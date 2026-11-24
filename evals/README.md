# graf evaluation suite

A 20-entry labeled suite that replays a realistic multi-harness timeline into a fresh graph and scores the result against gold labels. A release ships only when every gate below passes.

All names in the suite are fictional or public: `Acme` is a made-up organization, `acme-box` its sandbox software, `Tollgate` a made-up LLM gateway, and `lighthouse` a made-up devbox. The API key in `e18` is fake and exists only so the redactor has something to remove.

## Files

- `entries.jsonl`: one entry per line, in replay order.
- `expected.json`: gold labels for entities, merges, facts, invalidations, secrets, and retrieval queries.

## Running

```sh
nix develop
eval "$(nix run .#devdb -- env)"
zig build
zig-out/bin/graf eval run --suite evals --serve-bin zig-out/bin/graf
```

Flags:

| Flag | Meaning |
|---|---|
| `--suite DIR` | Directory holding the two files (default `evals`). |
| `--graph NAME` | Graph to create for the run (default `eval-<unix ms>`). The crash-resume check uses `NAME-crash`. |
| `--serve-bin PATH` | A `graf` binary for the crash-resume check. Without it that gate is unmeasured. |
| `--json` | Print the report as JSON instead of the scorecard table. |

The command exits 0 only when every gate passes, 1 when any gate fails or could not be measured, and 2 on usage, suite, or configuration errors. Model endpoints come from your normal graf configuration; the suite never names a provider.

What a run does:

1. Loads and validates the suite (counts and referential integrity).
2. Creates a fresh graph and replays each entry in order, driving ingestion until the entry is `committed`, `skipped`, `dead`, or `split` before enqueueing the next.
3. Runs the ten retrieval queries with `max_tokens = 1500` at each query's `as_of`.
4. Crash-resume: enqueues `e06` into a second graph, starts `graf serve`, waits until the entry is `extracted`, kills the process with SIGKILL, restarts it, waits for the commit, and checks that no new extraction call was recorded for that entry.
5. Reads `entity`, `entity_alias`, `fact`, `fact_evidence`, `entry`, and `llm_call` for the graph, scans every row of the graph's tables for forbidden substrings, and scores.

Any piece of the pipeline that is not built yet reports its gates as unmeasured rather than crashing the run. An unmeasured gate counts as a failure.

## Release gates

| Metric | Gate |
|---|---|
| Entity F1 | >= 0.85 |
| Merge accuracy | >= 0.90 |
| Cross-type merges | 0 |
| Fact precision | >= 0.85 |
| Fact recall | >= 0.80 |
| Invalidation and retraction F1 | >= 0.85 |
| Temporal grounding accuracy | >= 0.90 |
| Secret leaks | 0 |
| Retrieval recall@5 | >= 0.85 |
| Model calls per entry | <= 2.00 |
| Cost per entry | <= $0.02 |
| Crash-resume pass rate | 100% |

## How each metric is scored

**Name matching.** Names and aliases are normalized before comparison: ASCII letters are lowercased, apostrophes are dropped (`karlseguin's` becomes `karlseguins`), every other ASCII punctuation or whitespace run becomes one space, and the result is trimmed. So `pg.zig`, `pg-zig`, and `pg_zig` all become `pg zig`, while `Acme` and `acme-box` stay distinct.

**Mapping graph entities to gold.** A graph entity maps to the first gold entity whose name or alias equals one of its own names (its name first, then its aliases), provided the types are compatible. Compatible types share a class: person; organization; project, repository, code, software, AI model, or environment; dataset or document; decision, task, change, session, run, problem, or event; concept. `other` is compatible with everything. Entities are followed through `merged_into` to their surviving entity, and a survivor takes its own label or, failing that, the first label among the entities merged into it.

**Entity F1.** True positives are gold entities with at least one surviving entity. A second survivor for the same gold entity is a false positive (an unmerged duplicate), as is a survivor whose names hit a gold name but whose type is incompatible. Survivors that hit no gold name at all are outside the labels and are reported but not scored.

**Merge accuracy.** Each expected merge and each must-not-merge pair is one item. An expected merge is correct when its gold entity has exactly one survivor and every graph entity carrying the mention resolves to it. A must-not-merge pair is correct when both gold entities have survivors and no survivor's names (including everything merged into it, ignoring type) cover both. Cross-type merges count survivors whose names cover gold entities of different types, which catches both `merged_into` and alias-based merges.

**Facts.** A graph fact matches a gold fact when the subject maps to the gold subject, the relation matches after the equivalence table, the qualifier matches when the gold fact has one, and the object matches. Entity objects match by mapped entity; value objects match exactly after normalization, as dates within one day, or when the shorter value's words are all contained in the longer one. A value may stand in for an entity (and the reverse) when it equals one of the entity's names. The equivalence table maps a few common synonyms onto the core relations (for example `depends_on` to `uses`, `runs_on` to `located_at`, `compared_with` to `related_to`) and handles inverses such as `owns` for `owned_by` by swapping subject and object.

