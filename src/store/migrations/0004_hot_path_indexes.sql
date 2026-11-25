CREATE INDEX IF NOT EXISTS entity_alias_entity_idx ON entity_alias (entity_id, norm);
CREATE INDEX IF NOT EXISTS entity_graph_norm_idx ON entity (graph_id, norm);
CREATE INDEX IF NOT EXISTS entity_merged_into_idx ON entity (merged_into) WHERE merged_into IS NOT NULL;

CREATE INDEX IF NOT EXISTS fact_subject_idx ON fact (subject_id);
CREATE INDEX IF NOT EXISTS fact_object_idx ON fact (object_id) WHERE object_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS fact_evidence_entry_idx ON fact_evidence (entry_id);

CREATE INDEX IF NOT EXISTS llm_call_entry_idx ON llm_call (entry_id);

CREATE INDEX IF NOT EXISTS entry_claim_idx ON entry (graph_id, backfill, reference_time, seq_in_source, id)
  WHERE status IN ('queued', 'extracting', 'extracted', 'staged');
CREATE INDEX IF NOT EXISTS entry_source_pending_idx ON entry (source_id, backfill, seq_in_source, reference_time, id)
  WHERE status IN ('queued', 'extracting', 'extracted', 'staged', 'committing');

ALTER INDEX entity_alias_norm_trgm SET (fastupdate = off);
SELECT gin_clean_pending_list('entity_alias_norm_trgm'::regclass);
