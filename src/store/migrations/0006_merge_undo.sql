ALTER TABLE commit_log ALTER COLUMN entry_id DROP NOT NULL;

ALTER TABLE merge_log
  ADD COLUMN subject_facts uuid[],
  ADD COLUMN object_facts uuid[],
  ADD COLUMN added_aliases text[],
  ADD COLUMN added_mentions uuid[],
  ADD COLUMN undone_seq bigint;

ALTER TABLE possible_duplicate
  ADD COLUMN reason text,
  ADD COLUMN decided_at timestamptz;

CREATE INDEX IF NOT EXISTS possible_duplicate_open ON possible_duplicate (graph_id, score DESC) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS possible_duplicate_pair ON possible_duplicate (graph_id, entity_a, entity_b);
