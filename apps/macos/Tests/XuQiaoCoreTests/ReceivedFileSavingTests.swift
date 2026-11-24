import XCTest
import CryptoKit
import CSQLite
@testable import XuQiaoCore

/// 真实SQLite、文件系统和生产传输方法；不访问真实配对、系统剪贴板或用户接收目录。
final class ReceivedFileSavingTests: XCTestCase {
    private func sha(_ data: Data) -> String { Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined() }
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xq-receive-" + UUID().uuidString)
        let control = UUID()
        var engine: FileTransferEngine!
        let lock = NSLock()
        private var latest = FileTransferSnapshot()
        private var sent: [[String: Any]] = []
        var folder: URL { root.appendingPathComponent("public", isDirectory: true) }
        var store: URL { root.appendingPathComponent("store", isDirectory: true) }
        init(start: Bool = true, broken: Bool = false) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if broken { try Data("not a directory".utf8).write(to: folder) }
            if start { try restart() }
        }
        func restart() throws {
            engine = nil
            var config = ServerConfiguration(); config.fileStoreDirectory = store.path
            engine = try FileTransferEngine(configuration: config, send: { [weak self] _, packet, _ in
                guard let self else { return }; self.lock.lock(); self.sent.append(packet); self.lock.unlock()
            }, close: { _ in }, resume: { _ in }, changed: { [weak self] value in
                guard let self else { return }; self.lock.lock(); self.latest = value; self.lock.unlock()
            }, receiveFolder: ReceiveFolderLocation(path: folder.path, createsDirectory: true))
            message(["type": "file.hello", "protocol": "xq-file/1", "groupProtocol": "xq-group/1", "maxConcurrentFiles": 3, "maxConcurrentClipboard": 1])
        }
        var state: FileTransferSnapshot { lock.lock(); defer { lock.unlock() }; return latest }
        var packets: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return sent }
        func message(_ packet: [String: Any]) {
            let done = DispatchSemaphore(value: 0); engine.control(peer: "phone", channel: control, message: packet) { done.signal() }
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        }
        func receive(_ bytes: Data, name: String = "received.txt", extra: [String: Any] = [:]) -> (String, String) {
            let id = UUID().uuidString.lowercased(), attempt = UUID().uuidString.lowercased()
            var packet: [String: Any] = ["type": "file.offer", "taskId": id, "attemptId": attempt, "name": name,
                "size": bytes.count, "sha256": Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined()]
            packet.merge(extra) { _, new in new }; message(packet)
            engine.accept(id, expectedAttempt: attempt)
            let channel = UUID(); engine.bind(peer: "phone", control: control, channel: channel, server: "mac", id: id, attempt: attempt, direction: "upload")
            for offset in stride(from: 0, to: bytes.count, by: FILE_CHUNK_SIZE) {
                let chunk = bytes.subdata(in: offset..<min(bytes.count, offset + FILE_CHUNK_SIZE))
                engine.data(channel: channel, message: ["type": "file.chunk", "taskId": id, "attemptId": attempt, "offset": offset, "data": chunk.base64EncodedString()])
            }
            engine.data(channel: channel, message: ["type": "file.end", "taskId": id, "attemptId": attempt])
            return (id, attempt)
        }
        func setFolder(_ url: URL) -> String? {
            let done = DispatchSemaphore(value: 0); var error: String?
            engine.setReceiveFolder(url) { error = $0; done.signal() }; XCTAssertEqual(done.wait(timeout: .now() + 5), .success); return error
        }
        func locations(_ id: String, _ attempt: String) -> ([URL]?, String?) {
            let done = DispatchSemaphore(value: 0); var result: ([URL]?, String?) = (nil, nil)
            engine.receivedLocations(id, expectedAttempt: attempt) { result = ($0, $1); done.signal() }
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success); return result
        }
        deinit { engine = nil; try? FileManager.default.removeItem(at: root) }
    }
    @discardableResult private func until(_ message: String, _ predicate: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(8)
        while Date() < end { if predicate() { return true }; Thread.sleep(forTimeInterval: 0.005) }
        XCTFail(message); return false
    }
    private func saved(_ fixture: Fixture, _ id: String) -> FileTaskView? {
        until("automatic copy did not finish") { fixture.state.tasks.contains { $0.id == id && $0.receivedSaveState == "saved" && !$0.managementBusy } }
        return fixture.state.tasks.first { $0.id == id }
    }
    func testSingleFileAutoSavesAndCollisionNeverOverwrites() throws {
        let f = try Fixture(); let bytes = Data("new bytes".utf8)
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: f.folder.appendingPathComponent("received.txt"))
        let (id, attempt) = f.receive(bytes); XCTAssertEqual(saved(f, id)?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: f.folder.appendingPathComponent("received.txt")), Data("keep me".utf8))
        XCTAssertEqual(try Data(contentsOf: f.folder.appendingPathComponent("received (2).txt")), bytes)
        let urls = try XCTUnwrap(f.locations(id, attempt).0); XCTAssertEqual(urls.map(\.lastPathComponent), ["received (2).txt"])
        XCTAssertTrue(f.packets.contains { $0["type"] as? String == "file.complete" })
    }
    func testDuplicateOfferAndRestartDoNotCreateAnotherCopy() throws {
        let f = try Fixture(); let bytes = Data("once".utf8); let (id, attempt) = f.receive(bytes); _ = saved(f, id)
        f.message(["type": "file.offer", "taskId": id, "attemptId": attempt, "name": "received.txt", "size": bytes.count, "sha256": sha(bytes)])
        try f.restart()
        until("saved receipt not restored") { f.state.tasks.first { $0.id == id }?.receivedSaveState == "saved" }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.folder.path), ["received.txt"])
        XCTAssertEqual(f.locations(id, attempt).0?.count, 1)
    }
    func testSaveFailureKeepsCompletedPrivateFileAndExplicitRetryUsesNewFolder() throws {
        let f = try Fixture(broken: true); let bytes = Data("private retained".utf8); let (id, attempt) = f.receive(bytes)
        until("failure did not surface") { f.state.tasks.first { $0.id == id }?.receivedSaveState == "failed" }
        XCTAssertEqual(f.state.tasks.first { $0.id == id }?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: f.store.appendingPathComponent("Received/" + id + "/received.txt")), bytes)
        XCTAssertFalse(f.packets.contains { $0["type"] as? String == "file.error" })
        let alternate = f.root.appendingPathComponent("chosen"); try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
        XCTAssertNil(f.setFolder(alternate)); f.engine.retryReceivedSave(id, expectedAttempt: attempt); _ = saved(f, id)
        XCTAssertEqual(try Data(contentsOf: alternate.appendingPathComponent("received.txt")), bytes)
    }
    func testChangingFolderDoesNotMoveOrReexportEarlierFiles() throws {
        let f = try Fixture(); let first = f.receive(Data("first".utf8)); _ = saved(f, first.0)
        let alternate = f.root.appendingPathComponent("second-folder"); try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
        XCTAssertNil(f.setFolder(alternate))
        let second = f.receive(Data("second".utf8)); _ = saved(f, second.0)
        XCTAssertEqual(f.locations(first.0, first.1).0?.first?.deletingLastPathComponent().standardizedFileURL, f.folder.standardizedFileURL)
        XCTAssertEqual(f.locations(second.0, second.1).0?.first?.deletingLastPathComponent().standardizedFileURL, alternate.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: f.folder.appendingPathComponent("received.txt")), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: alternate.appendingPathComponent("received.txt")), Data("second".utf8))
    }
    func testSavedFileCanBeEditedButDeletedFileIsNotSilentlyCopiedAgain() throws {
        let f = try Fixture(); let (id, attempt) = f.receive(Data("original".utf8)); _ = saved(f, id)
        let output = f.folder.appendingPathComponent("received.txt"); try Data("user edited".utf8).write(to: output)
        XCTAssertEqual(f.locations(id, attempt).0?.first, output)
        XCTAssertNil(f.locations(id, UUID().uuidString.lowercased()).0)
        try FileManager.default.removeItem(at: output)
        XCTAssertNil(f.locations(id, attempt).0); XCTAssertNotNil(f.locations(id, attempt).1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testFolderBookmarkAndPreferenceRoundTrip() throws {
        let f = try Fixture(start: false), suite = "xq-folder-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let selected = try ReceiveFolderLocation.selected(f.root); try selected.persist(defaults: defaults)
        let restored = try ReceiveFolderLocation.load(defaults: defaults); XCTAssertEqual(restored, selected)
        let access = try ReceiveFolderAccess(restored, create: false); XCTAssertEqual(access.url.standardizedFileURL, f.root.standardizedFileURL)
        defaults.set(Data("bad json".utf8), forKey: ReceiveFolderLocation.preferenceKey)
        XCTAssertThrowsError(try ReceiveFolderLocation.load(defaults: defaults))
    }
    func testOldCompletedHistoryStaysInternalWhilePendingResumesAndSavingRequiresRetry() throws {
        for mode in ["legacy", "pending", "saving"] {
            let f = try Fixture(start: false), storage = try FileStorage(directory: f.store.path)
            let bytes = Data(mode.utf8), id = UUID().uuidString.lowercased(), attempt = UUID().uuidString.lowercased()
            var task = FileTask(id: id, peerId: "phone", direction: .incoming, name: "old.txt", size: Int64(bytes.count), sha256: sha(bytes), sourcePath: "", destinationPath: "", state: .completed, progress: Int64(bytes.count), attemptId: attempt, updatedAt: Date(), error: nil)
            task.destinationPath = storage.final(task).path
            if mode != "legacy" { task.receivedSave = ReceivedFileSaveReceipt(attempt: attempt, state: mode == "pending" ? .pending : .saving) }
            try storage.ensureReceived(task); try bytes.write(to: storage.final(task))
            try FileTaskStore(url: storage.root.appendingPathComponent("tasks.sqlite3")).save(task)
            try f.restart(); until("history missing") { f.state.tasks.contains { $0.id == id } }
            if mode == "pending" { _ = saved(f, id); XCTAssertTrue(FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("old.txt").path)) }
            else {
                XCTAssertEqual(f.state.tasks.first { $0.id == id }?.receivedSaveState, mode == "legacy" ? nil : "failed")
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("old.txt").path))
                if mode == "legacy" { XCTAssertEqual(f.locations(id, attempt).0?.first?.path, task.destinationPath) }
            }
        }
    }
    func testFileGroupAndDirectoryAutoSavePreservesStructureAndCollisionNames() throws {
        let f = try Fixture(), album = f.root.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: album.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: album.appendingPathComponent("one.jpg"))
        let text = f.root.appendingPathComponent("note.txt"); try Data("note".utf8).write(to: text)
        let done = DispatchSemaphore(value: 0); var failure: String?
        f.engine.prepareMany(peer: "phone", sources: [album, text]) { failure = $0; done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success); XCTAssertNil(failure)
        until("group offer missing") { f.packets.contains { $0["type"] as? String == "file.offer" && $0["kind"] as? String == "group" } }
        var offer = try XCTUnwrap(f.packets.first { $0["type"] as? String == "file.offer" && $0["kind"] as? String == "group" })
        let sourceID = try XCTUnwrap(offer["taskId"] as? String)
        let archive = try Data(contentsOf: f.store.appendingPathComponent("Staging/" + sourceID + "/source"))
        ["type", "taskId", "attemptId", "v"].forEach { offer.removeValue(forKey: $0) }
        try FileManager.default.createDirectory(at: f.folder.appendingPathComponent("Album"), withIntermediateDirectories: true)
        let (id, attempt) = f.receive(archive, name: "文件组", extra: offer); XCTAssertEqual(saved(f, id)?.kind, "group")
        XCTAssertEqual(try Data(contentsOf: f.folder.appendingPathComponent("Album (2)/one.jpg")), Data("photo".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("Album (2)/empty").path))
        XCTAssertEqual(try Data(contentsOf: f.folder.appendingPathComponent("note.txt")), Data("note".utf8))
        XCTAssertEqual(Set(try XCTUnwrap(f.locations(id, attempt).0).map(\.lastPathComponent)), ["Album (2)", "note.txt"])
    }
    func testNewClipboardReceiveDoesNotAutoSaveInOrdinaryFolder() throws {
        let f = try Fixture(), bytes = Data("clipboard".utf8)
        let record = String(repeating: "c", count: 32), request = String(repeating: "d", count: 32), name = "clipboard.txt"
        let storage = try FileStorage(directory: f.store.path)
        let content = ClipboardContent(recordId: record, sourceDeviceId: "phone", capturedAt: 1, kind: "file", name: name, size: Int64(bytes.count), sha256: sha(bytes), mimeType: "application/octet-stream")
        try ClipboardRecordStore(root: storage.root).save(ClipboardRecord(content: content, sourceName: "phone", receivedAt: 1))
        f.engine.setClipboardTrust(peer: "phone", generation: "g")
        f.engine.registerClipboardRequest(ClipboardBinding(sourceDeviceId: "phone", recordId: record, downloadRequestId: request, trustGeneration: "g"), control: f.control)
        let (id, _) = f.receive(bytes, name: name, extra: ["clipboardRecordId": record, "clipboardRequestId": request])
        until("clipboard receive did not finish") { f.state.tasks.first { $0.id == id }?.state == .completed }
        XCTAssertEqual(f.state.tasks.first { $0.id == id }?.state, .completed, String(describing: f.packets.filter { $0["type"] as? String == "file.error" }))
        XCTAssertNil(f.state.tasks.first { $0.id == id }?.receivedSaveState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.root.appendingPathComponent("Received/" + id + "/" + name).path))
    }
    func testExplicitMediaDownloadDoesNotDuplicateOrdinaryAutoSave() throws {
        let f = try Fixture(), bytes = Data("media".utf8), name = "media.jpg"
        let binding = MediaBinding(peerId: "phone", trustGeneration: "g", controlId: f.control.uuidString,
            grantId: String(repeating: "a", count: 32), assetId: String(repeating: "b", count: 32), requestId: String(repeating: "e", count: 32))
        f.engine.setClipboardTrust(peer: "phone", generation: "g")
        let done = DispatchSemaphore(value: 0); var registered = false
        f.engine.registerMediaRequest(binding, control: f.control, name: name, size: Int64(bytes.count)) { registered = $0; done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success); XCTAssertTrue(registered)
        let (id, _) = f.receive(bytes, name: name, extra: ["mediaGrantId": binding.grantId, "mediaAssetId": binding.assetId, "mediaRequestId": binding.requestId])
        until("media receive did not finish") { f.state.tasks.first { $0.id == id }?.state == .completed }
        XCTAssertEqual(f.state.tasks.first { $0.id == id }?.mediaRequestId, binding.requestId)
        XCTAssertNil(f.state.tasks.first { $0.id == id }?.receivedSaveState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.folder.path))
    }
    func testSavingStatePersistenceFailureCanRetryWithoutRestart() throws {
        let f = try Fixture(); var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(f.store.appendingPathComponent("tasks.sqlite3").path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        let trigger = """
        CREATE TRIGGER reject_saving BEFORE INSERT ON file_tasks
        WHEN NEW.receivedSaveJSON LIKE '%"state":"saving"%'
        BEGIN SELECT RAISE(ABORT, 'test saving write failure'); END;
        """
        XCTAssertEqual(sqlite3_exec(db, trigger, nil, nil, nil), SQLITE_OK)
        let bytes = Data("retry without restarting".utf8), (id, attempt) = f.receive(Data("retry without restarting".utf8))
        until("failed state must be visible and retryable") {
            f.state.tasks.contains { $0.id == id && $0.receivedSaveState == "failed" && !$0.managementBusy }
        }
        XCTAssertEqual(f.state.tasks.first { $0.id == id }?.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.folder.path), "copy must not start before saving intent is durable")
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER reject_saving", nil, nil, nil), SQLITE_OK)
        f.engine.retryReceivedSave(id, expectedAttempt: attempt); _ = saved(f, id)
        XCTAssertEqual(try Data(contentsOf: f.folder.appendingPathComponent("received.txt")), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.folder.path), ["received.txt"])
    }
}
