const std = @import("std");
const c = @import("c");
const query = @import("query.zig");
extern fn ws_sqlite_transient() c.sqlite3_destructor_type;

pub const MAX_JSON = 16 * 1024 * 1024;
pub const MAX_SOURCES = 100_000;
pub const schema =
    "CREATE TABLE IF NOT EXISTS user_sources(id TEXT PRIMARY KEY DEFAULT(lower(hex(randomblob(16)))),file_id INTEGER UNIQUE REFERENCES files(id) ON DELETE SET NULL,path TEXT NOT NULL,file_size INTEGER NOT NULL DEFAULT -1,mtime_ns INTEGER NOT NULL DEFAULT -1,content_hash INTEGER NOT NULL DEFAULT 0,identity_kind INTEGER NOT NULL DEFAULT 0,hash_algorithm INTEGER NOT NULL DEFAULT 0,sha256 TEXT,favourite INTEGER NOT NULL DEFAULT 0 CHECK(favourite IN(0,1)));" ++
    "CREATE TABLE IF NOT EXISTS user_tags(source_id TEXT NOT NULL REFERENCES user_sources(id) ON DELETE CASCADE,name TEXT NOT NULL,PRIMARY KEY(source_id,name)) WITHOUT ROWID;" ++
    "CREATE TABLE IF NOT EXISTS user_collections(source_id TEXT NOT NULL REFERENCES user_sources(id) ON DELETE CASCADE,name TEXT NOT NULL,start_ms INTEGER NOT NULL DEFAULT -1,end_ms INTEGER NOT NULL DEFAULT -1,CHECK((start_ms=-1 AND end_ms=-1) OR (start_ms>=0 AND end_ms>start_ms AND end_ms<=2147483647)),PRIMARY KEY(source_id,name,start_ms,end_ms)) WITHOUT ROWID;" ++
    "CREATE TABLE IF NOT EXISTS user_selects_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),legacy_seeded INTEGER NOT NULL CHECK(legacy_seeded IN(0,1)));" ++
    "INSERT OR IGNORE INTO user_selects_state VALUES(1,0);" ++
    "CREATE INDEX IF NOT EXISTS user_tags_name ON user_tags(name,source_id);" ++
    "CREATE INDEX IF NOT EXISTS user_collections_name ON user_collections(name,source_id);" ++
    "CREATE INDEX IF NOT EXISTS user_sources_path ON user_sources(path);" ++
    "CREATE INDEX IF NOT EXISTS idx_selects_sha ON file_move_identities(sha256);" ++
    "CREATE TRIGGER IF NOT EXISTS user_source_path_au AFTER UPDATE OF path ON files BEGIN UPDATE user_sources SET path=new.path WHERE file_id=new.id; END;" ++
    "CREATE TRIGGER IF NOT EXISTS user_source_detach_bd BEFORE DELETE ON files BEGIN UPDATE user_sources SET path=old.path,file_size=old.file_size,mtime_ns=old.mtime_ns,content_hash=old.content_hash,identity_kind=old.identity_kind,hash_algorithm=old.hash_algorithm,sha256=(SELECT lower(hex(sha256)) FROM file_move_identities WHERE file_id=old.id) WHERE file_id=old.id; END;";
pub const dropForTests = "DROP TRIGGER IF EXISTS user_source_path_au; DROP TRIGGER IF EXISTS user_source_detach_bd; DROP INDEX IF EXISTS idx_selects_sha; DROP TABLE user_tags; DROP TABLE user_collections; DROP TABLE user_sources; DROP TABLE user_selects_state;";

pub const Membership = struct { name: []const u8, start_ms: ?i64 = null, end_ms: ?i64 = null };
pub const Source = struct {
    id: ?[]const u8 = null,
    // Output convenience only. Import always resolves identity independently.
    file_id: ?i32 = null,
    path: []const u8,
    file_size: i64 = -1,
    mtime_ns: i64 = -1,
    content_hash: i64 = 0,
    identity_kind: u32 = 0,
    hash_algorithm: u32 = 0,
    sha256: ?[]const u8 = null,
    favourite: bool = false,
    tags: []const []const u8 = &.{},
    collections: []const Membership = &.{},
};
pub const Document = struct {
    version: u32,
    sources: []const Source,

    pub fn jsonParse(allocator: std.mem.Allocator, reader: anytype, options: std.json.ParseOptions) !Document {
        var exact = options;
        exact.parse_numbers = false;
        return strictValue(Document, allocator, try std.json.Value.jsonParse(allocator, reader, exact));
    }
};
pub const Report = struct { imported: u32 = 0, merged: u32 = 0, unresolved: u32 = 0, conflicts: u32 = 0 };
pub const Kind = enum(u32) { favourite = 0, tag = 1, collection = 2 };

