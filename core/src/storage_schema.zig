// Schema 14: explicit source identity strength and resumable lossless repacking.
pub const create =
    "CREATE INDEX IF NOT EXISTS idx_fingerprint_storage_pending ON file_fingerprints(algorithm_id,file_id) WHERE storage_version=0;" ++
    "CREATE TRIGGER IF NOT EXISTS file_identity_au AFTER UPDATE OF identity_kind,hash_algorithm ON files WHEN old.identity_kind!=new.identity_kind OR old.hash_algorithm!=new.hash_algorithm BEGIN UPDATE catalog_stats SET generation=generation+1 WHERE singleton=1; END;" ++
    "CREATE TRIGGER IF NOT EXISTS file_identity_source_au AFTER UPDATE OF content_hash,file_size,mtime_ns ON files WHEN old.content_hash!=new.content_hash OR old.file_size!=new.file_size OR old.mtime_ns!=new.mtime_ns BEGIN UPDATE files SET identity_kind=0,hash_algorithm=0 WHERE id=new.id AND (identity_kind!=0 OR hash_algorithm!=0); END;";

pub const check = "SELECT COUNT(*) FROM files WHERE identity_kind NOT IN(0,1,2,3) OR hash_algorithm NOT IN(0,1) OR (identity_kind=0 AND hash_algorithm!=0) OR (identity_kind!=0 AND (hash_algorithm!=1 OR file_size<0 OR content_hash=0)) OR (identity_kind IN(1,2) AND content_hash>=0) OR (identity_kind=3 AND content_hash<=0)";

// Fixture downgrade only; production keeps schema 14 and its source metadata.
pub const dropForTests =
    "DROP TRIGGER file_identity_au; DROP TRIGGER file_identity_source_au;" ++
    "DROP INDEX idx_fingerprint_storage_pending;" ++
    "ALTER TABLE files DROP COLUMN identity_kind; ALTER TABLE files DROP COLUMN hash_algorithm;" ++
    "ALTER TABLE file_fingerprints DROP COLUMN storage_version;";
