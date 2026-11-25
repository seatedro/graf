LOCK TABLE entity, fact IN SHARE ROW EXCLUSIVE MODE;

CREATE TABLE IF NOT EXISTS graph_entity_rank (
  id uuid PRIMARY KEY REFERENCES entity(id) ON DELETE CASCADE,
  graph_id uuid NOT NULL,
  type text NOT NULL,
  live boolean NOT NULL,
  degree bigint NOT NULL DEFAULT 0
);

WITH degrees AS (
  SELECT f.graph_id, endpoint, count(*) AS degree
  FROM fact f
  CROSS JOIN LATERAL (
    SELECT f.subject_id AS endpoint UNION SELECT f.object_id
  ) n
  WHERE f.object_id IS NOT NULL
  GROUP BY f.graph_id, endpoint
) INSERT INTO graph_entity_rank (id, graph_id, type, live, degree)
SELECT e.id, e.graph_id, e.type, e.merged_into IS NULL, coalesce(d.degree, 0)
FROM entity e LEFT JOIN degrees d ON d.graph_id = e.graph_id AND d.endpoint = e.id;

CREATE INDEX IF NOT EXISTS graph_entity_hubs ON graph_entity_rank (graph_id, degree DESC, id) WHERE live;
CREATE INDEX IF NOT EXISTS graph_entity_type_hubs ON graph_entity_rank (graph_id, type, degree DESC, id) WHERE live;
CREATE INDEX IF NOT EXISTS graph_entity_types ON graph_entity_rank (graph_id, type) WHERE live;

CREATE OR REPLACE FUNCTION graph_track_entity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO graph_entity_rank AS r (id, graph_id, type, live)
  VALUES (NEW.id, NEW.graph_id, NEW.type, NEW.merged_into IS NULL)
  ON CONFLICT (id) DO UPDATE SET graph_id = excluded.graph_id, type = excluded.type, live = excluded.live,
    degree = CASE WHEN r.graph_id = excluded.graph_id THEN r.degree ELSE (
      SELECT count(*) FROM fact f WHERE f.graph_id = NEW.graph_id AND f.object_id IS NOT NULL
        AND (f.subject_id = NEW.id OR f.object_id = NEW.id)
    ) END
  WHERE (r.graph_id, r.type, r.live) IS DISTINCT FROM (excluded.graph_id, excluded.type, excluded.live);
  RETURN NULL;
END
$$;

CREATE TRIGGER graph_entity_metadata AFTER INSERT OR UPDATE OF graph_id, type, merged_into ON entity
  FOR EACH ROW EXECUTE FUNCTION graph_track_entity();

CREATE TABLE IF NOT EXISTS graph_fact_facet (
  graph_id uuid NOT NULL REFERENCES graph(id) ON DELETE CASCADE,
  project text,
  relation text NOT NULL,
  facts bigint NOT NULL,
  UNIQUE NULLS NOT DISTINCT (graph_id, project, relation)
);

INSERT INTO graph_fact_facet (graph_id, project, relation, facts)
SELECT graph_id, project, relation, count(*) FROM fact GROUP BY graph_id, project, relation;

CREATE OR REPLACE FUNCTION graph_update_inventory() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  changes text;
BEGIN
  changes := CASE TG_OP
    WHEN 'INSERT' THEN 'SELECT graph_id, project, relation, subject_id, object_id, 1 AS delta FROM added'
    WHEN 'DELETE' THEN 'SELECT graph_id, project, relation, subject_id, object_id, -1 AS delta FROM removed'
    ELSE 'SELECT graph_id, project, relation, subject_id, object_id, 1 AS delta FROM added
          UNION ALL SELECT graph_id, project, relation, subject_id, object_id, -1 AS delta FROM removed'
  END;

  EXECUTE 'WITH changes AS (' || changes || '), degrees AS (
    SELECT c.graph_id, endpoint, sum(delta) AS delta FROM changes c
    CROSS JOIN LATERAL (SELECT c.subject_id AS endpoint UNION SELECT c.object_id) n
    WHERE c.object_id IS NOT NULL GROUP BY c.graph_id, endpoint HAVING sum(delta) <> 0
  ), updated AS (
    UPDATE graph_entity_rank e SET degree = e.degree + d.delta FROM degrees d WHERE e.graph_id = d.graph_id AND e.id = d.endpoint
  )
  INSERT INTO graph_fact_facet AS f (graph_id, project, relation, facts)
  SELECT graph_id, project, relation, sum(delta) FROM changes
  GROUP BY graph_id, project, relation HAVING sum(delta) <> 0 ORDER BY graph_id, project, relation
  ON CONFLICT (graph_id, project, relation) DO UPDATE SET facts = f.facts + excluded.facts';

  RETURN NULL;
END
$$;

CREATE TRIGGER graph_inventory_insert AFTER INSERT ON fact
  REFERENCING NEW TABLE AS added FOR EACH STATEMENT EXECUTE FUNCTION graph_update_inventory();
CREATE TRIGGER graph_inventory_delete AFTER DELETE ON fact
  REFERENCING OLD TABLE AS removed FOR EACH STATEMENT EXECUTE FUNCTION graph_update_inventory();
CREATE TRIGGER graph_inventory_update AFTER UPDATE ON fact
  REFERENCING OLD TABLE AS removed NEW TABLE AS added FOR EACH STATEMENT EXECUTE FUNCTION graph_update_inventory();

CREATE INDEX IF NOT EXISTS fact_graph_subject_page ON fact (graph_id, subject_id, id DESC)
  INCLUDE (object_id, project, relation, confidence, valid, known);
CREATE INDEX IF NOT EXISTS fact_graph_object_page ON fact (graph_id, object_id, id DESC)
  INCLUDE (subject_id, project, relation, confidence, valid, known) WHERE object_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS fact_graph_project_relation ON fact (graph_id, project, relation, id DESC);
CREATE INDEX IF NOT EXISTS fact_graph_relation_page ON fact (graph_id, relation, id DESC);
CREATE INDEX IF NOT EXISTS fact_graph_confidence ON fact (graph_id, confidence) WHERE object_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS fact_graph_map_page ON fact (graph_id, id DESC)
  INCLUDE (subject_id, object_id, relation, project, confidence, valid, known) WHERE object_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS entity_graph_map_node ON entity (graph_id, id)
  INCLUDE (name, type) WHERE merged_into IS NULL;
CREATE INDEX IF NOT EXISTS merge_graph_from_page ON merge_log (graph_id, from_id, created_at DESC);
CREATE INDEX IF NOT EXISTS merge_graph_into_page ON merge_log (graph_id, into_id, created_at DESC);