/// Borrowed locked catalog connection. All state/merge/query rules live here;
/// file dialogs, source authorization and JSON file I/O belong to the host.
pub const Catalog = struct {
    handle: *c.sqlite3,

    fn prepare(self: Catalog, sql: [*:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SelectsPrepareFailed;
        return stmt orelse error.SelectsPrepareFailed;
    }
    fn exec(self: Catalog, sql: [*:0]const u8) !void {
        if (c.sqlite3_exec(self.handle, sql, null, null, null) != c.SQLITE_OK) return error.SelectsWriteFailed;
    }

    fn validateCapacity(self: Catalog) !void {
        const stmt = try self.prepare("SELECT (SELECT COALESCE(SUM(length(CAST(json_quote(COALESCE(f.path,s.path)) AS BLOB))+512),0) FROM user_sources s LEFT JOIN files f ON f.id=s.file_id)+(SELECT COALESCE(SUM(length(CAST(json_quote(name) AS BLOB))+4),0) FROM user_tags)+(SELECT COALESCE(SUM(length(CAST(json_quote(name) AS BLOB))+64),0) FROM user_collections), (SELECT COALESCE(MAX(n),0) FROM (SELECT COUNT(*) n FROM user_tags GROUP BY source_id)),(SELECT COALESCE(MAX(n),0) FROM (SELECT COUNT(*) n FROM user_collections GROUP BY source_id))");
        defer _ = c.sqlite3_finalize(stmt);
        if (!try stepRow(stmt) or c.sqlite3_column_int64(stmt, 0) > MAX_JSON or c.sqlite3_column_int64(stmt, 1) > 256 or c.sqlite3_column_int64(stmt, 2) > 256) return error.SelectsLimit;
    }

    fn sourceAt(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !Source {
        return .{
            .id = try allocator.dupe(u8, column(stmt, 0)),
            .file_id = if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL) null else c.sqlite3_column_int(stmt, 1),
            .path = try allocator.dupe(u8, column(stmt, 2)),
            .file_size = c.sqlite3_column_int64(stmt, 3),
            .mtime_ns = c.sqlite3_column_int64(stmt, 4),
            .content_hash = c.sqlite3_column_int64(stmt, 5),
            .identity_kind = @intCast(c.sqlite3_column_int64(stmt, 6)),
            .hash_algorithm = @intCast(c.sqlite3_column_int64(stmt, 7)),
            .sha256 = if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL) null else try allocator.dupe(u8, column(stmt, 8)),
            .favourite = c.sqlite3_column_int(stmt, 9) != 0,
        };
    }

    pub fn exportJSON(self: Catalog, allocator: std.mem.Allocator) ![:0]u8 {
        try self.exec("BEGIN DEFERRED;");
        defer self.exec("ROLLBACK;") catch {};
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var sources: std.ArrayList(Source) = .empty;
        var budget: usize = MAX_JSON;
        const stmt = try self.prepare("SELECT s.id,s.file_id,COALESCE(f.path,s.path),COALESCE(f.file_size,s.file_size),COALESCE(f.mtime_ns,s.mtime_ns),COALESCE(f.content_hash,s.content_hash),COALESCE(f.identity_kind,s.identity_kind),COALESCE(f.hash_algorithm,s.hash_algorithm),CASE WHEN f.id IS NULL THEN s.sha256 ELSE (SELECT lower(hex(sha256)) FROM file_move_identities WHERE file_id=f.id) END,s.favourite FROM user_sources s LEFT JOIN files f ON f.id=s.file_id ORDER BY s.id");
        defer _ = c.sqlite3_finalize(stmt);
        while (true) {
            try query.check();
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SelectsReadFailed;
            if (sources.items.len >= MAX_SOURCES) return error.SelectsLimit;
            try charge(&budget, jsonCost(column(stmt, 2)) + 512);
            var source = try sourceAt(a, stmt);
            var tags: std.ArrayList([]const u8) = .empty;
            const tag_stmt = try self.prepare("SELECT name FROM user_tags WHERE source_id=? ORDER BY name");
            defer _ = c.sqlite3_finalize(tag_stmt);
            try text(tag_stmt, 1, source.id.?);
            while (try stepRow(tag_stmt)) {
                try charge(&budget, jsonCost(column(tag_stmt, 0)) + 4);
                if (tags.items.len == 256) return error.SelectsLimit;
                try tags.append(a, try a.dupe(u8, column(tag_stmt, 0)));
            }
            source.tags = tags.items;
            var members: std.ArrayList(Membership) = .empty;
            const member_stmt = try self.prepare("SELECT name,start_ms,end_ms FROM user_collections WHERE source_id=? ORDER BY name,start_ms,end_ms");
            defer _ = c.sqlite3_finalize(member_stmt);
            try text(member_stmt, 1, source.id.?);
            while (try stepRow(member_stmt)) {
                try charge(&budget, jsonCost(column(member_stmt, 0)) + 64);
                if (members.items.len == 256) return error.SelectsLimit;
                const start = c.sqlite3_column_int64(member_stmt, 1);
                try members.append(a, .{ .name = try a.dupe(u8, column(member_stmt, 0)), .start_ms = if (start < 0) null else start, .end_ms = if (start < 0) null else c.sqlite3_column_int64(member_stmt, 2) });
            }
            source.collections = members.items;
            try validateSource(source);
            try sources.append(a, source);
        }
        const bytes = try std.json.Stringify.valueAlloc(a, Document{ .version = 1, .sources = sources.items }, .{});
        if (bytes.len > MAX_JSON) return error.SelectsLimit;
        return allocator.dupeSentinel(u8, bytes, 0);
    }

    fn boundSource(self: Catalog, allocator: std.mem.Allocator, file_id: i32) !Source {
        const stmt = try self.prepare("SELECT COALESCE(s.id,''),f.id,f.path,f.file_size,f.mtime_ns,f.content_hash,f.identity_kind,f.hash_algorithm,(SELECT lower(hex(sha256)) FROM file_move_identities WHERE file_id=f.id),COALESCE(s.favourite,0) FROM files f LEFT JOIN user_sources s ON s.file_id=f.id WHERE f.id=?");
        defer _ = c.sqlite3_finalize(stmt);
        try integer(stmt, 1, file_id);
        if (!try stepRow(stmt)) return error.SelectsFileMissing;
        var source = try sourceAt(allocator, stmt);
        if (source.id.?.len == 0) source.id = null;
        return source;
    }

    fn insert(self: Catalog, allocator: std.mem.Allocator, source: Source) ![]const u8 {
        const count = try self.prepare("SELECT COUNT(*) FROM user_sources");
        defer _ = c.sqlite3_finalize(count);
        if (!try stepRow(count) or c.sqlite3_column_int64(count, 0) >= MAX_SOURCES) return error.SelectsLimit;
        const stmt = try self.prepare("INSERT INTO user_sources(id,file_id,path,file_size,mtime_ns,content_hash,identity_kind,hash_algorithm,sha256,favourite) VALUES(COALESCE(?1,lower(hex(randomblob(16)))),?2,?3,?4,?5,?6,?7,?8,?9,?10) RETURNING id");
        defer _ = c.sqlite3_finalize(stmt);
        try optionalText(stmt, 1, source.id);
        try optionalInt(stmt, 2, source.file_id);
        try text(stmt, 3, source.path);
        try integer(stmt, 4, source.file_size);
        try integer(stmt, 5, source.mtime_ns);
        try integer(stmt, 6, source.content_hash);
        try integer(stmt, 7, source.identity_kind);
        try integer(stmt, 8, source.hash_algorithm);
        try optionalText(stmt, 9, source.sha256);
        try integer(stmt, 10, @intFromBool(source.favourite));
        if (!try stepRow(stmt)) return error.SelectsWriteFailed;
        const id = try allocator.dupe(u8, column(stmt, 0));
        if (try stepRow(stmt)) return error.SelectsWriteFailed;
        return id;
    }

    fn setFavourite(self: Catalog, id: []const u8, enabled: bool) !void {
        const stmt = try self.prepare("UPDATE user_sources SET favourite=? WHERE id=?");
        defer _ = c.sqlite3_finalize(stmt);
        try integer(stmt, 1, @intFromBool(enabled));
        try text(stmt, 2, id);
        try done(stmt);
    }

    fn membership(self: Catalog, id: []const u8, kind: Kind, name: []const u8, start: i64, end: i64, enabled: bool) !void {
        if (enabled) {
            const capacity = try self.prepare(if (kind == .tag)
                "SELECT COUNT(*)<256 OR EXISTS(SELECT 1 FROM user_tags WHERE source_id=?1 AND name=?2) FROM user_tags WHERE source_id=?1"
            else
                "SELECT COUNT(*)<256 OR EXISTS(SELECT 1 FROM user_collections WHERE source_id=?1 AND name=?2 AND start_ms=?3 AND end_ms=?4) FROM user_collections WHERE source_id=?1");
            defer _ = c.sqlite3_finalize(capacity);
            try text(capacity, 1, id);
            try text(capacity, 2, name);
            if (kind == .collection) {
                try integer(capacity, 3, start);
                try integer(capacity, 4, end);
            }
            if (!try stepRow(capacity) or c.sqlite3_column_int(capacity, 0) == 0) return error.SelectsLimit;
        }
        const sql = if (kind == .tag)
            (if (enabled) "INSERT OR IGNORE INTO user_tags(source_id,name) VALUES(?1,?2)" else "DELETE FROM user_tags WHERE source_id=?1 AND name=?2")
        else
            (if (enabled) "INSERT OR IGNORE INTO user_collections(source_id,name,start_ms,end_ms) VALUES(?1,?2,?3,?4)" else "DELETE FROM user_collections WHERE source_id=?1 AND name=?2 AND start_ms=?3 AND end_ms=?4");
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try text(stmt, 1, id);
        try text(stmt, 2, name);
        if (kind == .collection) {
            try integer(stmt, 3, start);
            try integer(stmt, 4, end);
        }
        try done(stmt);
    }

    pub fn edit(self: Catalog, file_id: i32, kind: Kind, name: []const u8, start: i64, end: i64, enabled: bool) !void {
        if (kind != .favourite) try validateName(name);
        if (kind != .collection and (start != -1 or end != -1)) return error.InvalidSelectsRange;
        try validateRange(start, end);
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        const source = try self.boundSource(arena.allocator(), file_id);
        const id = source.id orelse try self.insert(arena.allocator(), source);
        if (kind == .favourite) try self.setFavourite(id, enabled) else try self.membership(id, kind, name, start, end, enabled);
        try self.validateCapacity();
        try self.exec("COMMIT;");
    }

    fn resolve(self: Catalog, source: Source) !?i32 {
        const stmt = try self.prepare(if (source.sha256 != null)
            "SELECT f.id FROM file_move_identities m JOIN files f ON f.id=m.file_id WHERE m.sha256=?1 AND f.file_size=?2 LIMIT 2"
        else
            "SELECT id FROM files WHERE path=?1 AND file_size=?2 AND mtime_ns=?3 AND content_hash=?4 AND identity_kind=?5 AND hash_algorithm=?6 AND identity_kind!=0 AND file_size>=0 AND mtime_ns>=0 LIMIT 2");
        defer _ = c.sqlite3_finalize(stmt);
        if (source.sha256) |sha| {
            var digest: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&digest, sha);
            if (c.sqlite3_bind_blob(stmt, 1, &digest, digest.len, ws_sqlite_transient()) != c.SQLITE_OK) return error.SelectsBindFailed;
        } else try text(stmt, 1, source.path);
        try integer(stmt, 2, source.file_size);
        if (source.sha256 == null) {
            try integer(stmt, 3, source.mtime_ns);
            try integer(stmt, 4, source.content_hash);
            try integer(stmt, 5, source.identity_kind);
            try integer(stmt, 6, source.hash_algorithm);
        }
        if (!try stepRow(stmt)) return null;
        const id = c.sqlite3_column_int(stmt, 0);
        return if (try stepRow(stmt)) null else id;
    }

    fn existingID(self: Catalog, allocator: std.mem.Allocator, id: []const u8) !?Source {
        const stmt = try self.prepare("SELECT s.id,s.file_id,COALESCE(f.path,s.path),COALESCE(f.file_size,s.file_size),COALESCE(f.mtime_ns,s.mtime_ns),COALESCE(f.content_hash,s.content_hash),COALESCE(f.identity_kind,s.identity_kind),COALESCE(f.hash_algorithm,s.hash_algorithm),CASE WHEN f.id IS NULL THEN s.sha256 ELSE (SELECT lower(hex(sha256)) FROM file_move_identities WHERE file_id=f.id) END,s.favourite FROM user_sources s LEFT JOIN files f ON f.id=s.file_id WHERE s.id=?");
        defer _ = c.sqlite3_finalize(stmt);
        try text(stmt, 1, id);
        return if (try stepRow(stmt)) try sourceAt(allocator, stmt) else null;
    }

    fn mergeValues(self: Catalog, id: []const u8, source: Source) !void {
        if (source.favourite) try self.setFavourite(id, true);
        for (source.tags) |name| try self.membership(id, .tag, name, -1, -1, true);
        for (source.collections) |member| try self.membership(id, .collection, member.name, member.start_ms orelse -1, member.end_ms orelse -1, true);
    }

    pub fn importJSON(self: Catalog, allocator: std.mem.Allocator, bytes: []const u8) !Report {
        if (bytes.len > MAX_JSON) return error.SelectsLimit;
        var parsed = try std.json.parseFromSlice(Document, allocator, bytes, .{ .max_value_len = 4096 });
        defer parsed.deinit();
        const document = parsed.value;
        if (document.version != 1) return error.UnsupportedSelectsVersion;
        if (document.sources.len > MAX_SOURCES) return error.SelectsLimit;
        for (document.sources) |source| try validateSource(source);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        var report = Report{};
        for (document.sources) |incoming| {
            try query.check();
            var source = incoming;
            source.file_id = try self.resolve(source);
            var target: ?[]const u8 = null;
            if (source.id) |id| if (try self.existingID(a, id)) |existing| {
                if (sameReference(existing, source)) {
                    target = existing.id;
                } else {
                    // Reusing an ID for different media must retain both records.
                    source.id = null;
                    report.conflicts += 1;
                }
            };
            if (source.file_id) |file_id| {
                const bound = try self.boundSource(a, file_id);
                if (bound.id) |id| {
                    target = id;
                } else if (target) |id| {
                    const bind = try self.prepare("UPDATE user_sources SET file_id=?1,path=?2 WHERE id=?3 AND file_id IS NULL");
                    defer _ = c.sqlite3_finalize(bind);
                    try integer(bind, 1, file_id);
                    try text(bind, 2, bound.path);
                    try text(bind, 3, id);
                    try done(bind);
                }
            }
            if (target == null) {
                const duplicate = try self.prepare("SELECT id FROM user_sources WHERE path=?1 AND file_size=?2 AND mtime_ns=?3 AND content_hash=?4 AND identity_kind=?5 AND hash_algorithm=?6 AND sha256 IS ?7 ORDER BY id LIMIT 1");
                defer _ = c.sqlite3_finalize(duplicate);
                try text(duplicate, 1, source.path);
                try integer(duplicate, 2, source.file_size);
                try integer(duplicate, 3, source.mtime_ns);
                try integer(duplicate, 4, source.content_hash);
                try integer(duplicate, 5, source.identity_kind);
                try integer(duplicate, 6, source.hash_algorithm);
                try optionalText(duplicate, 7, source.sha256);
                if (try stepRow(duplicate)) target = try a.dupe(u8, column(duplicate, 0));
            }
            if (target == null) {
                target = try self.insert(a, source);
                report.imported += 1;
            } else report.merged += 1;
            try self.mergeValues(target.?, source);
            if ((try self.existingID(a, target.?)).?.file_id == null) report.unresolved += 1;
        }
        try self.validateCapacity();
        try self.exec("COMMIT;");
        return report;
    }

    pub fn seedFavourites(self: Catalog, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len > MAX_JSON) return error.SelectsLimit;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .max_value_len = 4096, .parse_numbers = false });
        defer parsed.deinit();
        const paths = try strictValue([]const []const u8, allocator, parsed.value);
        defer allocator.free(paths);
        if (paths.len > MAX_SOURCES) return error.SelectsLimit;
        for (paths) |path| try validatePath(path);
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        const state = try self.prepare("SELECT legacy_seeded FROM user_selects_state WHERE singleton=1");
        defer _ = c.sqlite3_finalize(state);
        if (!try stepRow(state)) return error.SelectsReadFailed;
        if (c.sqlite3_column_int(state, 0) == 0) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            for (paths) |path| {
                const lookup = try self.prepare("SELECT id FROM files WHERE path=?");
                defer _ = c.sqlite3_finalize(lookup);
                try text(lookup, 1, path);
                if (try stepRow(lookup)) {
                    const source = try self.boundSource(a, c.sqlite3_column_int(lookup, 0));
                    try self.setFavourite(source.id orelse try self.insert(a, source), true);
                } else _ = try self.insert(a, .{ .path = path, .favourite = true });
            }
            try self.exec("UPDATE user_selects_state SET legacy_seeded=1 WHERE singleton=1;");
        }
        try self.validateCapacity();
        try self.exec("COMMIT;");
    }

    /// Explicit user-selected link. Merge onto an existing annotated file first.
    pub fn relink(self: Catalog, allocator: std.mem.Allocator, id: []const u8, file_id: i32) !void {
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        const old = (try self.existingID(allocator, id)) orelse return error.SelectsReferenceMissing;
        if (old.file_id != null) return error.SelectsAlreadyLinked;
        var source = try self.boundSource(allocator, file_id);
        if (source.id) |target| {
            const tags = try self.prepare("INSERT OR IGNORE INTO user_tags SELECT ?1,name FROM user_tags WHERE source_id=?2");
            defer _ = c.sqlite3_finalize(tags);
            try text(tags, 1, target);
            try text(tags, 2, id);
            try done(tags);
            const members = try self.prepare("INSERT OR IGNORE INTO user_collections SELECT ?1,name,start_ms,end_ms FROM user_collections WHERE source_id=?2");
            defer _ = c.sqlite3_finalize(members);
            try text(members, 1, target);
            try text(members, 2, id);
            try done(members);
            if (old.favourite) try self.setFavourite(target, true);
            const remove = try self.prepare("DELETE FROM user_sources WHERE id=?");
            defer _ = c.sqlite3_finalize(remove);
            try text(remove, 1, id);
            try done(remove);
        } else {
            source.id = id;
            const stmt = try self.prepare("UPDATE user_sources SET file_id=?1,path=?2,file_size=?3,mtime_ns=?4,content_hash=?5,identity_kind=?6,hash_algorithm=?7,sha256=?8 WHERE id=?9");
            defer _ = c.sqlite3_finalize(stmt);
            try integer(stmt, 1, file_id);
            try text(stmt, 2, source.path);
            try integer(stmt, 3, source.file_size);
            try integer(stmt, 4, source.mtime_ns);
            try integer(stmt, 5, source.content_hash);
            try integer(stmt, 6, source.identity_kind);
            try integer(stmt, 7, source.hash_algorithm);
            try optionalText(stmt, 8, source.sha256);
            try text(stmt, 9, id);
            try done(stmt);
        }
        try self.validateCapacity();
        try self.exec("COMMIT;");
    }
};

