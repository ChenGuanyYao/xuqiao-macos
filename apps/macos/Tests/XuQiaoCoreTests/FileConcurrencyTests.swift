import XCTest
import CryptoKit
@testable import XuQiaoCore

/// 直接使用真实任务库、稳定发送副本和数据流；控制与数据帧由隔离对端驱动，不启动服务或访问系统剪贴板。
final class FileConcurrencyTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xq-concurrency-" + UUID().uuidString)
        let control = UUID()
        let lock = NSLock()
        var engine: FileTransferEngine!
        private var snapshot = FileTransferSnapshot()
        private var sent: [(UUID, [String: Any])] = []
        init(modern: Bool = true, connected: Bool = true, busyRetryDelays: [TimeInterval] = [2, 4, 8, 16, 30]) throws {
            var config = ServerConfiguration(); config.fileStoreDirectory = root.appendingPathComponent("store").path
            engine = try FileTransferEngine(configuration: config, send: { [weak self] channel, message, _ in
                guard let self else { return }; self.lock.lock(); self.sent.append((channel, message)); self.lock.unlock()
            }, close: { _ in }, resume: { _ in }, changed: { [weak self] snapshot in
                guard let self else { return }; self.lock.lock(); self.snapshot = snapshot; self.lock.unlock()
            }, busyRetryDelays: busyRetryDelays)
            if connected { hello(modern: modern) }
        }
        func hello(modern: Bool = true, channel: UUID? = nil) {
            var value: [String: Any] = ["type": "file.hello", "protocol": "xq-file/1"]
            if modern { value["maxConcurrentFiles"] = 3; value["maxConcurrentClipboard"] = 1 }
            message(value, channel: channel)
        }
        func message(_ value: [String: Any], channel: UUID? = nil) {
            let done = DispatchSemaphore(value: 0)
            engine.control(peer: "phone", channel: channel ?? control, message: value) { done.signal() }
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        }
        var state: FileTransferSnapshot { lock.lock(); defer { lock.unlock() }; return snapshot }
        func packets(_ type: String, channel: UUID? = nil) -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return sent.filter { $0.1["type"] as? String == type && (channel == nil || channel == $0.0) }.map { $0.1 }
        }
        func source(_ name: String = UUID().uuidString, bytes: Data = Data("payload".utf8)) throws -> URL {
            let url = root.appendingPathComponent(name + ".bin"); try bytes.write(to: url); return url
        }
        @discardableResult func prepare(_ url: URL) -> String? {
            let done = DispatchSemaphore(value: 0); var error: String?
            engine.prepareSend(peer: "phone", source: url) { error = $0; done.signal() }
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success); return error
        }
        @discardableResult func prepareClipboard(bytes: Data = Data("clipboard".utf8)) throws -> String? {
            let url = try source(bytes: bytes)
            let content = ClipboardContent(recordId: String(repeating: "a", count: 32), sourceDeviceId: "mac", capturedAt: 1,
                kind: "file", name: url.lastPathComponent, size: Int64(bytes.count), sha256: digest(bytes), mimeType: "application/octet-stream")
            let binding = ClipboardBinding(sourceDeviceId: "mac", recordId: content.recordId, downloadRequestId: String(repeating: "b", count: 32), trustGeneration: "g")
            engine.setClipboardTrust(peer: "phone", generation: "g")
            let done = DispatchSemaphore(value: 0); var error: String?
            engine.prepareClipboardSend(peer: "phone", control: control, content: content, binding: binding, snapshot: url) { error = $0; done.signal() }
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success); return error
        }
        @discardableResult func incoming(bytes: Data = Data("incoming".utf8), clipboard: Bool = false) throws -> (String, String) {
            let id = UUID().uuidString.lowercased(), attempt = UUID().uuidString.lowercased()
            var fields: [String: Any] = ["type": "file.offer", "taskId": id, "attemptId": attempt, "name": id + ".bin", "size": bytes.count, "sha256": digest(bytes)]
            if clipboard {
                let record = String(repeating: "c", count: 32), request = String(repeating: "d", count: 32)
                let content = ClipboardContent(recordId: record, sourceDeviceId: "phone", capturedAt: 1, kind: "file", name: id + ".bin", size: Int64(bytes.count), sha256: digest(bytes), mimeType: "application/octet-stream")
                let storage = try FileStorage(directory: root.appendingPathComponent("store").path)
                try ClipboardRecordStore(root: storage.root).save(ClipboardRecord(content: content, sourceName: "phone", receivedAt: 1))
                engine.setClipboardTrust(peer: "phone", generation: "g")
                engine.registerClipboardRequest(ClipboardBinding(sourceDeviceId: "phone", recordId: record, downloadRequestId: request, trustGeneration: "g"), control: control)
                fields["clipboardRecordId"] = record; fields["clipboardRequestId"] = request
            }
            message(fields); return (id, attempt)
        }
        func bind(_ task: FileTaskView, control: UUID? = nil) -> UUID {
            let channel = UUID()
            if task.direction == .outgoing { message(["type": "file.accept", "taskId": task.id, "attemptId": task.attemptId], channel: control) }
            else { engine.accept(task.id, expectedAttempt: task.attemptId) }
            engine.bind(peer: "phone", control: control ?? self.control, channel: channel, server: "mac", id: task.id, attempt: task.attemptId,
                direction: task.direction == .outgoing ? "download" : "upload")
            return channel
        }
        func close() { engine = nil }
        deinit { try? FileManager.default.removeItem(at: root) }
    }
    @discardableResult private func until(_ message: String, _ predicate: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end { if predicate() { return true }; Thread.sleep(forTimeInterval: 0.005) }
        XCTFail(message); return false
    }
    func testCapabilityRequiresIntegerAndFallsBackForOldPeer() throws {
        XCTAssertTrue(try FileConcurrencyLimits(hello: [:]).legacy)
        XCTAssertTrue(try FileConcurrencyLimits(hello: ["maxConcurrentFiles": 3]).legacy)
        XCTAssertFalse(try FileConcurrencyLimits(hello: ["maxConcurrentFiles": 3, "maxConcurrentClipboard": 1]).legacy)
        for invalid in [true, 0, 4, 1.5, 3.0, "3", NSNull()] as [Any] {
            XCTAssertThrowsError(try FileConcurrencyLimits(hello: ["maxConcurrentFiles": invalid, "maxConcurrentClipboard": 1]))
        }
        XCTAssertThrowsError(try FileConcurrencyLimits(hello: ["maxConcurrentFiles": 3, "maxConcurrentClipboard": 2]))
    }
    func testThreeRealOutgoingStreamsOverlapAndQueuedTaskContinues() throws {
        let f = try Fixture(); defer { f.close() }
        for i in 0..<4 { XCTAssertNil(f.prepare(try f.source("file-\(i)", bytes: Data(repeating: UInt8(i), count: 1024)))) }
        until("3 offers and one persistent queue expected") { f.packets("file.offer").count == 3 && f.state.tasks.filter { $0.state == .queued }.count == 1 }
        let tasks = f.state.tasks.filter { $0.state == .waitingAcceptance }
        let channels = tasks.map { f.bind($0) }
        until("all 3 streams should be open concurrently") { f.state.tasks.filter { $0.state == .transferring }.count == 3 && channels.allSatisfy { f.packets("file.chunk", channel: $0).count == 1 } }
        for (task, channel) in zip(tasks, channels) {
            let packet = try XCTUnwrap(f.packets("file.chunk", channel: channel).first)
            let bytes = try XCTUnwrap(Data(base64Encoded: packet["data"] as! String))
            XCTAssertEqual(digest(bytes), task.sha256)
        }
        let first = tasks[0], channel = channels[0]
        f.engine.data(channel: channel, message: ["type": "file.chunkAck", "taskId": first.id, "attemptId": first.attemptId, "offset": first.size])
        until("first stream did not finish independently") { f.packets("file.end", channel: channel).count == 1 }
        f.engine.data(channel: channel, message: ["type": "file.complete", "taskId": first.id, "attemptId": first.attemptId, "size": first.size, "sha256": first.sha256])
        until("released slot did not start fourth task") { f.packets("file.offer").count == 4 }
        XCTAssertEqual(f.state.tasks.filter { $0.state == .transferring }.count, 2)
        XCTAssertEqual(f.state.tasks.first { $0.id == first.id }?.state, .completed)
    }
    func testClipboardHasIndependentLaneInBothDirectionsWithEightBoundStreams() throws {
        let f = try Fixture(); defer { f.close() }
        for _ in 0..<3 { XCTAssertNil(f.prepare(try f.source())); _ = try f.incoming() }
        XCTAssertNil(try f.prepareClipboard()); let clip = try f.incoming(clipboard: true)
        until("all eight independent reservations expected") { f.state.tasks.count == 8 && f.packets("file.offer").count == 4 }
        XCTAssertTrue(f.state.canPrepareSend(peerID: "phone"), "clipboard or another transfer must not disable ordinary send")
        let tasks = f.state.tasks
        let channels = tasks.map { f.bind($0) }
        until("eight independent data streams did not overlap") { f.state.tasks.filter { $0.state == .transferring }.count == 8 && f.packets("file.ready").count == 8 }
        let incomingClip = try XCTUnwrap(tasks.first { $0.id == clip.0 })
        let index = try XCTUnwrap(tasks.firstIndex { $0.id == incomingClip.id })
        let bytes = Data("incoming".utf8)
        f.engine.data(channel: channels[index], message: ["type": "file.chunk", "taskId": clip.0, "attemptId": clip.1, "offset": 0, "data": bytes.base64EncodedString()])
        until("clipboard ACK missing") { f.packets("file.chunkAck", channel: channels[index]).count == 1 }
        f.engine.data(channel: channels[index], message: ["type": "file.end", "taskId": clip.0, "attemptId": clip.1])
        until("clipboard did not commit") { f.state.tasks.first { $0.id == clip.0 }?.state == .completed }
        XCTAssertEqual(f.state.tasks.filter { $0.state == .transferring }.count, 7)
        XCTAssertTrue(f.state.tasks.filter { $0.clipboardRecordId != nil }.allSatisfy { !$0.isFileTransferRecord })
        let storage = try FileStorage(directory: f.root.appendingPathComponent("store").path)
        XCTAssertEqual(try Data(contentsOf: storage.receivedDirectory(clip.0).appendingPathComponent(incomingClip.name)), bytes)
    }
    func testLegacyAggregateSingleSlotAndOrdinaryQueueHasPriority() throws {
        let f = try Fixture(modern: false); defer { f.close() }
        XCTAssertNil(f.prepare(try f.source("active")))
        until("initial offer missing") { f.packets("file.offer").count == 1 }
        XCTAssertNil(try f.prepareClipboard())
        XCTAssertNil(f.prepare(try f.source("ordinary-priority")))
        until("both ordinary and clipboard should wait") { f.state.tasks.filter { $0.state == .queued }.count == 2 }
        let active = try XCTUnwrap(f.state.tasks.first { $0.state == .waitingAcceptance })
        f.engine.cancel(active.id, expectedAttempt: active.attemptId)
        until("ordinary queue did not continue") { f.packets("file.offer").count == 2 }
        XCTAssertEqual(f.packets("file.offer").last?["name"] as? String, "ordinary-priority.bin")
        XCTAssertEqual(f.state.tasks.first { $0.clipboardRecordId != nil }?.state, .queued)
        _ = try f.incoming()
        XCTAssertEqual(f.packets("file.error").last?["code"] as? String, "FILE_BUSY")
        let next = try XCTUnwrap(f.state.tasks.first { $0.state == .waitingAcceptance })
        f.engine.cancel(next.id, expectedAttempt: next.attemptId)
        until("clipboard queue never resumed") { f.packets("file.offer").count == 3 }
        XCTAssertNotNil(f.packets("file.offer").last?["clipboardRecordId"])
    }
    func testBoundedOrdinaryAdmissionAllowsFiftyIncludingActiveAndIncoming() throws {
        let f = try Fixture(); defer { f.close() }; let url = try f.source()
        _ = try f.incoming()
        for _ in 0..<49 { XCTAssertNil(f.prepare(url)) }
        until("six direction slots share fifty ordinary task admissions") { f.state.tasks.count == 50 && f.state.tasks.filter { $0.state == .queued }.count == 46 }
        XCTAssertFalse(f.state.canPrepareSend(peerID: "phone"))
        XCTAssertTrue(f.state.canPrepareSend(peerID: "phone", excludingTaskID: f.state.tasks[0].id), "retrying an admitted task must not reserve a second queue place")
        XCTAssertNotNil(f.prepare(url)); XCTAssertEqual(f.state.tasks.count, 50)
        let queued = try XCTUnwrap(f.state.tasks.first { $0.state == .queued })
        f.engine.cancel(queued.id, expectedAttempt: queued.attemptId)
        until("cancel did not release queued admission") { f.state.canPrepareSend(peerID: "phone") }
        XCTAssertNil(f.prepare(url))
    }
    func testOldAttemptCancelLateAckAndOneTimeoutDoNotAffectOtherTasks() throws {
        let f = try Fixture(); defer { f.close() }; let url = try f.source()
        for _ in 0..<4 { XCTAssertNil(f.prepare(url)) }
        until("initial three offers missing") { f.packets("file.offer").count == 3 }
        let tasks = f.state.tasks.filter { $0.state == .waitingAcceptance }
        let activeChannel = f.bind(tasks[0])
        f.message(["type": "file.accept", "taskId": tasks[1].id, "attemptId": tasks[1].attemptId])
        f.message(["type": "file.cancel", "taskId": tasks[0].id, "attemptId": UUID().uuidString.lowercased(), "reason": "user"])
        until("bound stream missing") { f.state.tasks.first { $0.id == tasks[0].id }?.state == .transferring }
        f.engine.tick(now: Date().addingTimeInterval(16))
        until("awaiting-data task did not time out") { f.state.tasks.first { $0.id == tasks[1].id }?.state == .failed && f.packets("file.offer").count == 4 }
        XCTAssertEqual(f.state.tasks.first { $0.id == tasks[0].id }?.state, .transferring)
        XCTAssertEqual(f.state.tasks.first { $0.id == tasks[2].id }?.state, .waitingAcceptance)
        // 超时任务的旧通道和ACK到达后，也不能清掉另一个任务的句柄。
        let oldChannel = UUID(); f.engine.dataClosed(oldChannel)
        f.engine.data(channel: oldChannel, message: ["type": "file.chunkAck", "taskId": tasks[1].id, "attemptId": tasks[1].attemptId, "offset": 7])
        f.engine.data(channel: activeChannel, message: ["type": "file.chunkAck", "taskId": tasks[0].id, "attemptId": tasks[0].attemptId, "offset": 7])
        until("unrelated active stream could no longer progress") { f.packets("file.end", channel: activeChannel).count == 1 }
    }
    func testDataClosedReleasesSlotForQueuedTaskWithoutRetryingInterruptedTask() throws {
        let f = try Fixture(); defer { f.close() }; let url = try f.source()
        for _ in 0..<4 { XCTAssertNil(f.prepare(url)) }
        until("initial three offers and queued fourth missing") { f.packets("file.offer").count == 3 && f.state.tasks.filter { $0.state == .queued }.count == 1 }
        let tasks = f.state.tasks.filter { $0.state == .waitingAcceptance }
        let queued = try XCTUnwrap(f.state.tasks.first { $0.state == .queued })
        let channels = tasks.map { f.bind($0) }
        until("three simultaneous streams missing") { f.state.tasks.filter { $0.state == .transferring }.count == 3 }
        f.engine.dataClosed(channels[0])
        until("data disconnect did not release its slot for queued fourth") {
            f.state.tasks.first { $0.id == tasks[0].id }?.state == .waitingConnection && f.packets("file.offer").count == 4
        }
        XCTAssertEqual(f.packets("file.offer").last?["taskId"] as? String, queued.id)
        XCTAssertEqual(f.packets("file.offer").filter { $0["taskId"] as? String == tasks[0].id }.count, 1, "failed stream must wait for reconnect or explicit retry")
        XCTAssertEqual(f.state.tasks.first { $0.id == tasks[0].id }?.attemptId, tasks[0].attemptId)
        XCTAssertEqual(f.state.tasks.filter { $0.state == .transferring }.count, 2)
        let fourth = try XCTUnwrap(f.state.tasks.first { $0.id == queued.id })
        _ = f.bind(fourth)
        until("replacement stream did not bind") { f.state.tasks.filter { $0.state == .transferring }.count == 3 }
        f.engine.data(channel: channels[1], message: ["type": "file.chunkAck", "taskId": tasks[1].id, "attemptId": tasks[1].attemptId, "offset": 7])
        until("unrelated stream lost its handle") { f.packets("file.end", channel: channels[1]).count == 1 }
    }
    func testDisconnectKeepsEveryOutgoingTaskAndReconnectRespectsLimits() throws {
        let f = try Fixture(); defer { f.close() }; let url = try f.source()
        for _ in 0..<5 { XCTAssertNil(f.prepare(url)) }
        until("initial offers missing") { f.packets("file.offer").count == 3 }
        f.engine.controlClosed(f.control)
        until("all pending tasks must persist offline") { f.state.tasks.filter { $0.state == .waitingConnection }.count == 5 }
        f.hello(channel: UUID())
        until("reconnect must start only three") { f.packets("file.offer").count == 6 && f.state.tasks.filter { $0.state == .queued }.count == 2 }
    }
    func testOrdinarySendCanPrepareWhileClipboardStreamIsActive() throws {
        for modern in [true, false] {
            let f = try Fixture(modern: modern); defer { f.close() }
            XCTAssertNil(try f.prepareClipboard())
            until("clipboard offer missing") { f.packets("file.offer").count == 1 }
            let clipboard = try XCTUnwrap(f.state.tasks.first)
            _ = f.bind(clipboard)
            until("clipboard stream missing") { f.state.tasks.first?.state == .transferring }
            XCTAssertTrue(f.state.canPrepareSend(peerID: "phone"))
            XCTAssertNil(f.prepare(try f.source("manual-while-clipboard")))
            until("ordinary send was refused by clipboard stream") { f.state.tasks.count == 2 }
            if modern { until("independent ordinary lane did not start") { f.packets("file.offer").count == 2 } }
            else { XCTAssertEqual(f.state.tasks.first { $0.clipboardRecordId == nil }?.state, .queued) }
        }
    }
    func testOneIncomingHashFailureLeavesOtherStreamAndReceiptIntact() throws {
        let f = try Fixture(); defer { f.close() }
        _ = try f.incoming(); _ = try f.incoming()
        let tasks = f.state.tasks; let channels = tasks.map { f.bind($0) }
        until("both incoming streams missing") { f.state.tasks.filter { $0.state == .transferring }.count == 2 }
        for i in 0..<2 {
            let bytes = Data((i == 0 ? "corrupt!" : "incoming").utf8)
            f.engine.data(channel: channels[i], message: ["type": "file.chunk", "taskId": tasks[i].id, "attemptId": tasks[i].attemptId, "offset": 0, "data": bytes.base64EncodedString()])
            until("chunk ACK missing") { f.packets("file.chunkAck", channel: channels[i]).count == 1 }
            f.engine.data(channel: channels[i], message: ["type": "file.end", "taskId": tasks[i].id, "attemptId": tasks[i].attemptId])
        }
        until("hash failure or successful neighbor receipt missing") {
            f.state.tasks.first { $0.id == tasks[0].id }?.state == .failed && f.state.tasks.first { $0.id == tasks[1].id }?.state == .completed
        }
        XCTAssertEqual(f.packets("file.complete", channel: channels[1]).first?["sha256"] as? String, tasks[1].sha256)
        XCTAssertTrue(f.packets("file.complete", channel: channels[0]).isEmpty)
    }
    func testBusySchedulesBoundedAttemptScopedRetriesAndExhaustionIsVisible() throws {
        let f = try Fixture(busyRetryDelays: [0.015, 0.015, 0.015, 0.015, 0.015]); defer { f.close() }
        XCTAssertNil(f.prepare(try f.source()))
        until("initial offer missing") { f.packets("file.offer").count == 1 }
        let id = try XCTUnwrap(f.state.tasks.first?.id)
        var attempts = Set<String>()
        for count in 1...6 {
            until("BUSY retry did not create a fresh attempt") { f.packets("file.offer").count == count }
            let task = try XCTUnwrap(f.state.tasks.first { $0.id == id }); attempts.insert(task.attemptId)
            f.message(["type": "file.error", "taskId": id, "attemptId": task.attemptId, "code": "FILE_BUSY"])
        }
        until("retry exhaustion must be explicit") { f.state.tasks.first?.state == .failed }
        XCTAssertEqual(attempts.count, 6)
        XCTAssertTrue(f.state.tasks.first?.error?.contains("自动重试已停止") == true)
        Thread.sleep(forTimeInterval: 0.06)
        XCTAssertEqual(f.packets("file.offer").count, 6)
    }
    func testCancelledBusyTimerCannotRestartTask() throws {
        let f = try Fixture(busyRetryDelays: [0.04]); defer { f.close() }
        XCTAssertNil(f.prepare(try f.source()))
        until("initial offer missing") { f.packets("file.offer").count == 1 }
        let task = try XCTUnwrap(f.state.tasks.first)
        f.message(["type": "file.error", "taskId": task.id, "attemptId": task.attemptId, "code": "FILE_BUSY"])
        f.engine.cancel(task.id, expectedAttempt: task.attemptId)
        until("queued BUSY task did not cancel") { f.state.tasks.first?.state == .cancelled }
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(f.packets("file.offer").count, 1)
    }
    func testQueuedTasksSurviveEngineRestartWithoutBecomingAdditionalActiveSlots() throws {
        let f = try Fixture(connected: false); defer { f.close() }
        let url = try f.source(); for _ in 0..<4 { XCTAssertNil(f.prepare(url)) }
        XCTAssertEqual(f.state.tasks.filter { $0.state == .waitingConnection }.count, 4)
        var config = ServerConfiguration(); config.fileStoreDirectory = f.root.appendingPathComponent("store").path
        let lock = NSLock(); var restored = FileTransferSnapshot()
        let engine = try FileTransferEngine(configuration: config, send: { _, _, _ in }, close: { _ in }, resume: { _ in }, changed: { value in lock.lock(); restored = value; lock.unlock() })
        engine.control(peer: "phone", channel: UUID(), message: ["type": "file.hello", "protocol": "xq-file/1", "maxConcurrentFiles": 3, "maxConcurrentClipboard": 1], completion: {})
        until("persistent tasks not restored into bounded scheduler") { lock.lock(); defer { lock.unlock() }; return restored.tasks.filter { $0.state == .waitingAcceptance }.count == 3 && restored.tasks.filter { $0.state == .queued }.count == 1 }
    }
}
