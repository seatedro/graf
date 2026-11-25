, eligible AS MATERIALIZED (
  SELECT f.id, f.subject_id, s.name AS subject_name, s.type AS subject_type,
    f.object_id, o.name AS object_name, o.type AS object_type, f.relation, f.confidence
  FROM fact_view f
  CROSS JOIN LATERAL (SELECT name, type FROM live WHERE id = f.subject_id LIMIT 1) s
  CROSS JOIN LATERAL (SELECT name, type FROM live WHERE id = f.object_id LIMIT 1) o
  WHERE f.object_id IS NOT NULL AND f.visible AND ($8::uuid IS NULL OR f.id < $8)
    AND ($3::text IS NULL OR EXISTS (SELECT 1 FROM ranked WHERE type = $3))
    AND ($3 IS NULL OR f.subject_id IN (SELECT id FROM ranked WHERE type = $3)
      OR f.object_id IN (SELECT id FROM ranked WHERE type = $3))
  ORDER BY f.id DESC LIMIT 2049
), page AS MATERIALIZED (
  SELECT * FROM eligible ORDER BY id DESC LIMIT 2048
), nodes AS (
  SELECT subject_id AS id, subject_name AS name, subject_type AS type FROM page
  UNION SELECT object_id, object_name, object_type FROM page
), edges AS (
  SELECT id, subject_id, object_id, relation, confidence FROM page
), more AS (
  SELECT count(*) > 2048 AS present FROM eligible
)
SELECT json_build_object(
  'nodes', coalesce((SELECT json_agg(n ORDER BY id) FROM nodes n), '[]'),
  'edges', coalesce((SELECT json_agg(e ORDER BY id DESC) FROM edges e), '[]'),
  'next_before', CASE WHEN more.present THEN (SELECT id FROM page ORDER BY id LIMIT 1) END,
  'truncated', more.present
)::text FROM more
