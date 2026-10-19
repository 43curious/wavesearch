// Schema 16 keeps unknown technical values NULL and invalidates cached values
// with source identity. Discovery/publishing own descriptive text, never hosts.
pub const create =
    "CREATE TABLE IF NOT EXISTS file_audio_metadata(file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,channels INTEGER CHECK(channels>0 AND channels<=256),sample_rate INTEGER CHECK(sample_rate>0 AND sample_rate<=384000),bit_depth INTEGER CHECK(bit_depth>0 AND bit_depth<=64),encoding INTEGER CHECK(encoding IN(1,3)),limited INTEGER NOT NULL CHECK(limited IN(0,1))) WITHOUT ROWID;" ++
    "CREATE TRIGGER IF NOT EXISTS audio_metadata_source_au AFTER UPDATE OF content_hash,file_size,mtime_ns ON files WHEN old.content_hash!=new.content_hash OR old.file_size!=new.file_size OR old.mtime_ns!=new.mtime_ns BEGIN DELETE FROM file_audio_metadata WHERE file_id=new.id; UPDATE files SET description='' WHERE id=new.id; END;" ++
    "CREATE TRIGGER IF NOT EXISTS audio_description_au AFTER UPDATE OF description ON files WHEN old.description!=new.description BEGIN UPDATE catalog_stats SET generation=generation+1 WHERE singleton=1; END;";

const drop_fts = "DROP TRIGGER IF EXISTS files_ai; DROP TRIGGER IF EXISTS files_ad; DROP TRIGGER IF EXISTS files_au; DROP TABLE IF EXISTS files_fts;";

fn fts(comptime structured: bool) []const u8 {
    const column = if (structured) ",description" else "";
    const new_column = if (structured) ",new.description" else "";
    const old_column = if (structured) ",old.description" else "";
    return "CREATE VIRTUAL TABLE files_fts USING fts5(search_text,name" ++ column ++ ",content='files',content_rowid='id',tokenize='unicode61 remove_diacritics 1');" ++
        "CREATE TRIGGER files_ai AFTER INSERT ON files BEGIN INSERT INTO files_fts(rowid,search_text,name" ++ column ++ ") VALUES(new.id,new.search_text,new.name" ++ new_column ++ "); INSERT INTO files_trigram(rowid,search_text) VALUES(new.id,new.search_text); END;" ++
        "CREATE TRIGGER files_ad AFTER DELETE ON files BEGIN INSERT INTO files_fts(files_fts,rowid,search_text,name" ++ column ++ ") VALUES('delete',old.id,old.search_text,old.name" ++ old_column ++ "); INSERT INTO files_trigram(files_trigram,rowid,search_text) VALUES('delete',old.id,old.search_text); END;" ++
        "CREATE TRIGGER files_au AFTER UPDATE OF search_text,name" ++ column ++ " ON files BEGIN INSERT INTO files_fts(files_fts,rowid,search_text,name" ++ column ++ ") VALUES('delete',old.id,old.search_text,old.name" ++ old_column ++ "); INSERT INTO files_fts(rowid,search_text,name" ++ column ++ ") VALUES(new.id,new.search_text,new.name" ++ new_column ++ "); INSERT INTO files_trigram(files_trigram,rowid,search_text) VALUES('delete',old.id,old.search_text); INSERT INTO files_trigram(rowid,search_text) VALUES(new.id,new.search_text); END;" ++
        "INSERT INTO files_fts(files_fts) VALUES('rebuild');" ++
        (if (structured) "INSERT INTO files_fts(files_fts,rank) VALUES('rank','bm25(1.0,1.0,2.0)');" else "");
}
pub const rebuild = drop_fts ++ "CREATE VIRTUAL TABLE IF NOT EXISTS files_trigram USING fts5(search_text,content='files',content_rowid='id',tokenize='trigram');" ++ fts(true) ++ "INSERT INTO files_trigram(files_trigram) VALUES('rebuild');";
pub const dropForTests = "DROP TRIGGER audio_metadata_source_au; DROP TRIGGER audio_description_au; DROP TABLE file_audio_metadata;" ++ drop_fts ++ "ALTER TABLE files DROP COLUMN description;" ++ fts(false);
pub const check = "SELECT COUNT(*) FROM file_audio_metadata m LEFT JOIN files f ON f.id=m.file_id WHERE f.id IS NULL OR (m.channels IS NOT NULL AND (m.channels<=0 OR m.channels>256)) OR (m.sample_rate IS NOT NULL AND (m.sample_rate<=0 OR m.sample_rate>384000)) OR (m.bit_depth IS NOT NULL AND (m.bit_depth<=0 OR m.bit_depth>64)) OR (m.encoding IS NOT NULL AND m.encoding NOT IN(1,3)) OR m.limited NOT IN(0,1)";
