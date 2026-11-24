# AGENTS.md

Read this before changing anything in graf. It is short on purpose.

## Layout and ownership

Code is split into modules under `src/`. A module is a directory with a root file `mod.zig` and may import only the modules declared for it in `build.zig`; the compiler rejects anything else. Add files freely inside your module. You never need to touch `build.zig` to add a file.

| Module | Directory | May import | Covers |
|---|---|---|---|
| core | `src/core/` | (none) | shared types, ontology, config, TOML |
| store | `src/store/` | core, pg | schema, migrations, queue, commit, ledger, managed Postgres |
| eval | `src/eval/`, `evals/` | core, store, llm, ingest, retrieve | labeled eval suite and scorer |
| llm | `src/llm/` | core | model and embeddings client, limiter, cost capture |
| ingest | `src/ingest/` | core, store, llm, pg | extraction, resolution, workers |
| capture | `src/capture/` | core | transcript tailers, redaction, segmenter, hooks |
| retrieve | `src/retrieve/` | core, store, llm, pg | hybrid search, rerank, rendering, brief |
| surface | `src/surface/`, `src/main.zig` | everything | CLI, MCP, HTTP daemon |

Rules for working across modules:

- Stay inside your directories. If you need something from another module, code against its public declarations in `mod.zig`. If a declaration is missing or wrong, change it in a PR for that module rather than from inside another module's change.
- `core` is shared. You may add new declarations to `core` in your PR. Changing or removing an existing `core` declaration needs its own small PR that lands first.
- Stubs return `error.NotImplemented` (`core.NotImplemented`). Replace them with real implementations.
- Capture never imports `store`: it writes through `core.EntrySink`. The LLM client never imports `store`: it writes through `core.LlmLedger`. `store` implements both.

## Migrations

SQL lives in `src/store/migrations/NNNN_name.sql` and is registered in `src/store/migrations.zig` (keep the list sorted). Migrations are append-only: never edit one that has merged. Version ranges avoid collisions between concurrent branches:

| Range | Module |
|---|---|
| 0001-0099 | store |
| 0100-0199 | ingest |
| 0200-0299 | retrieve |
| 0300-0399 | surface |

The runner applies every version missing from `schema_migrations`, each in its own transaction.

## Build and test

```sh
nix develop                        # Zig 0.17.1 and Postgres 17 + pgvector on PATH
nix run .#devdb                    # local Postgres on 127.0.0.1:54329 (databases graf, graf_test)
eval "$(nix run .#devdb -- env)"   # exports GRAF_DATABASE_URL and GRAF_TEST_DATABASE_URL
zig build test                     # all modules
zig build test-store               # one module (test-core, test-llm, test-ingest, ...)
zig build test -Dtest-filter=toml  # tests whose names contain "toml"
zig fmt build.zig src              # CI runs zig fmt --check
zig build run -- config            # run the CLI
```

Integration tests need Postgres. Open a migrated store with `store.testing.open()`; it skips the test when `GRAF_TEST_DATABASE_URL` is unset, so `zig build test` always works offline. CI sets it against a `pgvector/pgvector:pg17` service. Tests must not call real model APIs: replay captured, scrubbed fixtures instead.

Zig is pinned to 0.17.1 (`build.zig.zon`, the flake, CI). Use the `std.Io` interfaces (pass `io` explicitly), `std.process.Init`, and `std.testing.io` in tests.

## Conventions

- Match the spec. Where you make a call the spec leaves open, say why in your PR description.
- No comments by default. Names and types should carry the meaning; add a comment only for something the code cannot say.
- Every LLM attempt writes an `llm_call` row, including failures. Nothing logs or stores secrets; redaction runs before storage and before any model call.
- License: MIT. Files copied from Apache-2.0 projects keep their original license header, and the copy is recorded in `THIRD_PARTY_NOTICES.md` with the upstream URL, commit, and license text.
- Agents never merge PRs.
