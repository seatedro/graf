, first_sample AS MATERIALIZED (
  SELECT r.id AS anchor, f.* FROM roots r
  {s}
), first_links AS MATERIALIZED (
  SELECT DISTINCT f.anchor, f.id, f.subject_id, f.object_id, f.relation, f.confidence
  FROM first_sample f
  WHERE EXISTS (
    SELECT 1 FROM live WHERE id = CASE WHEN f.subject_id = f.anchor THEN f.object_id ELSE f.subject_id END
    OFFSET 0
  )
), displayed_roots AS (
  SELECT r.* FROM roots r WHERE $8 IS NOT NULL OR EXISTS (SELECT 1 FROM first_links l WHERE l.anchor = r.id)
    OR (r.degree = 0 AND $2 IS NULL AND $4 IS NULL AND $5 IS NULL AND $6 IS NULL)
)