fn sameReference(a: Source, b: Source) bool {
    if (a.sha256 != null and b.sha256 != null) return a.file_size == b.file_size and std.mem.eql(u8, a.sha256.?, b.sha256.?);
    return std.mem.eql(u8, a.path, b.path) and a.file_size == b.file_size and a.mtime_ns == b.mtime_ns and a.content_hash == b.content_hash and a.identity_kind == b.identity_kind and a.hash_algorithm == b.hash_algorithm;
}

// Identity/range numbers must be integers, never floating-point coercions.
// Keeping number tokens also avoids f128 runtime dependencies in native hosts.
fn strictValue(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) error{ OutOfMemory, InvalidNumber, UnexpectedToken, MissingField, UnknownField }!T {
    return switch (@typeInfo(T)) {
        .int => switch (value) {
            .number_string => |number| std.fmt.parseInt(T, number, 10) catch error.InvalidNumber,
            else => error.InvalidNumber,
        },
        .bool => if (value == .bool) value.bool else error.UnexpectedToken,
        .optional => |info| if (value == .null) null else try strictValue(info.child, allocator, value),
        .pointer => |info| blk: {
            if (info.child == u8) break :blk if (value == .string) value.string else error.UnexpectedToken;
            if (value != .array) return error.UnexpectedToken;
            const result = try allocator.alloc(info.child, value.array.items.len);
            for (result, value.array.items) |*dest, item| dest.* = try strictValue(info.child, allocator, item);
            break :blk result;
        },
        .@"struct" => |info| blk: {
            if (value != .object) return error.UnexpectedToken;
            var result: T = undefined;
            var known: usize = 0;
            inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                if (value.object.get(name)) |item| {
                    @field(result, name) = try strictValue(Field, allocator, item);
                    known += 1;
                } else if (attrs.defaultValue(Field)) |default| {
                    @field(result, name) = default;
                } else return error.MissingField;
            }
            if (known != value.object.count()) return error.UnknownField;
            break :blk result;
        },
        else => @compileError("Unsupported selects JSON field: " ++ @typeName(T)),
    };
}
fn jsonCost(bytes: []const u8) usize {
    var count: usize = 2;
    for (bytes) |ch| count += if (ch < 32) @as(usize, 6) else if (ch == '"' or ch == '\\') @as(usize, 2) else 1;
    return count;
}
fn charge(budget: *usize, count: usize) !void {
    if (count > budget.*) return error.SelectsLimit;
    budget.* -= count;
}
fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return error.InvalidSelectsPath;
}
fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 128 or std.mem.trim(u8, name, " \t\r\n").len == 0 or std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidSelectsName;
}
fn validateRange(start: i64, end: i64) !void {
    if (!((start == -1 and end == -1) or (start >= 0 and end > start and end <= std.math.maxInt(i32)))) return error.InvalidSelectsRange;
}
fn validateSource(source: Source) !void {
    try validatePath(source.path);
    if (source.id) |id| {
        if (id.len != 32) return error.InvalidSelectsID;
        for (id) |ch| if (!(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'))) return error.InvalidSelectsID;
    }
    if (source.sha256) |digest| {
        if (digest.len != 64 or source.file_size < 0) return error.InvalidSelectsIdentity;
        for (digest) |ch| if (!(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'))) return error.InvalidSelectsIdentity;
    }
    if (source.file_size < -1 or source.mtime_ns < -1 or source.identity_kind > 3 or source.hash_algorithm > 1) return error.InvalidSelectsIdentity;
    if (source.tags.len > 256 or source.collections.len > 256) return error.SelectsLimit;
    for (source.tags) |name| try validateName(name);
    for (source.collections) |member| {
        try validateName(member.name);
        if ((member.start_ms == null) != (member.end_ms == null)) return error.InvalidSelectsRange;
        if (member.start_ms) |start| if (start < 0) return error.InvalidSelectsRange;
        try validateRange(member.start_ms orelse -1, member.end_ms orelse -1);
    }
}
fn column(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, index) orelse return "";
    return ptr[0..@intCast(c.sqlite3_column_bytes(stmt, index))];
}
fn text(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), ws_sqlite_transient()) != c.SQLITE_OK) return error.SelectsBindFailed;
}
fn optionalText(stmt: *c.sqlite3_stmt, index: c_int, value: ?[]const u8) !void {
    if (value) |v| return text(stmt, index, v);
    if (c.sqlite3_bind_null(stmt, index) != c.SQLITE_OK) return error.SelectsBindFailed;
}
fn integer(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) return error.SelectsBindFailed;
}
fn optionalInt(stmt: *c.sqlite3_stmt, index: c_int, value: ?i32) !void {
    if (value) |v| return integer(stmt, index, v);
    if (c.sqlite3_bind_null(stmt, index) != c.SQLITE_OK) return error.SelectsBindFailed;
}
fn stepRow(stmt: *c.sqlite3_stmt) !bool {
    try query.check();
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.SelectsReadFailed,
    };
}
fn done(stmt: *c.sqlite3_stmt) !void {
    if (try stepRow(stmt)) return error.SelectsWriteFailed;
}
