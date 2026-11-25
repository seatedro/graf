WITH live AS NOT MATERIALIZED (
  SELECT id, name, type FROM entity WHERE graph_id = $1 AND merged_into IS NULL
), ranked AS NOT MATERIALIZED (
  SELECT id, type, degree FROM graph_entity_rank WHERE graph_id = $1 AND live
), fact_view AS NOT MATERIALIZED (
  SELECT f.*,
    ($2::text IS NULL OR f.project = $2)
    AND ($4::text IS NULL OR f.relation = $4)
    AND ($5::real IS NULL OR f.confidence >= $5)
    AND (CASE WHEN $7::bool THEN
      f.valid && tstzrange(NULL, coalesce($6::timestamptz, now()), '(]')
      AND f.known && tstzrange(NULL, coalesce($6::timestamptz, now()), '(]')
    ELSE f.valid @> coalesce($6::timestamptz, now()) AND f.known @> coalesce($6::timestamptz, now()) END) AS visible
  FROM fact f WHERE f.graph_id = $1
)
