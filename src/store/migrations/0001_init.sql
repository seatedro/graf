CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE graph (
  id          uuid PRIMARY KEY,
  name        text UNIQUE NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE source (
  id          uuid PRIMARY KEY,
  graph_id    uuid NOT NULL REFERENCES graph(id),
  harness     text NOT NULL,
  external_id text NOT NULL,
  project     text,
  agent       text,
  model       text,
  cursor      text,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (graph_id, harness, external_id)
);

CREATE TABLE episode (
  id             uuid PRIMARY KEY,
  graph_id       uuid NOT NULL REFERENCES graph(id),
  source_id      uuid REFERENCES source(id),
  seq_in_source  int NOT NULL DEFAULT 0,
  kind           text NOT NULL,
  project        text,
  asserted_by    text NOT NULL,
  body           jsonb NOT NULL,
  content_hash   bytea NOT NULL,
  reference_time timestamptz NOT NULL,
  received_at    timestamptz NOT NULL DEFAULT now(),
  status         text NOT NULL DEFAULT 'queued',
  attempts       int NOT NULL DEFAULT 0,
  not_before     timestamptz,
  lease_owner    text,
  lease_token    bigint,
  lease_until    timestamptz,
  extraction     jsonb,
  change_set     jsonb,
  base_seq       bigint,
  commit_seq     bigint,
  cost_usd       numeric(12,6) NOT NULL DEFAULT 0,
  warnings       jsonb NOT NULL DEFAULT '[]',
  last_error     jsonb,
  UNIQUE (graph_id, content_hash)
);

CREATE TABLE entity (
  id                  uuid PRIMARY KEY,
  graph_id            uuid NOT NULL REFERENCES graph(id),
  name                text NOT NULL,
  norm                text NOT NULL,
  type                text NOT NULL,
  description         text NOT NULL DEFAULT '',
  summary             text NOT NULL DEFAULT '',
  facts_since_summary int NOT NULL DEFAULT 0,
  attributes          jsonb NOT NULL DEFAULT '{}',
  name_emb            halfvec(512),
  tsv                 tsvector GENERATED ALWAYS AS (
                        to_tsvector('english', coalesce(name, '') || ' ' || coalesce(description, ''))
                      ) STORED,
  merged_into         uuid REFERENCES entity(id),
  created_seq         bigint NOT NULL,
  updated_seq         bigint NOT NULL
);

CREATE TABLE entity_alias (
  graph_id   uuid NOT NULL REFERENCES graph(id),
  norm       text NOT NULL,
  entity_id  uuid NOT NULL REFERENCES entity(id),
  alias      text NOT NULL,
  PRIMARY KEY (graph_id, norm, entity_id)
);

CREATE TABLE predicate (
  graph_id      uuid NOT NULL REFERENCES graph(id),
  name          text NOT NULL,
  description   text NOT NULL,
  cardinality   text NOT NULL,
  opposes       text,
  object_kind   text NOT NULL DEFAULT 'either',
  status        text NOT NULL,
  mapped_to     text,
  uses          int NOT NULL DEFAULT 0,
  episodes      int NOT NULL DEFAULT 0,
  sources       int NOT NULL DEFAULT 0,
  PRIMARY KEY (graph_id, name)
);

CREATE TABLE fact (
  id           uuid PRIMARY KEY,
  graph_id     uuid NOT NULL REFERENCES graph(id),
  subject_id   uuid NOT NULL REFERENCES entity(id),
  predicate    text NOT NULL,
  qualifier    text NOT NULL DEFAULT '',
  object_id    uuid REFERENCES entity(id),
  object_value text,
  text         text NOT NULL,
  rationale    text,
  project      text,
  scope        text NOT NULL,
  valid        tstzrange NOT NULL,
  sys          tstzrange NOT NULL,
  end_kind     text,
  ended_by     uuid REFERENCES fact(id),
  asserted_by  text NOT NULL,
  confidence   real NOT NULL,
  emb          halfvec(512) NOT NULL,
  tsv          tsvector GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
  created_seq  bigint NOT NULL,
  CHECK ((object_id IS NULL) <> (object_value IS NULL))
);

CREATE TABLE fact_provenance (
  fact_id     uuid NOT NULL REFERENCES fact(id) ON DELETE CASCADE,
  episode_id  uuid NOT NULL REFERENCES episode(id) ON DELETE CASCADE,
  role        text NOT NULL,
  quote       text,
  PRIMARY KEY (fact_id, episode_id, role)
);

CREATE TABLE entity_mention (
  entity_id   uuid NOT NULL REFERENCES entity(id),
  episode_id  uuid NOT NULL REFERENCES episode(id) ON DELETE CASCADE,
  PRIMARY KEY (entity_id, episode_id)
);

CREATE TABLE commit_log (
  graph_id         uuid NOT NULL REFERENCES graph(id),
  seq              bigint NOT NULL,
  episode_id       uuid NOT NULL REFERENCES episode(id),
  committed_at     timestamptz NOT NULL DEFAULT now(),
  touched_entities uuid[] NOT NULL,
  touched_facts    uuid[] NOT NULL,
  PRIMARY KEY (graph_id, seq)
);

CREATE TABLE merge_log (
  id          uuid PRIMARY KEY,
  graph_id    uuid NOT NULL REFERENCES graph(id),
  seq         bigint NOT NULL,
  from_id     uuid NOT NULL REFERENCES entity(id),
  into_id     uuid NOT NULL REFERENCES entity(id),
  reason      text NOT NULL,
  moved_facts uuid[] NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE must_not_merge (
  graph_id  uuid NOT NULL REFERENCES graph(id),
  entity_a  uuid NOT NULL REFERENCES entity(id),
  entity_b  uuid NOT NULL REFERENCES entity(id),
  reason    text NOT NULL,
  PRIMARY KEY (graph_id, entity_a, entity_b),
  CHECK (entity_a < entity_b)
);

CREATE TABLE possible_duplicate (
  id         uuid PRIMARY KEY,
  graph_id   uuid NOT NULL REFERENCES graph(id),
  entity_a   uuid NOT NULL REFERENCES entity(id),
  entity_b   uuid NOT NULL REFERENCES entity(id),
  score      real NOT NULL,
  status     text NOT NULL DEFAULT 'open',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE llm_call (
  id                 uuid PRIMARY KEY,
  graph_id           uuid NOT NULL REFERENCES graph(id),
  episode_id         uuid REFERENCES episode(id),
  purpose            text NOT NULL,
  route              text NOT NULL,
  model              text NOT NULL,
  attempt            int NOT NULL,
  outcome            text NOT NULL,
  error_class        text,
  http_status        int,
  input_tokens       int NOT NULL DEFAULT 0,
  output_tokens      int NOT NULL DEFAULT 0,
  cache_read_tokens  int NOT NULL DEFAULT 0,
  cache_write_tokens int NOT NULL DEFAULT 0,
  cost_usd           numeric(12,8) NOT NULL DEFAULT 0,
  cost_status        text NOT NULL DEFAULT 'missing',
  latency_ms         int NOT NULL,
  started_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX fact_emb_hnsw ON fact USING hnsw (emb halfvec_cosine_ops) WITH (m = 16, ef_construction = 128);
CREATE INDEX entity_name_emb_hnsw ON entity USING hnsw (name_emb halfvec_cosine_ops) WITH (m = 16, ef_construction = 128);

CREATE INDEX fact_tsv_gin ON fact USING gin (tsv);
CREATE INDEX entity_tsv_gin ON entity USING gin (tsv);
CREATE INDEX entity_alias_norm_trgm ON entity_alias USING gin (norm gin_trgm_ops);

CREATE INDEX fact_active_subject ON fact (graph_id, subject_id)
  WHERE upper_inf(sys) AND upper_inf(valid);
CREATE INDEX fact_active_object ON fact (graph_id, object_id)
  WHERE upper_inf(sys) AND upper_inf(valid);
CREATE INDEX fact_active_key ON fact (graph_id, subject_id, predicate, qualifier)
  WHERE upper_inf(sys) AND upper_inf(valid);

CREATE INDEX fact_valid_gist ON fact USING gist (graph_id, valid);
CREATE INDEX fact_sys_gist ON fact USING gist (graph_id, sys);

CREATE INDEX episode_queue ON episode (graph_id, not_before, reference_time)
  WHERE status IN ('queued', 'extracted', 'staged');
CREATE INDEX episode_source_seq ON episode (source_id, seq_in_source);

CREATE INDEX llm_call_started ON llm_call (graph_id, started_at);
