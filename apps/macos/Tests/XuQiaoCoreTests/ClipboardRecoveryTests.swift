import XCTest
import AppKit
@testable import XuQiaoCore

final class ClipboardRecoveryTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xq-capture-test-" + UUID().uuidString)
        let queue = DispatchQueue(label: "xq.recovery.test")
        let io = DispatchQueue(label: "xq.recovery.test.io")
        let boardName = "com.chenguangyao.xuqiao.test.recovery." + UUID().uuidString
        var running = true
        var reads = 0
        var engine: FileTransferEngine!
        var adapter: PlatformClipboard!
        var core: ClipboardCoordinator!
        init(peerIDs: [String] = ["phone"]) throws {
            var config = ServerConfiguration()
            config.fileStoreDirectory = root.path
            config.keychainSuffix = "capture-test-" + UUID().uuidString
            config.clipboardPasteboard = boardName
            adapter = PlatformClipboard(name: boardName, sessionState: { [weak self] in
                guard let self else { return false }; self.reads += 1; return self.running
            })
            engine = try FileTransferEngine(configuration: config, send: { _,_,_ in }, close: { _ in }, resume: { _ in }, changed: { _ in })
            let peers = peerIDs.map { StoredPeer(id: $0, name: "test", clipboardTrustGeneration: "g", tokenHash: "unused", paused: false, lastSeen: Date()) }
            core = try ClipboardCoordinator(configuration: config, store: SecureStore(suffix: config.keychainSuffix), queue: queue, localID: "mac", localName: "test", engine: engine, peers: peers, send: { _,_ in }, changed: {}, captureQueue: io, platformClipboard: adapter)
            queue.sync {
                for peer in peers {
                    let channel = UUID()
                    core.authenticated(peer: peer.id, channel: channel)
                    core.control(peer: peer.id, channel: channel, message: ["type": "clip.hello", "protocol": "xq-clipboard/2", "maxTextBytes": 16384,
                        "acceptRecords": true, "receiverEpoch": String(repeating: "a", count: 32), "acceptedKinds": ["text"], "syncEnabled": true, "enabledKinds": ["text"]])
                }
            }
        }
        func rows() -> [ClipboardRecord] { queue.sync { core.matchingRows(source: "", kind: "", query: "") } }
        func manual(_ text: String, context: String? = nil) { queue.sync { core.manualToAll(text: text, expectedContext: context ?? core.context) } }
        func blockIO() -> DispatchSemaphore {
            let hold = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
            io.async { entered.signal(); _ = hold.wait(timeout: .now() + 8) }
            _ = entered.wait(timeout: .now() + 1)
            return hold
        }
        func close() {
            queue.sync { core.stop() }
            io.sync {}; queue.sync {}
            core = nil; adapter = nil; engine = nil
            try? FileManager.default.removeItem(at: root)
        }
    }
    @discardableResult private func until(_ message: String, seconds: TimeInterval = 4, _ check: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if check() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail(message); return false
    }
    private func ready(_ f: Fixture) {
        until("runtime failed to become active") { f.queue.sync { f.core.views(["phone"]).first?.effectiveReceive == true } }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    private func write(_ f: Fixture, _ text: String) {
        let p = NSPasteboard(name: .init(f.boardName)); p.clearContents(); XCTAssertTrue(p.setString(text, forType: .string))
    }
    func testExplicitSameTextCreatesNewRecords() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        f.manual("same"); until("first manual not saved") { f.rows().count == 1 }
        let first = f.rows().first!.content.recordId
        f.manual("same"); until("second manual was incorrectly deduplicated") { f.rows().count == 2 }
        XCTAssertNotEqual(first, f.rows().first!.content.recordId)
    }
    func testAutomaticSameTextStillReusesAdjacentRecord() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        write(f, "same-auto"); until("automatic copy not captured") { f.rows().count == 1 }
        let id = f.rows().first!.content.recordId
        write(f, "same-auto")
        until("automatic adjacent reuse missing") { f.queue.sync { f.core.notice == "已复用上一条相同记录" } }
        XCTAssertEqual(f.rows().count, 1); XCTAssertEqual(f.rows().first!.content.recordId, id)
    }
    func testBusyCaptureKeepsLatestAutomaticCopy() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        let hold = f.blockIO(); defer { hold.signal() }
        f.manual("blocking")
        write(f, "copy-b"); RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        write(f, "copy-c"); RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hold.signal()
        until("latest busy copy lost") { f.rows().contains { $0.content.text == "copy-c" } }
        XCTAssertFalse(f.rows().contains { $0.content.text == "copy-b" })
    }
    func testBusyCaptureKeepsManualAheadOfAutomatic() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        let hold = f.blockIO(); defer { hold.signal() }
        f.manual("blocking"); f.manual("manual-next")
        write(f, "automatic-next"); RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hold.signal()
        until("manual or latest automatic pending capture lost") { f.rows().count == 3 }
        XCTAssertEqual(f.rows().reversed().compactMap { $0.content.text }, ["blocking", "manual-next", "automatic-next"])
    }
    func testLaterManualDiscardsOlderPendingAutomaticCopy() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        let hold = f.blockIO(); defer { hold.signal() }
        f.manual("blocking")
        write(f, "older-auto"); RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        f.manual("newer-manual"); hold.signal()
        until("newer manual lost") { f.rows().contains { $0.content.text == "newer-manual" } }
        f.io.sync {}; f.queue.sync {}
        XCTAssertFalse(f.rows().contains { $0.content.text == "older-auto" })
        XCTAssertEqual(f.rows().first?.content.text, "newer-manual")
    }
    func testSinglePeerManualRetainsOtherPeersPendingAutomaticCopy() throws {
        let f = try Fixture(peerIDs: ["phone", "other"]); defer { f.close() }; ready(f)
        let hold = f.blockIO(); defer { hold.signal() }
        f.manual("blocking"); write(f, "auto-for-other")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        f.queue.sync { f.core.manual(peer: "phone", text: "manual-for-phone") }
        hold.signal(); until("other peer lost pending automatic copy") { f.rows().count == 3 }
        let rows = f.rows()
        let grants = try f.queue.sync { try ClipboardRecordStore(root: FileStorage(directory: f.root.path).root).grants() }
        let autoID = rows.first { $0.content.text == "auto-for-other" }!.content.recordId
        let manualID = rows.first { $0.content.text == "manual-for-phone" }!.content.recordId
        XCTAssertEqual(grants.filter { $0.recordId == autoID }.map(\.peerId), ["other"])
        XCTAssertEqual(grants.filter { $0.recordId == manualID }.map(\.peerId), ["phone"])
    }
    func testSettingsRotationDiscardsOldQueuedIntents() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        let hold = f.blockIO(); defer { hold.signal() }
        f.manual("cancelled-a"); f.manual("cancelled-b")
        f.queue.sync { XCTAssertNil(f.core.savePreferences(f.core.preferences, expectedContext: f.core.context)) }
        hold.signal(); f.io.sync {}; f.queue.sync {}
        XCTAssertEqual(f.rows().count, 0)
        f.manual("after-settings"); until("source did not recover") { f.rows().count == 1 }
        XCTAssertEqual(f.rows().first?.content.text, "after-settings")
    }
    func testStaleManualContextHasFailureFeedback() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        f.manual("must-not-send", context: "old-context")
        XCTAssertEqual(f.rows().count, 0)
        XCTAssertTrue(f.queue.sync { f.core.notice?.contains("本次未发送") == true })
    }
    func testForegroundEventRecoversTemporaryRuntimeFalse() throws {
        let f = try Fixture(); defer { f.close() }; f.running = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.3)); f.running = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        ready(f); f.manual("after-foreground"); until("foreground refresh did not recover source") { f.rows().count == 1 }
    }
    func testInactiveManualRequestsOneRuntimeRefresh() throws {
        let f = try Fixture(); defer { f.close() }; f.running = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        f.running = true; f.manual("not-accepted")
        XCTAssertTrue(f.queue.sync { f.core.notice?.contains("本次未发送") == true })
        ready(f); f.manual("accepted-after-recovery"); until("manual refresh did not recover") { f.rows().count == 1 }
        let reads = f.reads; RunLoop.current.run(until: Date().addingTimeInterval(0.6)); XCTAssertEqual(f.reads, reads)
    }
    func testDelayedRuntimeCheckRecoversWithoutAnotherEvent() throws {
        let f = try Fixture(); defer { f.close() }; f.running = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.1)); f.running = true
        ready(f)
        let reads = f.reads; RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(f.reads, reads)
    }
    func testPermitRotationDuringManualBoardReadHasFeedback() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        write(f, "not-accepted-after-rotation")
        f.queue.sync {
            f.core.manualToAll(text: nil, expectedContext: f.core.context)
            XCTAssertNil(f.core.savePreferences(f.core.preferences, expectedContext: f.core.context))
        }
        until("revoked manual read silently discarded") { f.queue.sync { f.core.notice?.contains("本次未发送") == true } }
        XCTAssertEqual(f.rows().count, 0)
    }
    func testPauseCancelsLateRecoveryRecheck() throws {
        let f = try Fixture(); defer { f.close() }; f.running = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        f.running = true
        // 仅测试进程内的NSWorkspace通知，不向DistributedNotificationCenter广播锁屏。
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        XCTAssertFalse(f.queue.sync { f.core.views(["phone"]).first!.effectiveReceive })
    }
    func testPauseClearsQueuedCaptureAndNewResumeCaptureSurvives() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        let hold = f.blockIO(); defer { hold.signal() }
        f.manual("cancelled-a"); f.manual("cancelled-b")
        f.running = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        f.running = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        ready(f); f.manual("new-after-resume")
        hold.signal()
        until("new capture blocked by cancelled IO") { f.rows().count == 1 }
        XCTAssertEqual(f.rows().first?.content.text, "new-after-resume")
    }
}
