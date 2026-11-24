CREATE TABLE relation_embedding (
  graph_id uuid NOT NULL REFERENCES graph(id),
  name     text NOT NULL,
  emb      halfvec(512) NOT NULL,
  PRIMARY KEY (graph_id, name)
);

CREATE TABLE ingest_job (
  graph_id uuid NOT NULL REFERENCES graph(id),
  name     text NOT NULL,
  last_run timestamptz NOT NULL,
  PRIMARY KEY (graph_id, name)
);

CREATE INDEX entity_summary_due ON entity (graph_id, facts_since_summary) WHERE merged_into IS NULL;
