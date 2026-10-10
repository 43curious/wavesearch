// Schema 12: indexed name keys and transactionally maintained work statistics.
// All tables are derived. Rebuilds happen only on migration/restore, never per item.
pub const create =
    "CREATE TABLE file_search_keys(file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,name_key TEXT NOT NULL,stem_key TEXT NOT NULL);" ++
    "CREATE INDEX idx_search_name ON file_search_keys(name_key,file_id);" ++
    "CREATE INDEX idx_search_stem ON file_search_keys(stem_key,file_id);" ++
    "INSERT INTO file_search_keys SELECT id,ws_name_key(name),ws_stem_key(name) FROM files;" ++
    "CREATE TRIGGER search_keys_ai AFTER INSERT ON files BEGIN INSERT INTO file_search_keys VALUES(new.id,ws_name_key(new.name),ws_stem_key(new.name)); END;" ++
    "CREATE TRIGGER search_keys_au AFTER UPDATE OF name ON files BEGIN UPDATE file_search_keys SET name_key=ws_name_key(new.name),stem_key=ws_stem_key(new.name) WHERE file_id=new.id; END;" ++
    "CREATE VIRTUAL TABLE files_vocab USING fts5vocab(files_fts,'row');" ++
    "CREATE TABLE catalog_stats(singleton INTEGER PRIMARY KEY CHECK(singleton=1),generation INTEGER NOT NULL DEFAULT 0,file_count INTEGER NOT NULL DEFAULT 0,universal_count INTEGER NOT NULL DEFAULT 0,detailed_count INTEGER NOT NULL DEFAULT 0,universal_bytes INTEGER NOT NULL DEFAULT 0,detailed_bytes INTEGER NOT NULL DEFAULT 0,waveform_failure_count INTEGER NOT NULL DEFAULT 0,waveform_terminal_count INTEGER NOT NULL DEFAULT 0);" ++
    "INSERT INTO catalog_stats(singleton) VALUES(1);" ++
    "ALTER TABLE embedding_models ADD COLUMN embedded_count INTEGER NOT NULL DEFAULT 0;" ++
    "ALTER TABLE embedding_models ADD COLUMN failed_count INTEGER NOT NULL DEFAULT 0;" ++
    "ALTER TABLE embedding_models ADD COLUMN quantized_count INTEGER NOT NULL DEFAULT 0;" ++
    "CREATE INDEX idx_waveform_detailed_lru ON waveform_tiers(detailed_access_ns,file_id) WHERE detailed_blob IS NOT NULL;" ++
    "ALTER TABLE fingerprint_algorithms ADD COLUMN document_count INTEGER NOT NULL DEFAULT 0;" ++
    "ALTER TABLE fingerprint_algorithms ADD COLUMN failed_count INTEGER NOT NULL DEFAULT 0;" ++
    "CREATE TABLE fingerprint_df(algorithm_id INTEGER NOT NULL REFERENCES fingerprint_algorithms(id) ON DELETE CASCADE,token_hash INTEGER NOT NULL,document_count INTEGER NOT NULL,PRIMARY KEY(algorithm_id,token_hash)) WITHOUT ROWID;" ++
    // Clear old derived identities before counters begin tracking row lifetimes.
    reconcile ++
    "CREATE TRIGGER catalog_files_ai AFTER INSERT ON files BEGIN UPDATE catalog_stats SET generation=generation+1,file_count=file_count+1 WHERE singleton=1; END;" ++
    "CREATE TRIGGER catalog_files_ad AFTER DELETE ON files BEGIN UPDATE catalog_stats SET generation=generation+1,file_count=file_count-1 WHERE singleton=1; END;" ++
    "CREATE TRIGGER catalog_files_au AFTER UPDATE OF path,name,search_text,duration_ms,content_hash,file_size,mtime_ns ON files BEGIN UPDATE catalog_stats SET generation=generation+1 WHERE singleton=1; END;" ++
    // BEFORE update/delete ensures derived counters see the old identity. The
    // existing application invalidation is idempotent and remains compatible.
    "CREATE TRIGGER catalog_source_bu BEFORE UPDATE OF content_hash,file_size,mtime_ns ON files WHEN (old.content_hash!=new.content_hash OR old.file_size!=new.file_size OR old.mtime_ns!=new.mtime_ns) AND NOT (old.file_size<0 AND old.content_hash!=0 AND old.content_hash=new.content_hash) BEGIN DELETE FROM file_embeddings WHERE file_id=old.id; DELETE FROM embedding_failures WHERE file_id=old.id; DELETE FROM file_fingerprints WHERE file_id=old.id; DELETE FROM fingerprint_failures WHERE file_id=old.id; END;" ++
    "CREATE TRIGGER stats_waveform_ai AFTER INSERT ON waveform_tiers BEGIN UPDATE catalog_stats SET universal_count=universal_count+1,detailed_count=detailed_count+(new.detailed_blob IS NOT NULL),universal_bytes=universal_bytes+new.universal_bytes,detailed_bytes=detailed_bytes+new.detailed_bytes WHERE singleton=1; END;" ++
    "CREATE TRIGGER stats_waveform_ad AFTER DELETE ON waveform_tiers BEGIN UPDATE catalog_stats SET universal_count=universal_count-1,detailed_count=detailed_count-(old.detailed_blob IS NOT NULL),universal_bytes=universal_bytes-old.universal_bytes,detailed_bytes=detailed_bytes-old.detailed_bytes WHERE singleton=1; END;" ++
    "CREATE TRIGGER stats_waveform_au AFTER UPDATE OF universal_bytes,detailed_bytes ON waveform_tiers BEGIN UPDATE catalog_stats SET detailed_count=detailed_count+(new.detailed_blob IS NOT NULL)-(old.detailed_blob IS NOT NULL),universal_bytes=universal_bytes+new.universal_bytes-old.universal_bytes,detailed_bytes=detailed_bytes+new.detailed_bytes-old.detailed_bytes WHERE singleton=1; END;" ++
    "CREATE TRIGGER stats_waveform_fail_ai AFTER INSERT ON waveform_failures BEGIN UPDATE catalog_stats SET waveform_failure_count=waveform_failure_count+1,waveform_terminal_count=waveform_terminal_count+new.permanent WHERE singleton=1; END;" ++
    "CREATE TRIGGER stats_waveform_fail_ad AFTER DELETE ON waveform_failures BEGIN UPDATE catalog_stats SET waveform_failure_count=waveform_failure_count-1,waveform_terminal_count=waveform_terminal_count-old.permanent WHERE singleton=1; END;" ++
    "CREATE TRIGGER stats_waveform_fail_au AFTER UPDATE OF permanent ON waveform_failures BEGIN UPDATE catalog_stats SET waveform_terminal_count=waveform_terminal_count+new.permanent-old.permanent WHERE singleton=1; END;" ++
    "CREATE TRIGGER stats_embedding_ai AFTER INSERT ON file_embeddings BEGIN UPDATE embedding_models SET embedded_count=embedded_count+1 WHERE id=new.model_id; END;" ++
    "CREATE TRIGGER stats_embedding_ad AFTER DELETE ON file_embeddings BEGIN UPDATE embedding_models SET embedded_count=embedded_count-1 WHERE id=old.model_id; END;" ++
    quantizedCounters ++
    "CREATE TRIGGER stats_embedding_fail_ai AFTER INSERT ON embedding_failures BEGIN UPDATE embedding_models SET failed_count=failed_count+1 WHERE id=new.model_id; END;" ++
    "CREATE TRIGGER stats_embedding_fail_ad AFTER DELETE ON embedding_failures BEGIN UPDATE embedding_models SET failed_count=failed_count-1 WHERE id=old.model_id; END;" ++
    "CREATE TRIGGER stats_fingerprint_ai AFTER INSERT ON file_fingerprints BEGIN UPDATE fingerprint_algorithms SET document_count=document_count+1 WHERE id=new.algorithm_id; END;" ++
    "CREATE TRIGGER stats_fingerprint_ad AFTER DELETE ON file_fingerprints BEGIN UPDATE fingerprint_algorithms SET document_count=document_count-1 WHERE id=old.algorithm_id; END;" ++
    "CREATE TRIGGER stats_fingerprint_fail_ai AFTER INSERT ON fingerprint_failures BEGIN UPDATE fingerprint_algorithms SET failed_count=failed_count+1 WHERE id=new.algorithm_id; END;" ++
    "CREATE TRIGGER stats_fingerprint_fail_ad AFTER DELETE ON fingerprint_failures BEGIN UPDATE fingerprint_algorithms SET failed_count=failed_count-1 WHERE id=old.algorithm_id; END;" ++
    "CREATE TRIGGER stats_posting_ai AFTER INSERT ON fingerprint_postings BEGIN INSERT INTO fingerprint_df VALUES(new.algorithm_id,new.token_hash,1) ON CONFLICT(algorithm_id,token_hash) DO UPDATE SET document_count=document_count+1; END;" ++
    "CREATE TRIGGER stats_posting_ad AFTER DELETE ON fingerprint_postings BEGIN UPDATE fingerprint_df SET document_count=document_count-1 WHERE algorithm_id=old.algorithm_id AND token_hash=old.token_hash; DELETE FROM fingerprint_df WHERE algorithm_id=old.algorithm_id AND token_hash=old.token_hash AND document_count=0; END;" ++
    "CREATE TRIGGER stats_posting_au AFTER UPDATE OF algorithm_id,token_hash ON fingerprint_postings BEGIN UPDATE fingerprint_df SET document_count=document_count-1 WHERE algorithm_id=old.algorithm_id AND token_hash=old.token_hash; DELETE FROM fingerprint_df WHERE algorithm_id=old.algorithm_id AND token_hash=old.token_hash AND document_count=0; INSERT INTO fingerprint_df VALUES(new.algorithm_id,new.token_hash,1) ON CONFLICT(algorithm_id,token_hash) DO UPDATE SET document_count=document_count+1; END;";

