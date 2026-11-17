import Foundation
import CSQLite

/// 协调器队列使用的独立SQLite连接；与原文件任务共用WAL，所有写入显式列名。
final class ClipboardRecordStore {
    private var db: OpaquePointer?
    private var cachedRecords: [ClipboardRecord]?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(root: URL) throws {
        guard sqlite3_open_v2(root.appendingPathComponent("tasks.sqlite3").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else { throw ClipboardFailure.io }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=3000;")
        try exec("""
        CREATE TABLE IF NOT EXISTS clipboard_records(seq INTEGER PRIMARY KEY AUTOINCREMENT,sourceDeviceId TEXT NOT NULL,recordId TEXT NOT NULL,sourceName TEXT NOT NULL,capturedAt INTEGER NOT NULL,receivedAt INTEGER NOT NULL,kind TEXT NOT NULL,recordJSON TEXT NOT NULL,available INTEGER NOT NULL DEFAULT 1,availabilityVersion INTEGER NOT NULL DEFAULT 0,cacheExpiresAt INTEGER NOT NULL DEFAULT 0,localTaskId TEXT NOT NULL DEFAULT '',downloadState TEXT NOT NULL DEFAULT 'none',error TEXT NOT NULL DEFAULT '',UNIQUE(sourceDeviceId,recordId));
        CREATE INDEX IF NOT EXISTS idx_clipboard_records_source ON clipboard_records(sourceDeviceId,seq);
        CREATE INDEX IF NOT EXISTS idx_clipboard_records_kind ON clipboard_records(kind,seq);
        CREATE TABLE IF NOT EXISTS clipboard_snapshots(recordId TEXT PRIMARY KEY NOT NULL,relativePath TEXT NOT NULL,createdAt INTEGER NOT NULL,expiresAt INTEGER NOT NULL,byteSize INTEGER NOT NULL,state TEXT NOT NULL DEFAULT 'ready');
        CREATE TABLE IF NOT EXISTS clipboard_previews(sourceDeviceId TEXT NOT NULL,recordId TEXT NOT NULL,payloadSha256 TEXT NOT NULL,previewSha256 TEXT NOT NULL,mimeType TEXT NOT NULL,width INTEGER NOT NULL,height INTEGER NOT NULL,byteSize INTEGER NOT NULL,relativePath TEXT NOT NULL,lastAccessedAt INTEGER NOT NULL,PRIMARY KEY(sourceDeviceId,recordId,payloadSha256));
        CREATE INDEX IF NOT EXISTS idx_clipboard_previews_access ON clipboard_previews(lastAccessedAt);
        CREATE TABLE IF NOT EXISTS clipboard_deliveries(recordId TEXT NOT NULL,peerId TEXT NOT NULL,trustGeneration TEXT NOT NULL,announcedVersion INTEGER NOT NULL DEFAULT -1,liveEpoch TEXT NOT NULL DEFAULT '',manual INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(recordId,peerId,trustGeneration));
        """)
    }
    deinit { sqlite3_close(db) }
    func exec(_ sql: String) throws {
        // 多语句执行可能部分成功；失败也不能复用写入前的历史。
        defer { cachedRecords = nil }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ClipboardFailure.io }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        // 事务体可读取并缓存未提交结果，提交和回滚后都必须重新校验DB。
        defer { cachedRecords = nil }
        try exec("BEGIN IMMEDIATE")
        do { let result = try body(); try exec("COMMIT"); return result } catch { try? exec("ROLLBACK"); throw error }
    }
    private func statement(_ sql: String, _ values: [Any]) throws -> OpaquePointer {
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw ClipboardFailure.io }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            if let value = value as? String { sqlite3_bind_text(s, index, value, -1, transient) }
            else if let value = value as? Int64 { sqlite3_bind_int64(s, index, value) }
            else if let value = value as? Int { sqlite3_bind_int64(s, index, Int64(value)) }
        }
        return s
    }
    func run(_ sql: String, _ values: [Any] = []) throws {
        defer { cachedRecords = nil }
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw ClipboardFailure.io }
    }
    private func rows(_ sql: String, _ values: [Any] = []) throws -> [[String]] {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }; var result: [[String]] = []
        while true {
            let step = sqlite3_step(s); if step == SQLITE_DONE { return result }; guard step == SQLITE_ROW else { throw ClipboardFailure.io }
            result.append((0..<sqlite3_column_count(s)).map { index in sqlite3_column_text(s, index).map { String(cString: $0) } ?? "" })
        }
    }
    private func load(_ condition: String = "", _ values: [Any] = [], limit: Int = 1001, offset: Int = 0) throws -> [ClipboardRecord] {
        try rows("SELECT seq,recordJSON,sourceName,receivedAt,available,availabilityVersion,cacheExpiresAt,localTaskId,downloadState,error FROM clipboard_records " + condition + " ORDER BY seq DESC LIMIT ? OFFSET ?", values + [limit,offset]).map { row in
            let object = try JSONSerialization.jsonObject(with: Data(row[1].utf8)) as? [String: Any] ?? [:]
            return ClipboardRecord(seq: Int64(row[0]) ?? 0, content: try ClipboardContent.parse(object), sourceName: row[2], receivedAt: Int64(row[3]) ?? 0,
                available: row[4] == "1", availabilityVersion: Int64(row[5]) ?? 0, cacheExpiresAt: Int64(row[6]) ?? 0, localTaskId: row[7], downloadState: row[8], error: row[9])
        }
    }
    func records() throws -> [ClipboardRecord] {
        if let cachedRecords { return cachedRecords }
        // 仅复用通过原DB边界完整解析的数组，保留seq倒序及1001条窗口。
        let records = try load(); cachedRecords = records; return records
    }
    /// 引用检查不能受历史页/1001条展示窗口限制。
    func references(task: FileTask, excludingRecordKey: String? = nil) throws -> Bool {
        var conditions = ["localTaskId=?"], values: [Any] = [task.id]
        if let binding = task.clipboard {
            conditions.append("(sourceDeviceId=? AND recordId=?)")
            values += [binding.sourceDeviceId, binding.recordId]
        }
        var sql = "SELECT sourceDeviceId,recordId FROM clipboard_records WHERE (" + conditions.joined(separator: " OR ") + ")"
        if let excludingRecordKey {
            sql += " AND (sourceDeviceId || ':' || recordId)<>?"; values.append(excludingRecordKey)
        }
        return try !rows(sql + " LIMIT 1", values).isEmpty
    }
    // 不带页面筛选，远端最新记录也必须打断本机相邻重复。
    func latest() throws -> ClipboardRecord? { try load(limit: 1).first }
    func find(source: String, id: String) throws -> ClipboardRecord? { try load("WHERE sourceDeviceId=? AND recordId=?", [source,id], limit: 1).first }
    private func filter(source: String, kind: String) -> (String,[Any]) {
        var conditions: [String] = [], values: [Any] = []
        if !source.isEmpty { conditions.append("sourceDeviceId=?"); values.append(source) }
        if !kind.isEmpty { conditions.append("kind=?"); values.append(kind) }
        return (conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "), values)
    }
    func page(source: String, kind: String, page: Int) throws -> [ClipboardRecord] {
        let value = filter(source: source, kind: kind); return try load(value.0, value.1, limit: 50, offset: min(1000,max(0,page * 50)))
    }
    func count(source: String, kind: String) throws -> Int {
        let value = filter(source: source, kind: kind)
        return Int(try rows("SELECT COUNT(*) FROM clipboard_records " + value.0,value.1).first?.first ?? "0") ?? 0
    }
    func save(_ record: ClipboardRecord) throws {
        let json = try JSONSerialization.data(withJSONObject: record.content.object, options: [.sortedKeys, .withoutEscapingSlashes])
        try run("""
        INSERT INTO clipboard_records(sourceDeviceId,recordId,sourceName,capturedAt,receivedAt,kind,recordJSON,available,availabilityVersion,cacheExpiresAt,localTaskId,downloadState,error) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(sourceDeviceId,recordId) DO UPDATE SET available=excluded.available,availabilityVersion=excluded.availabilityVersion,cacheExpiresAt=excluded.cacheExpiresAt,localTaskId=excluded.localTaskId,downloadState=excluded.downloadState,error=excluded.error
        """, [record.content.sourceDeviceId, record.content.recordId, record.sourceName, record.content.capturedAt, record.receivedAt, record.content.kind, String(decoding: json, as: UTF8.self), record.available ? 1 : 0, record.availabilityVersion, record.cacheExpiresAt, record.localTaskId, record.downloadState, record.error])
    }
    func snapshots() throws -> [ClipboardSnapshotIndex] {
        try rows("SELECT recordId,relativePath,createdAt,expiresAt,byteSize,state FROM clipboard_snapshots ORDER BY createdAt").map { ClipboardSnapshotIndex(recordId: $0[0], relativePath: $0[1], createdAt: Int64($0[2]) ?? 0, expiresAt: Int64($0[3]) ?? 0, byteSize: Int64($0[4]) ?? 0, state: $0[5]) }
    }
    func snapshot(id: String) throws -> ClipboardSnapshotIndex? {
        try rows("SELECT recordId,relativePath,createdAt,expiresAt,byteSize,state FROM clipboard_snapshots WHERE recordId=?", [id]).first.map {
            ClipboardSnapshotIndex(recordId: $0[0], relativePath: $0[1], createdAt: Int64($0[2]) ?? 0, expiresAt: Int64($0[3]) ?? 0, byteSize: Int64($0[4]) ?? 0, state: $0[5])
        }
    }
    func saveSnapshot(_ value: ClipboardSnapshotIndex) throws {
        try run("INSERT INTO clipboard_snapshots(recordId,relativePath,createdAt,expiresAt,byteSize,state) VALUES(?,?,?,?,?,?) ON CONFLICT(recordId) DO UPDATE SET state=excluded.state", [value.recordId,value.relativePath,value.createdAt,value.expiresAt,value.byteSize,value.state])
    }
    func grants() throws -> [ClipboardGrant] {
        try rows("SELECT recordId,peerId,trustGeneration,announcedVersion,liveEpoch,manual FROM clipboard_deliveries").map { ClipboardGrant(recordId: $0[0], peerId: $0[1], trustGeneration: $0[2], announcedVersion: Int64($0[3]) ?? -1, liveEpoch: $0[4], manual: $0[5] == "1") }
    }
    func saveGrant(_ value: ClipboardGrant) throws {
        // 重复捕获只补授权/提升明确手动许可，不能重置已确认或正在投递的进度。
        try run("INSERT INTO clipboard_deliveries(recordId,peerId,trustGeneration,announcedVersion,liveEpoch,manual) VALUES(?,?,?,?,?,?) ON CONFLICT(recordId,peerId,trustGeneration) DO UPDATE SET manual=MAX(manual,excluded.manual)", [value.recordId,value.peerId,value.trustGeneration,value.announcedVersion,value.liveEpoch,value.manual ? 1 : 0])
    }
    func remove(source: String, id: String, local: Bool) throws {
        try transaction {
            try run("DELETE FROM clipboard_records WHERE sourceDeviceId=? AND recordId=?", [source,id])
            if local { try run("DELETE FROM clipboard_deliveries WHERE recordId=?", [id]); try run("DELETE FROM clipboard_snapshots WHERE recordId=?", [id]) }
        }
    }
    func previews() throws -> [ClipboardPreviewIndex] {
        try rows("SELECT sourceDeviceId,recordId,payloadSha256,previewSha256,width,height,byteSize,relativePath,lastAccessedAt FROM clipboard_previews WHERE mimeType='image/jpeg'").map {
            ClipboardPreviewIndex(source: $0[0], record: $0[1], payloadSHA: $0[2], previewSHA: $0[3], width: Int($0[4]) ?? 0, height: Int($0[5]) ?? 0, size: Int64($0[6]) ?? 0, relativePath: $0[7], accessed: Int64($0[8]) ?? 0)
        }
    }
    func savePreview(_ index: ClipboardPreviewIndex) throws {
        try run("INSERT OR REPLACE INTO clipboard_previews(sourceDeviceId,recordId,payloadSha256,previewSha256,mimeType,width,height,byteSize,relativePath,lastAccessedAt) VALUES(?,?,?,?,?,?,?,?,?,?)", [index.source,index.record,index.payloadSHA,index.previewSHA,"image/jpeg",index.width,index.height,index.size,index.relativePath,index.accessed])
    }
    func removePreview(source: String, id: String) throws { try run("DELETE FROM clipboard_previews WHERE sourceDeviceId=? AND recordId=?", [source,id]) }

}
