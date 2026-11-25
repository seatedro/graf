, matches AS (
  (SELECT id, 0 AS priority FROM entity
   WHERE graph_id = $1 AND merged_into IS NULL AND norm = $9::text AND ($3::text IS NULL OR type = $3) LIMIT 32)
  UNION ALL
  (SELECT entity_id, 1 FROM entity_alias WHERE graph_id = $1 AND norm = $9 LIMIT 32)
  UNION ALL
  (SELECT entity_id, 2 FROM entity_alias WHERE graph_id = $1 AND length($9) >= 3 AND norm LIKE $9 || '%' LIMIT 64)
  UNION ALL
  (SELECT id, 3 FROM entity WHERE graph_id = $1 AND merged_into IS NULL AND ($3 IS NULL OR type = $3)
    AND tsv @@ websearch_to_tsquery('english', $8::text) LIMIT 64)
), entity_hits AS (
  SELECT e.id, e.name, e.type, m.priority FROM (SELECT id, min(priority) AS priority FROM matches GROUP BY id) m
  CROSS JOIN LATERAL (SELECT * FROM live WHERE id = m.id AND ($3 IS NULL OR type = $3) LIMIT 1) e
  WHERE ($2 IS NULL AND $4 IS NULL AND $5 IS NULL AND $6 IS NULL) OR
    EXISTS (SELECT 1 FROM fact_view WHERE subject_id = e.id AND visible OFFSET 0) OR
    EXISTS (SELECT 1 FROM fact_view WHERE object_id = e.id AND visible OFFSET 0)
  ORDER BY m.priority, e.name, e.id LIMIT 24
), fact_hits AS (
  SELECT f.id, f.text, f.subject_id, f.relation FROM fact_view f
  WHERE f.visible AND f.tsv @@ websearch_to_tsquery('english', $8)
    AND EXISTS (SELECT 1 FROM live WHERE id = f.subject_id AND ($3 IS NULL OR type = $3) OFFSET 0)
    AND (f.object_id IS NULL OR EXISTS (SELECT 1 FROM live WHERE id = f.object_id OFFSET 0))
  LIMIT 24
)
SELECT json_build_object(
  'entities', coalesce((SELECT json_agg(json_build_object('id', id, 'name', name, 'type', type) ORDER BY priority, name, id) FROM entity_hits), '[]'),
  'facts', coalesce((SELECT json_agg(f ORDER BY id) FROM fact_hits f), '[]')
)::text