pub const quantizedCounters =
    "CREATE TRIGGER stats_sq8_ai AFTER INSERT ON semantic_sq8 BEGIN UPDATE embedding_models SET quantized_count=quantized_count+1 WHERE id=new.model_id; END;" ++
    "CREATE TRIGGER stats_sq8_ad AFTER DELETE ON semantic_sq8 BEGIN UPDATE embedding_models SET quantized_count=quantized_count-1 WHERE id=old.model_id; END;";

pub const reconcile =
    "DELETE FROM file_embeddings WHERE NOT EXISTS(SELECT 1 FROM files f WHERE f.id=file_id AND f.content_hash=source_content_hash);" ++
    "DELETE FROM embedding_failures WHERE NOT EXISTS(SELECT 1 FROM files f WHERE f.id=file_id AND f.content_hash=source_content_hash);" ++
    "DELETE FROM file_fingerprints WHERE NOT EXISTS(SELECT 1 FROM files f WHERE f.id=file_id AND f.content_hash=source_content_hash);" ++
    "DELETE FROM fingerprint_failures WHERE NOT EXISTS(SELECT 1 FROM files f WHERE f.id=file_id AND f.content_hash=source_content_hash);" ++
    "DELETE FROM waveform_tiers WHERE NOT EXISTS(SELECT 1 FROM files f WHERE f.id=file_id AND f.content_hash=source_content_hash AND f.file_size=source_file_size AND f.mtime_ns=source_mtime_ns);" ++
    "DELETE FROM waveform_failures WHERE NOT EXISTS(SELECT 1 FROM files f WHERE f.id=file_id AND f.content_hash=source_content_hash AND f.file_size=source_file_size AND f.mtime_ns=source_mtime_ns);" ++
    "UPDATE catalog_stats SET file_count=(SELECT COUNT(*) FROM files),universal_count=(SELECT COUNT(*) FROM waveform_tiers),detailed_count=(SELECT COUNT(*) FROM waveform_tiers WHERE detailed_blob IS NOT NULL),universal_bytes=(SELECT COALESCE(SUM(universal_bytes),0) FROM waveform_tiers),detailed_bytes=(SELECT COALESCE(SUM(detailed_bytes),0) FROM waveform_tiers),waveform_failure_count=(SELECT COUNT(*) FROM waveform_failures),waveform_terminal_count=(SELECT COUNT(*) FROM waveform_failures WHERE permanent!=0) WHERE singleton=1;" ++
    "UPDATE embedding_models SET embedded_count=(SELECT COUNT(*) FROM file_embeddings WHERE model_id=embedding_models.id),quantized_count=(SELECT COUNT(*) FROM semantic_sq8 WHERE model_id=embedding_models.id),failed_count=(SELECT COUNT(*) FROM embedding_failures WHERE model_id=embedding_models.id);" ++
    "UPDATE fingerprint_algorithms SET document_count=(SELECT COUNT(*) FROM file_fingerprints WHERE algorithm_id=fingerprint_algorithms.id),failed_count=(SELECT COUNT(*) FROM fingerprint_failures WHERE algorithm_id=fingerprint_algorithms.id);" ++
    "DELETE FROM fingerprint_df; INSERT INTO fingerprint_df SELECT algorithm_id,token_hash,COUNT(*) FROM fingerprint_postings GROUP BY algorithm_id,token_hash;";

