//! Durable pending rows: selecting a batch never consumes work. Analysis or a
//! terminal failure removes it in the same SQLite transaction as publication.
//! Separate owner tables keep model and fingerprint revisions independently
//! resumable without process-local cursors or a second job scheduler.

fn Queue(comptime pending: []const u8, comptime owners: []const u8, comptime owner_id: []const u8, comptime results: []const u8, comptime failures: []const u8) type {
    return struct {
        const eligible = "NOT EXISTS(SELECT 1 FROM " ++ results ++ " r WHERE r." ++ owner_id ++ "=o.id AND r.file_id=f.id AND r.source_content_hash=f.content_hash) AND " ++
            "NOT EXISTS(SELECT 1 FROM " ++ failures ++ " x WHERE x." ++ owner_id ++ "=o.id AND x.file_id=f.id AND x.source_content_hash=f.content_hash)";
        const candidates = "SELECT o.id,f.id,f.folder_id FROM " ++ owners ++ " o CROSS JOIN files f WHERE " ++ eligible;
        const insert = "INSERT OR IGNORE INTO " ++ pending ++ "(" ++ owner_id ++ ",file_id,folder_id) ";
        const requeue_old = insert ++ candidates ++ " AND o.id=old." ++ owner_id ++ " AND f.id=old.file_id;";
        const finish_new = "DELETE FROM " ++ pending ++ " WHERE " ++ owner_id ++ "=new." ++ owner_id ++ " AND file_id=new.file_id AND EXISTS(SELECT 1 FROM files f WHERE f.id=new.file_id AND f.content_hash=new.source_content_hash);";

        const create = "CREATE TABLE " ++ pending ++ "(" ++ owner_id ++ " INTEGER NOT NULL REFERENCES " ++ owners ++ "(id) ON DELETE CASCADE," ++
            "file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,folder_id INTEGER NOT NULL,PRIMARY KEY(" ++ owner_id ++ ",file_id)) WITHOUT ROWID;" ++
            "CREATE INDEX idx_" ++ pending ++ "_folder ON " ++ pending ++ "(" ++ owner_id ++ ",folder_id,file_id);" ++
            "CREATE INDEX idx_" ++ pending ++ "_file ON " ++ pending ++ "(file_id);" ++
            "CREATE TRIGGER " ++ pending ++ "_owner_ai AFTER INSERT ON " ++ owners ++ " BEGIN " ++ insert ++ "SELECT new.id,id,folder_id FROM files; END;" ++
            "CREATE TRIGGER " ++ pending ++ "_file_ai AFTER INSERT ON files BEGIN " ++ insert ++ candidates ++ " AND f.id=new.id; END;" ++
            "CREATE TRIGGER " ++ pending ++ "_file_au AFTER UPDATE OF content_hash,file_size,mtime_ns,folder_id ON files " ++
            "WHEN old.content_hash!=new.content_hash OR old.file_size!=new.file_size OR old.mtime_ns!=new.mtime_ns OR old.folder_id!=new.folder_id BEGIN " ++
            "DELETE FROM " ++ pending ++ " WHERE file_id=new.id;" ++ insert ++ candidates ++ " AND f.id=new.id; END;" ++
            "CREATE TRIGGER " ++ pending ++ "_result_ai AFTER INSERT ON " ++ results ++ " BEGIN " ++ finish_new ++ " END;" ++
            "CREATE TRIGGER " ++ pending ++ "_result_au AFTER UPDATE ON " ++ results ++ " BEGIN " ++ requeue_old ++ finish_new ++ " END;" ++
            "CREATE TRIGGER " ++ pending ++ "_result_ad AFTER DELETE ON " ++ results ++ " BEGIN " ++ requeue_old ++ " END;" ++
            "CREATE TRIGGER " ++ pending ++ "_failure_ai AFTER INSERT ON " ++ failures ++ " BEGIN " ++ finish_new ++ " END;" ++
            "CREATE TRIGGER " ++ pending ++ "_failure_au AFTER UPDATE ON " ++ failures ++ " BEGIN " ++ requeue_old ++ finish_new ++ " END;" ++
            "CREATE TRIGGER " ++ pending ++ "_failure_ad AFTER DELETE ON " ++ failures ++ " BEGIN " ++ requeue_old ++ " END;";

        const rebuild = "DELETE FROM " ++ pending ++ ";" ++ insert ++ candidates ++ ";";
        const check = "EXISTS(" ++ candidates ++ " AND NOT EXISTS(SELECT 1 FROM " ++ pending ++ " p WHERE p." ++ owner_id ++ "=o.id AND p.file_id=f.id AND p.folder_id=f.folder_id)) OR " ++
            "EXISTS(SELECT 1 FROM " ++ pending ++ " p LEFT JOIN " ++ owners ++ " o ON o.id=p." ++ owner_id ++ " LEFT JOIN files f ON f.id=p.file_id WHERE o.id IS NULL OR f.id IS NULL OR p.folder_id!=f.folder_id OR NOT(" ++ eligible ++ "))";
        const drop = "DROP TRIGGER " ++ pending ++ "_owner_ai; DROP TRIGGER " ++ pending ++ "_file_ai; DROP TRIGGER " ++ pending ++ "_file_au;" ++
            "DROP TRIGGER " ++ pending ++ "_result_ai; DROP TRIGGER " ++ pending ++ "_result_au; DROP TRIGGER " ++ pending ++ "_result_ad;" ++
            "DROP TRIGGER " ++ pending ++ "_failure_ai; DROP TRIGGER " ++ pending ++ "_failure_au; DROP TRIGGER " ++ pending ++ "_failure_ad; DROP TABLE " ++ pending ++ ";";
    };
}

const Semantic = Queue("pending_embeddings", "embedding_models", "model_id", "file_embeddings", "embedding_failures");
const Acoustic = Queue("pending_fingerprints", "fingerprint_algorithms", "algorithm_id", "file_fingerprints", "fingerprint_failures");

pub const create = Semantic.create ++ Acoustic.create ++ rebuild;
pub const rebuild = Semantic.rebuild ++ Acoustic.rebuild;
pub const check = "SELECT " ++ Semantic.check ++ " OR " ++ Acoustic.check;
pub const dropForTests = Semantic.drop ++ Acoustic.drop;
