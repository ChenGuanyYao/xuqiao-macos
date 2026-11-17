import Foundation
import CSQLite

/// 仅在传输引擎串行队列使用；完整提交收据使用 SQLite FULL 同步持久化。
final class FileTaskStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            sqlite3_close(database); database = nil; throw FileFailure.io
        }
        do {
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=3000;")
        try exec("""
        CREATE TABLE IF NOT EXISTS file_private_images_cleared(taskId TEXT PRIMARY KEY NOT NULL);
        CREATE TABLE IF NOT EXISTS file_public_exports(taskId TEXT NOT NULL,path TEXT NOT NULL,size INTEGER NOT NULL,sha256 TEXT NOT NULL,PRIMARY KEY(taskId,path));
        CREATE TABLE IF NOT EXISTS file_task_visibility(taskId TEXT PRIMARY KEY NOT NULL,hiddenAt INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS file_tasks (
        id TEXT PRIMARY KEY NOT NULL, peerId TEXT NOT NULL, direction TEXT NOT NULL, name TEXT NOT NULL,
        size INTEGER NOT NULL, sha256 TEXT NOT NULL, sourcePath TEXT NOT NULL, destinationPath TEXT NOT NULL,
        state TEXT NOT NULL, progress INTEGER NOT NULL, attemptId TEXT NOT NULL, updatedAt REAL NOT NULL, error TEXT);
        """)
        var columns = Set<String>()
        var inspection: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(file_tasks)", -1, &inspection, nil) == SQLITE_OK else { throw FileFailure.io }
        while sqlite3_step(inspection) == SQLITE_ROW {
            if let raw = sqlite3_column_text(inspection, 1) { columns.insert(String(cString: raw).lowercased()) }
        }
        sqlite3_finalize(inspection)
        if !columns.contains("clipboardjson") { try exec("ALTER TABLE file_tasks ADD COLUMN clipboardJSON TEXT NOT NULL DEFAULT ''") }
        if !columns.contains("mediajson") { try exec("ALTER TABLE file_tasks ADD COLUMN mediaJSON TEXT NOT NULL DEFAULT ''") }
        if !columns.contains("groupjson") { try exec("ALTER TABLE file_tasks ADD COLUMN groupJSON TEXT") }
        if !columns.contains("imagepreviewjson") { try exec("ALTER TABLE file_tasks ADD COLUMN imagePreviewJSON TEXT") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { sqlite3_close(database) }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw FileFailure.io }
    }
    func all() throws -> [FileTask] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id,peerId,direction,name,size,sha256,sourcePath,destinationPath,state,progress,attemptId,updatedAt,error,groupJSON,clipboardJSON,mediaJSON,imagePreviewJSON FROM file_tasks", -1, &statement, nil) == SQLITE_OK else { throw FileFailure.io }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String {
            guard let raw = sqlite3_column_text(statement, column) else { return "" }; return String(cString: raw)
        }
        var rows: [FileTask] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW, let direction = FileTaskDirection(rawValue: text(2)), let state = FileTaskState(rawValue: text(8)),
                  fileID(text(0)) != nil, fileID(text(10)) != nil, fileName(text(3)) != nil, validHex(text(5)) else { throw FileFailure(code: "FILE_IO", message: "文件任务库记录无法读取") }
            let size = sqlite3_column_int64(statement, 4), progress = sqlite3_column_int64(statement, 9)
            guard (0...FILE_MAX_SIZE).contains(size), (0...size).contains(progress) else { throw FileFailure.io }
            var task = FileTask(id: text(0), peerId: text(1), direction: direction, name: text(3), size: size, sha256: text(5), sourcePath: text(6), destinationPath: text(7), state: state, progress: progress, attemptId: text(10), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)), error: sqlite3_column_type(statement, 12) == SQLITE_NULL ? nil : text(12))
            if sqlite3_column_type(statement, 13) != SQLITE_NULL, !text(13).isEmpty {
                let data = Data(text(13).utf8); guard data.count <= GROUP_MAX_METADATA else { throw FileFailure.io }
                let group = try JSONDecoder().decode(GroupMetadata.self, from: data)
                _ = try GroupMetadata.parse(group.offerFields)
                if !group.entries.isEmpty { _ = try validateGroupEntries(group.entries, expected: group) }
                task.group = group
            }
            if !text(14).isEmpty {
                let data = Data(text(14).utf8); guard data.count <= 2048 else { throw FileFailure.io }
                let binding = try JSONDecoder().decode(ClipboardBinding.self, from: data)
                guard binding.valid else { throw FileFailure.io }; task.clipboard = binding
            }
            if !text(15).isEmpty {
                let data = Data(text(15).utf8); guard data.count <= 4096 else { throw FileFailure.io }
                let binding = try JSONDecoder().decode(MediaBinding.self, from:data)
                guard binding.valid, task.clipboard == nil, binding.peerId == task.peerId, task.group == nil else { throw FileFailure.io }; task.media = binding
            }
            if task.group == nil, task.clipboard == nil, task.media == nil, FileOfferImagePreview.imageName(task.name) {
                let encoded = text(16)
                // 缩图是可选附加信息，坏缩图不能阻断原件历史恢复。
                if encoded.utf8.count <= 34_816, let value = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) {
                    task.imagePreview = FileOfferImagePreview.parse(value)
                }
            }
            rows.append(task)
        }
    }
    func save(_ task: FileTask, showHistory: Bool = false, restoringPrivateImage: Bool = false) throws {
        guard showHistory || restoringPrivateImage else { try saveRow(task); return }
        try exec("BEGIN IMMEDIATE")
        do {
            try saveRow(task)
            if showHistory { try show(task.id) }
            // 新原件可靠完成与旧清理标记必须一起提交，失败时保留原committing日志供恢复。
            if restoringPrivateImage { try restorePrivateImage(task.id) }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    private func saveRow(_ task: FileTask) throws {
        var statement: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO file_tasks(id,peerId,direction,name,size,sha256,sourcePath,destinationPath,state,progress,attemptId,updatedAt,error,groupJSON,clipboardJSON,mediaJSON,imagePreviewJSON) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw FileFailure.io }
        defer { sqlite3_finalize(statement) }
        func text(_ position: Int32, _ value: String) { _ = sqlite3_bind_text(statement, position, value, -1, transient) }
        text(1, task.id); text(2, task.peerId); text(3, task.direction.rawValue); text(4, task.name)
        sqlite3_bind_int64(statement, 5, task.size); text(6, task.sha256); text(7, task.sourcePath); text(8, task.destinationPath)
        text(9, task.state.rawValue); sqlite3_bind_int64(statement, 10, task.progress); text(11, task.attemptId)
        sqlite3_bind_double(statement, 12, task.updatedAt.timeIntervalSince1970)
        if let error = task.error { text(13, error) } else { sqlite3_bind_null(statement, 13) }
        if let group = task.group {
            let data = try JSONEncoder().encode(group)
            guard data.count <= GROUP_MAX_METADATA else { throw FileFailure.io }
            text(14, String(decoding: data, as: UTF8.self))
        } else { sqlite3_bind_null(statement, 14) }
        if let binding = task.clipboard {
            text(15, String(decoding: try JSONEncoder().encode(binding), as: UTF8.self))
        } else { text(15, "") }
        if let media = task.media { text(16,String(decoding:try JSONEncoder().encode(media),as:UTF8.self)) } else {text(16,"")}
        if let preview = task.imagePreview { text(17, String(decoding: try JSONSerialization.data(withJSONObject: preview.wireFields, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)) }
        else { sqlite3_bind_null(statement, 17) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FileFailure.io }
    }
    /// 只记录已完整校验并同步的公共成品；清理原图时还需重新校验文件，不能仅凭历史成功标记。
    func recordPublicExport(_ task: FileTask, url: URL) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO file_public_exports(taskId,path,size,sha256) VALUES(?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw FileFailure.io }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, task.id, -1, transient); sqlite3_bind_text(statement, 2, url.path, -1, transient)
        sqlite3_bind_int64(statement, 3, task.size); sqlite3_bind_text(statement, 4, task.sha256, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FileFailure.io }
    }
    func publicExportPaths(_ task: FileTask) throws -> [URL] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT path FROM file_public_exports WHERE taskId=? AND size=? AND sha256=?", -1, &statement, nil) == SQLITE_OK else { throw FileFailure.io }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, task.id, -1, transient); sqlite3_bind_int64(statement, 2, task.size); sqlite3_bind_text(statement, 3, task.sha256, -1, transient)
        var values: [URL] = []
        while true {
            let step = sqlite3_step(statement); if step == SQLITE_DONE { return values }
            guard step == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { throw FileFailure.io }
            values.append(URL(fileURLWithPath: String(cString: raw)))
        }
    }
    func markPrivateImageCleared(_ id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO file_private_images_cleared(taskId) VALUES(?)", -1, &statement, nil) == SQLITE_OK else { throw FileFailure.io }
        defer { sqlite3_finalize(statement) }; sqlite3_bind_text(statement, 1, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FileFailure.io }
    }
    func restorePrivateImage(_ id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM file_private_images_cleared WHERE taskId=?", -1, &statement, nil) == SQLITE_OK else { throw FileFailure.io }
        defer { sqlite3_finalize(statement) }; sqlite3_bind_text(statement, 1, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FileFailure.io }
    }
    func clearedPrivateImages() throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT taskId FROM file_private_images_cleared", -1, &statement, nil) == SQLITE_OK else { throw FileFailure.io }
        defer { sqlite3_finalize(statement) }; var values = Set<String>()
        while true {
            let step = sqlite3_step(statement); if step == SQLITE_DONE { return values }
            guard step == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { throw FileFailure.io }
            values.insert(String(cString: raw))
        }
    }
    func hiddenIDs() throws -> Set<String> {
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, "SELECT taskId FROM file_task_visibility", -1, &statement, nil) == SQLITE_OK else { throw FileFailure.io }
        defer { sqlite3_finalize(statement) }; var result = Set<String>()
        while true {
            let code = sqlite3_step(statement); if code == SQLITE_DONE { return result }; guard code == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw FileFailure.io }
            result.insert(String(cString: value))
        }
    }
    private func show(_ id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM file_task_visibility WHERE taskId=?", -1, &statement, nil) == SQLITE_OK else { throw FileFailure.io }
        defer { sqlite3_finalize(statement) }; sqlite3_bind_text(statement, 1, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FileFailure.io }
    }
    func hide(_ id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO file_task_visibility(taskId,hiddenAt) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK else { throw FileFailure.io }
        defer { sqlite3_finalize(statement) }; sqlite3_bind_text(statement, 1, id, -1, transient); sqlite3_bind_int64(statement, 2, milliseconds())
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FileFailure.io }
    }

}