// Only fixture downgrades use this; production never removes schema 12.
pub const dropForTests =
    "DROP TRIGGER search_keys_ai; DROP TRIGGER search_keys_au;" ++
    "DROP TRIGGER catalog_files_ai; DROP TRIGGER catalog_files_ad; DROP TRIGGER catalog_files_au; DROP TRIGGER catalog_source_bu;" ++
    "DROP TRIGGER stats_waveform_ai; DROP TRIGGER stats_waveform_ad; DROP TRIGGER stats_waveform_au;" ++
    "DROP TRIGGER stats_waveform_fail_ai; DROP TRIGGER stats_waveform_fail_ad; DROP TRIGGER stats_waveform_fail_au;" ++
    "DROP TRIGGER stats_embedding_ai; DROP TRIGGER stats_embedding_ad; DROP TRIGGER stats_embedding_fail_ai; DROP TRIGGER stats_embedding_fail_ad; DROP TRIGGER stats_sq8_ai; DROP TRIGGER stats_sq8_ad;" ++
    "DROP INDEX idx_waveform_detailed_lru;" ++
    "DROP TRIGGER stats_fingerprint_ai; DROP TRIGGER stats_fingerprint_ad; DROP TRIGGER stats_fingerprint_fail_ai; DROP TRIGGER stats_fingerprint_fail_ad;" ++
    "DROP TRIGGER stats_posting_ai; DROP TRIGGER stats_posting_ad; DROP TRIGGER stats_posting_au;" ++
    "DROP TABLE file_search_keys; DROP TABLE files_vocab; DROP TABLE catalog_stats; DROP TABLE fingerprint_df;" ++
    "ALTER TABLE embedding_models DROP COLUMN embedded_count; ALTER TABLE embedding_models DROP COLUMN failed_count; ALTER TABLE embedding_models DROP COLUMN quantized_count;" ++
    "ALTER TABLE fingerprint_algorithms DROP COLUMN document_count; ALTER TABLE fingerprint_algorithms DROP COLUMN failed_count;";

