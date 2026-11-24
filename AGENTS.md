# AGENTS.md

Read this before changing anything in graf. It is short on purpose.

## Hard rule: vendor neutrality

graf is a public-grade, vendor-neutral project. Nothing in this repository may name an internal company, an internal LLM gateway or proxy, or any internal service codename. That covers code, identifiers, config keys, CLI flags, environment variables, HTTP headers, tests, fixtures, docs, comments, branch names, PR text, and commit messages.

- Describe providers generically: "an OpenAI-compatible endpoint", "an Anthropic-compatible endpoint", "a proxy", "a typed decision-model backend".
- Provider URLs, API keys, cost headers, and model ids belong in the user's `~/.config/graf/config.toml` or `GRAF_*` env vars, never in source. Code reads the cost header name from `llm.cost_header`; it never hard-codes one.
- Fixtures and eval episodes use made-up names (`example.test`, "acme", a fictional gateway). Captured provider responses are scrubbed of hostnames, ids, and vendor headers before they are committed.
- To test against a private endpoint on your own machine, map its credentials into `GRAF_LLM_BASE_URL` / `GRAF_LLM_API_KEY` (and the `GRAF_EMBED_*` / `GRAF_DECISION_*` equivalents) in your shell. Never commit them, and never mention where they point.
- CI runs a denylist check when the `GRAF_DENYLIST` repository secret is set. Passing it is necessary, not sufficient.

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
- Stubs return `error.NotImplemented` (`core.NotImplemented`). Replace them; keep the documented contract or update the doc comment with it.
- Capture never imports `store`: it writes through `core.EpisodeSink`. The LLM client never imports `store`: it writes through `core.LlmLedger`. `store` implements both.

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
- Keep public interfaces documented with `///` comments; they are what other modules code against.
- Every LLM attempt writes an `llm_call` row, including failures. Nothing logs or stores secrets; redaction runs before storage and before any model call.
- License: MIT. Files copied from Apache-2.0 projects keep their original license header, and the copy is recorded in `THIRD_PARTY_NOTICES.md` with the upstream URL, commit, and license text.
- Agents never merge PRs.
