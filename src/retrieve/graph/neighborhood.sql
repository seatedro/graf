, round_robin AS (
  SELECT l.*, row_number() OVER (PARTITION BY anchor ORDER BY confidence DESC, id DESC) AS turn FROM first_links l
), hop1 AS MATERIALIZED (
  SELECT id, subject_id, object_id, relation, confidence, min(turn) AS turn
  FROM round_robin GROUP BY id, subject_id, object_id, relation, confidence
  ORDER BY min(turn), confidence DESC, id DESC LIMIT 64
), frontier AS MATERIALIZED (
  SELECT id FROM (
    SELECT subject_id AS id FROM hop1 UNION SELECT object_id FROM hop1
  ) n WHERE $9::int = 2 AND NOT EXISTS (SELECT 1 FROM roots WHERE id = n.id)
  ORDER BY id LIMIT 32
), second_sample AS MATERIALIZED (
  SELECT r.id AS anchor, f.* FROM frontier r
  {s}
), hop2 AS (
  SELECT DISTINCT f.id, f.subject_id, f.object_id, f.relation, f.confidence
  FROM second_sample f
  WHERE NOT EXISTS (SELECT 1 FROM hop1 h WHERE h.id = f.id)
    AND EXISTS (SELECT 1 FROM live WHERE id = CASE WHEN f.subject_id = f.anchor THEN f.object_id ELSE f.subject_id END OFFSET 0)
), all_edges AS MATERIALIZED (
  SELECT id, subject_id, object_id, relation, confidence, 1 AS hop FROM hop1
  UNION ALL SELECT id, subject_id, object_id, relation, confidence, 2 FROM hop2
), edges AS MATERIALIZED (
  SELECT id, subject_id, object_id, relation, confidence FROM all_edges
  ORDER BY hop, confidence DESC, id DESC LIMIT 96
), nodes AS (
  SELECT id FROM displayed_roots UNION SELECT subject_id FROM edges UNION SELECT object_id FROM edges
)
SELECT json_build_object(
  'nodes', coalesce((SELECT json_agg(json_build_object('id', e.id, 'name', e.name, 'type', e.type) ORDER BY e.id)
    FROM nodes n CROSS JOIN LATERAL (SELECT * FROM live WHERE id = n.id LIMIT 1) e), '[]'),
  'edges', coalesce((SELECT json_agg(e ORDER BY confidence DESC, id DESC) FROM edges e), '[]'),
  'truncated', (SELECT count(*) > 96 FROM all_edges) OR (SELECT count(DISTINCT id) > 64 FROM first_links)
    OR (SELECT count(*) > 12 FROM candidates)
    OR EXISTS (SELECT 1 FROM first_sample GROUP BY anchor, direction HAVING count(*) = 65)
    OR EXISTS (SELECT 1 FROM second_sample GROUP BY anchor, direction HAVING count(*) = 65)
    OR (SELECT count(*) = 257 FROM scoped)
    OR ($9 = 2 AND (SELECT count(*) FROM (
      SELECT subject_id AS id FROM hop1 UNION SELECT object_id FROM hop1 EXCEPT SELECT id FROM roots
    ) n) > 32)
)::text
WHERE $8 IS NULL OR EXISTS (SELECT 1 FROM roots)
