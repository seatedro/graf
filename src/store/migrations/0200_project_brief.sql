CREATE TABLE project_brief (
  graph_id   uuid NOT NULL REFERENCES graph(id),
  project    text NOT NULL,
  body       text NOT NULL,
  built_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (graph_id, project)
);
