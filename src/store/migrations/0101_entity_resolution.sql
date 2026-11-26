CREATE INDEX IF NOT EXISTS entity_person_first_token ON entity (graph_id, split_part(norm, ' ', 1))
  WHERE type = 'person' AND merged_into IS NULL;
