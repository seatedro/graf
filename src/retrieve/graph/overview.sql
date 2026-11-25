, inventory AS MATERIALIZED (
  SELECT project, relation, facts FROM graph_fact_facet WHERE graph_id = $1 AND facts > 0
), types AS MATERIALIZED (
  SELECT type, count(*) AS count FROM ranked GROUP BY type
)
SELECT json_build_object(
  'entities', (SELECT coalesce(sum(count), 0) FROM types),
  'facts', (SELECT coalesce(sum(facts), 0) FROM inventory),
  'types', coalesce((SELECT json_agg(t ORDER BY count DESC, type) FROM (SELECT * FROM types ORDER BY count DESC, type LIMIT 128) t), '[]'),
  'projects', coalesce((SELECT json_agg(project ORDER BY project) FROM (SELECT DISTINCT project FROM inventory WHERE project IS NOT NULL ORDER BY project LIMIT 128) p), '[]'),
  'relations', coalesce((SELECT json_agg(relation ORDER BY relation) FROM (SELECT DISTINCT relation FROM inventory ORDER BY relation LIMIT 128) p), '[]'),
  'hubs', coalesce((SELECT json_agg(json_build_object('id', e.id, 'name', e.name, 'type', e.type) ORDER BY r.degree DESC, r.id)
    FROM displayed_roots r JOIN live e ON e.id = r.id), '[]'),
  'recent', coalesce((SELECT json_agg(c ORDER BY seq DESC) FROM (
    SELECT seq, committed_at FROM commit_log WHERE graph_id = $1 ORDER BY seq DESC LIMIT 12
  ) c), '[]'),
  'queue', (SELECT count(*) FROM entry WHERE graph_id = $1 AND status IN ('queued', 'extracting', 'extracted', 'staged', 'committing'))
)::text
