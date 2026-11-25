, scoped AS MATERIALIZED (
  SELECT subject_id, object_id FROM fact_view
  WHERE $8::uuid IS NULL AND ($2::text IS NOT NULL OR $4::text IS NOT NULL OR $5::real IS NOT NULL OR $6::timestamptz IS NOT NULL)
    AND visible AND object_id IS NOT NULL
  ORDER BY relation, id DESC LIMIT 257
), candidates AS (
  (SELECT id, degree FROM ranked WHERE $8 IS NULL AND $2 IS NULL AND $4 IS NULL AND $5 IS NULL AND $6 IS NULL
    AND ($3::text IS NULL OR type = $3) ORDER BY degree DESC, id LIMIT 13)
  UNION ALL
  (SELECT e.id, e.degree FROM (
    SELECT subject_id AS id FROM scoped UNION SELECT object_id FROM scoped
  ) s CROSS JOIN LATERAL (
    SELECT id, degree FROM ranked WHERE id = s.id AND ($3 IS NULL OR type = $3) LIMIT 1
  ) e ORDER BY e.degree DESC, e.id LIMIT 13)
  UNION ALL SELECT id, degree FROM ranked WHERE id = $8
), roots AS MATERIALIZED (
  SELECT id, degree FROM candidates ORDER BY degree DESC, id LIMIT 12
)
