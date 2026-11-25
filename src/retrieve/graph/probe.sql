 CROSS JOIN LATERAL (
  (SELECT f.id, f.subject_id, f.object_id, f.relation, f.confidence, 1 AS direction FROM fact_view f
   WHERE f.subject_id = r.id AND f.object_id IS NOT NULL AND f.visible
     AND ($8::uuid IS NULL OR $3::text IS NULL OR EXISTS (SELECT 1 FROM ranked WHERE id = f.object_id AND type = $3))
   ORDER BY f.id DESC LIMIT 65)
  UNION ALL
  (SELECT f.id, f.subject_id, f.object_id, f.relation, f.confidence, 2 AS direction FROM fact_view f
   WHERE f.object_id = r.id AND f.visible
     AND ($8 IS NULL OR $3 IS NULL OR EXISTS (SELECT 1 FROM ranked WHERE id = f.subject_id AND type = $3))
   ORDER BY f.id DESC LIMIT 65)
) f
WHERE $8 IS NULL OR $3 IS NULL OR EXISTS (SELECT 1 FROM ranked WHERE type = $3)
