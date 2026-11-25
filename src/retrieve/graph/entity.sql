, profile AS MATERIALIZED (
  SELECT id, name, type, summary, description, attributes, merged_into FROM entity WHERE graph_id = $1 AND id = $8::uuid
), incident AS (
  (SELECT id FROM fact_view f WHERE f.subject_id = $8 AND f.visible
    AND ($9::uuid IS NULL OR f.id < $9) AND ($10::uuid IS NULL OR f.id = $10)
    AND ($3::text IS NULL OR (SELECT type FROM profile) = $3 OR EXISTS (
      SELECT 1 FROM entity e WHERE e.id = f.object_id AND e.graph_id = $1 AND e.type = $3 OFFSET 0))
    ORDER BY id DESC LIMIT 65)
  UNION
  (SELECT id FROM fact_view f WHERE f.object_id = $8 AND f.visible
    AND ($9 IS NULL OR f.id < $9) AND ($10 IS NULL OR f.id = $10)
    AND ($3 IS NULL OR (SELECT type FROM profile) = $3 OR EXISTS (
      SELECT 1 FROM entity e WHERE e.id = f.subject_id AND e.graph_id = $1 AND e.type = $3 OFFSET 0))
    ORDER BY id DESC LIMIT 65)
), details AS MATERIALIZED (
  SELECT f.id, f.text, f.relation, f.qualifier, f.author, f.rationale, f.subject_id, s.name AS subject_name, f.object_id, o.name AS object_name,
    f.object_value, lower(f.valid) AS valid_from, upper(f.valid) AS valid_to,
    lower(f.known) AS known_from, upper(f.known) AS known_to, f.end_kind, f.confidence, f.scope, f.project
  FROM incident i
  CROSS JOIN LATERAL (SELECT * FROM fact WHERE id = i.id LIMIT 1) f
  CROSS JOIN LATERAL (SELECT name, type FROM entity WHERE graph_id = $1 AND id = f.subject_id LIMIT 1) s
  LEFT JOIN LATERAL (SELECT name, type FROM entity WHERE graph_id = $1 AND id = f.object_id LIMIT 1) o ON true
  WHERE f.object_id IS NULL OR o.name IS NOT NULL
  ORDER BY f.id DESC LIMIT 65
), facts AS (
  SELECT d.*, coalesce((SELECT json_agg(v ORDER BY entry_id, kind) FROM (
    SELECT p.quote, p.entry_id, p.kind FROM fact_evidence p
    JOIN entry e ON e.id = p.entry_id AND e.graph_id = $1
    WHERE p.fact_id = d.id ORDER BY p.entry_id, p.kind LIMIT 8
  ) v), '[]') AS evidence FROM (SELECT * FROM details ORDER BY id DESC LIMIT 64) d
), merges AS (
  (SELECT from_id, into_id, reason, created_at FROM merge_log WHERE graph_id = $1 AND from_id = $8 ORDER BY created_at DESC LIMIT 32)
  UNION (SELECT from_id, into_id, reason, created_at FROM merge_log WHERE graph_id = $1 AND into_id = $8 ORDER BY created_at DESC LIMIT 32)
)
SELECT json_build_object(
  'entity', p,
  'aliases', coalesce((SELECT json_agg(alias ORDER BY norm) FROM (
    SELECT alias, norm FROM entity_alias WHERE graph_id = $1 AND entity_id = $8 ORDER BY norm LIMIT 64
  ) a), '[]'),
  'facts', coalesce((SELECT json_agg(f ORDER BY id DESC) FROM facts f), '[]'),
  'truncated', (SELECT count(*) > 64 FROM details),
  'next_before', CASE WHEN (SELECT count(*) > 64 FROM details) THEN (SELECT id FROM details ORDER BY id DESC OFFSET 63 LIMIT 1) END,
  'merges', coalesce((SELECT json_agg(m ORDER BY created_at DESC) FROM (SELECT * FROM merges ORDER BY created_at DESC LIMIT 32) m), '[]')
)::text FROM profile p
