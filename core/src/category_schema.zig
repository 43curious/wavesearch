pub const create =
    "CREATE INDEX IF NOT EXISTS idx_files_ucs ON files(ucs_id);" ++
    "CREATE TRIGGER IF NOT EXISTS files_category_au AFTER UPDATE OF ucs_id ON files WHEN old.ucs_id IS NOT new.ucs_id BEGIN UPDATE catalog_stats SET generation=generation+1 WHERE singleton=1; END;";
pub const dropForTests = "DROP TRIGGER IF EXISTS files_category_au; DROP INDEX IF EXISTS idx_files_ucs; ALTER TABLE files DROP COLUMN ucs_id;";
