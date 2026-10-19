//! A complete byte digest is independent of the existing fast/normal hash modes.
//! Unknown proofs stay absent; migration never infers them from sampled hashes.
pub const create =
    "CREATE TABLE IF NOT EXISTS file_move_identities(file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,sha256 BLOB NOT NULL CHECK(typeof(sha256)='blob' AND length(sha256)=32)) WITHOUT ROWID;" ++
    "CREATE TRIGGER IF NOT EXISTS file_move_identity_source_au AFTER UPDATE OF content_hash,file_size,mtime_ns ON files WHEN old.content_hash!=new.content_hash OR old.file_size!=new.file_size OR old.mtime_ns!=new.mtime_ns BEGIN DELETE FROM file_move_identities WHERE file_id=new.id; END;" ++
    "DROP TRIGGER IF EXISTS catalog_source_bu;" ++
    "CREATE TRIGGER catalog_source_bu BEFORE UPDATE OF content_hash,file_size,mtime_ns ON files WHEN (old.content_hash!=new.content_hash OR old.file_size!=new.file_size OR old.mtime_ns!=new.mtime_ns) AND NOT (old.file_size<0 AND old.content_hash!=0 AND old.content_hash=new.content_hash) AND ws_verified_move_v1(old.id)=0 BEGIN DELETE FROM file_embeddings WHERE file_id=old.id; DELETE FROM embedding_failures WHERE file_id=old.id; DELETE FROM file_fingerprints WHERE file_id=old.id; DELETE FROM fingerprint_failures WHERE file_id=old.id; END;";

pub const dropForTests = "DROP TRIGGER file_move_identity_source_au; DROP TABLE file_move_identities;";

pub const check = "SELECT COUNT(*) FROM file_move_identities m LEFT JOIN files f ON f.id=m.file_id WHERE f.id IS NULL OR typeof(m.sha256)!='blob' OR length(m.sha256)!=32";