Each gold fact is claimed by at most one graph fact, chosen in replay order. Precision counts every graph fact: a claim is a true positive; a second row matching an already claimed gold fact (a restatement written as a new row) is a false positive, as is any fact stated by a `skip` entry and any fact matching no gold label. A fact matching a `must_not_contain_facts` entry is forgiven only when it was retracted or forgotten, which is the correct outcome for a correction within one entry. Recall counts every `facts_added` entry plus every `restated` entry; a restatement is found when the matched fact carries evidence from the restating entry.

**Invalidation and retraction F1.** Predicted invalidations are graph facts whose `end_kind` is set or whose valid or system range is closed. A prediction is a true positive when it maps to a gold invalidation with the same `end_kind`; anything else is a false positive, including a fact listed in `must_remain_active`. Facts born with a closed range because the gold fact has `valid_to` (historical backfill) are not predictions. Forgiven corrections are ignored.

**Temporal grounding.** One item per `valid_from` and `valid_to` of each gold fact that has `time_basis` or `valid_to`, plus one per invalidation `valid_to`. An item is correct when a matching graph fact has that bound within one day. A missing fact or bound is wrong.

**Secret leaks.** The number of distinct `forbidden_substrings_anywhere` entries found, case-sensitively, in any row of the graph's `entity`, `entity_alias`, `fact`, `fact_evidence`, `entry`, `llm_call`, `source`, `relation`, and `merge_log` tables (each row is cast to text whole, so every text and jsonb column is covered). Findings name the location but never print the secret.

**Retrieval recall@5.** The fraction of all `must_include` facts that appear among the first five hits of their query. `must_exclude` hits and `must_exclude_substrings` (matched as whole words, case-sensitively) are reported as exclusion violations but are not a gate.

**Calls and cost per entry.** Calls are ledger rows with purpose `extract`, `resolve`, or `repair`, every attempt included, divided by the 20 suite entries. Embedding calls are reported separately. Cost is the sum of `llm_call.cost_usd` for every purpose except query-time `rerank` and `embed_query`, divided by 20. Both are unmeasured until every entry reaches a terminal status.

**Crash-resume.** Passes when the killed entry ends `committed` (or `skipped`) and the extraction-call count for it is unchanged after the restart. A run where the entry is never observed at `extracted` is unmeasured.

## entries.jsonl

| Field | Type | Meaning |
|---|---|---|
| `id` | string | `e01` to `e20`, in replay order. |
| `seq` | integer | Position within its source; strictly increasing per source. |
| `harness` | string | `claude-code`, `codex`, `pi`, `fx`, `capy`, `api`, `cli`, or `mcp`. |
| `source_id` | string | Session, thread, or note stream id. |
| `project`, `agent`, `model` | string | Source metadata; `project` scopes the entry. |
| `reference_time` | RFC 3339 | When the conversation happened. |
| `kind` | string | `turns` or `note`. |
| `author` | string | `user`, `agent`, `mixed`, or `tool`. |
| `turns` | array | `{ role, text, tool_calls? }` with `tool_calls` as `{ name, args_preview, result_preview }`. |

The source key is `(harness, source_id)`, and `seq` becomes `seq_in_source`.

## expected.json

- `canonical_entities`: `{ id, name, type, aliases, first_seen }`, where `type` is a core entity type.
- `expected_merges`: `{ entry, mention, must_resolve_to, rule }`. The mention must end up in the same surviving entity as the gold entity.
- `must_not_merge`: `{ entry, entity_a, entity_b, reason }`.
- `entries`: keyed by entry id, each with:
  - `skip`: the entry must produce no facts.
  - `facts_added`: `{ id, subject, relation, qualifier?, object? | object_value?, scope?, valid_from, valid_to?, time_basis? }`. Exactly one of `object` (a gold entity id) and `object_value` is set.
  - `restated`: gold fact ids this entry restates; they must gain evidence, not a new row.
  - `invalidations`: `{ fact_id, end_kind, valid_to, mechanism }` with `end_kind` `changed` or `retracted`.
  - `must_not_contain_facts`: `"<subject> <relation> <object>"`, where the subject is a gold entity name or alias, the relation one word, and the object the rest. Such a fact may be written only if it is retracted.
  - `must_remain_active`: gold fact ids that must not be ended by this entry.
  - `forbidden_substrings_anywhere`: strings that must not appear in any stored row.
- `retrieval_queries`: `{ id, query, project, as_of, must_include, must_exclude?, must_exclude_substrings? }`. A `project` of `*` searches every project.

## Coverage

- Extraction of several facts per entry: `e01` to `e03`.
- Entries with no durable knowledge: `e04` (test output) and `e14` (brainstorming).
- Deduplication by alias and across projects: `e05`, `e08`, `e19`.
- Merge traps: `Acme` (organization) against `acme-box` (software) in `e09`, and `fx` (software) against the FX dataset in `e20`.
- State changes: `e06` (on-call handoff), `e10` (opposed relation), `e11` (setting change).
- Corrections: `e07` (refuted claim) and `e13` (self-correction within one entry).
- Historical backfill that must not end current state: `e12`.
- Restatement from another harness: `e15`.
- Explicit future date: `e16`.
- Global preferences: `e17`.
- Secret redaction: `e18`.