pub const check =
    "SELECT file_count!=(SELECT COUNT(*) FROM files) OR universal_count!=(SELECT COUNT(*) FROM waveform_tiers) OR detailed_count!=(SELECT COUNT(*) FROM waveform_tiers WHERE detailed_blob IS NOT NULL) OR universal_bytes!=(SELECT COALESCE(SUM(universal_bytes),0) FROM waveform_tiers) OR detailed_bytes!=(SELECT COALESCE(SUM(detailed_bytes),0) FROM waveform_tiers) OR waveform_failure_count!=(SELECT COUNT(*) FROM waveform_failures) OR waveform_terminal_count!=(SELECT COUNT(*) FROM waveform_failures WHERE permanent!=0) OR EXISTS(SELECT 1 FROM embedding_models m WHERE m.embedded_count!=(SELECT COUNT(*) FROM file_embeddings WHERE model_id=m.id) OR m.quantized_count!=(SELECT COUNT(*) FROM semantic_sq8 WHERE model_id=m.id) OR m.failed_count!=(SELECT COUNT(*) FROM embedding_failures WHERE model_id=m.id)) OR EXISTS(SELECT 1 FROM fingerprint_algorithms a WHERE a.document_count!=(SELECT COUNT(*) FROM file_fingerprints WHERE algorithm_id=a.id) OR a.failed_count!=(SELECT COUNT(*) FROM fingerprint_failures WHERE algorithm_id=a.id)) OR EXISTS(SELECT algorithm_id,token_hash,COUNT(*) FROM fingerprint_postings GROUP BY algorithm_id,token_hash EXCEPT SELECT algorithm_id,token_hash,document_count FROM fingerprint_df) OR EXISTS(SELECT algorithm_id,token_hash,document_count FROM fingerprint_df EXCEPT SELECT algorithm_id,token_hash,COUNT(*) FROM fingerprint_postings GROUP BY algorithm_id,token_hash) FROM catalog_stats WHERE singleton=1";
