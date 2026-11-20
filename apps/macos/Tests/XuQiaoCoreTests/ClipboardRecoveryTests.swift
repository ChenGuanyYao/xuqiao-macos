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
        var channels: [String: UUID] = [:]
        var packets: [(UUID, [String: Any])] = []
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
            core = try ClipboardCoordinator(configuration: config, store: SecureStore(suffix: config.keychainSuffix), queue: queue, localID: "mac", localName: "test", engine: engine, peers: peers, send: { [weak self] channel, packet in self?.packets.append((channel, packet)) }, changed: {}, captureQueue: io, platformClipboard: adapter)
            queue.sync {
                for peer in peers {
                    let channel = UUID()
                    channels[peer.id] = channel
                    core.authenticated(peer: peer.id, channel: channel)
                    core.control(peer: peer.id, channel: channel, message: ["type": "clip.hello", "protocol": "xq-clipboard/2", "maxTextBytes": 16384,
                        "acceptRecords": true, "receiverEpoch": String(repeating: "a", count: 32), "acceptedKinds": ["text"], "syncEnabled": true, "enabledKinds": ["text"]])
                }
            }
        }
        func rows() -> [ClipboardRecord] { queue.sync { core.matchingRows(source: "", kind: "", query: "") } }
        func manual(_ text: String, context: String? = nil) { queue.sync { core.manualToAll(text: text, expectedContext: context ?? core.context) } }
        func reconnect(_ peer: String = "phone") {
            queue.sync {
                core.disconnected(channels[peer]!); let channel = UUID(); channels[peer] = channel
                core.authenticated(peer: peer, channel: channel)
                core.control(peer: peer, channel: channel, message: ["type": "clip.hello", "protocol": "xq-clipboard/2", "maxTextBytes": 16384,
                    "acceptRecords": true, "receiverEpoch": String(repeating: "a", count: 32), "acceptedKinds": ["text"], "syncEnabled": true, "enabledKinds": ["text"]])
            }
        }
        func acknowledge(_ peer: String = "phone", applyError: Bool = false) {
            queue.sync {
                guard let channel = channels[peer], let packet = packets.last(where: { $0.0 == channel && $0.1["type"] as? String == "clip.record" })?.1 else { XCTFail("No outgoing record"); return }
                var ack = packet; ack["type"] = "clip.recordAck"; ack["status"] = "stored"
                if applyError { ack["applyError"] = "CLIP_IO" }
                core.control(peer: peer, channel: channel, message: ack)
            }
        }
        func reconnectBeforeHello(_ peer: String = "phone") {
            queue.sync {
                core.disconnected(channels[peer]!); let channel = UUID(); channels[peer] = channel
                core.authenticated(peer: peer, channel: channel)
            }
        }
        func finishHello(_ peer: String = "phone", accept: Bool = true) {
            queue.sync {
                core.control(peer: peer, channel: channels[peer]!, message: ["type": "clip.hello", "protocol": "xq-clipboard/2", "maxTextBytes": 16384,
                    "acceptRecords": accept, "receiverEpoch": accept ? String(repeating: "a", count: 32) : "", "acceptedKinds": accept ? ["text"] : [], "syncEnabled": true, "enabledKinds": ["text"]])
            }
        }
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
    func testLegacyDeliveryMigrationPreservesAckAndTreatsUnknownAttemptConservatively() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xq-delivery-migration-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = try FileStorage(directory: root.path).root
        var legacy: ClipboardRecordStore? = try ClipboardRecordStore(root: canonical)
        try legacy!.saveGrant(ClipboardGrant(recordId: "old", peerId: "phone", trustGeneration: "g"))
        try legacy!.run("UPDATE clipboard_deliveries SET announcedVersion=0")
        try legacy!.exec("ALTER TABLE clipboard_deliveries DROP COLUMN attempted"); legacy = nil
        let migrated = try ClipboardRecordStore(root: canonical)
        XCTAssertEqual(try migrated.grants(recordID: "old").first?.announcedVersion, 0)
        XCTAssertEqual(try migrated.grants(recordID: "old", attemptedOnly: true).count, 1)
        try migrated.saveGrant(ClipboardGrant(recordId: "new", peerId: "phone", trustGeneration: "g"))
        XCTAssertEqual(try migrated.grants(recordID: "new", attemptedOnly: true).count, 0)
    }
    func testAutomaticSameTextStillReusesAdjacentRecord() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        write(f, "same-auto"); until("automatic copy not captured") { f.rows().count == 1 }; f.acknowledge()
        let id = f.rows().first!.content.recordId
        let revision = f.queue.sync { f.core.noticeRevision }
        write(f, "same-auto")
        until("automatic adjacent reuse missing") { f.queue.sync { f.core.noticeRevision >= revision + 2 && f.core.notice != "正在准备剪贴板记录…" } }
        XCTAssertEqual(f.rows().count, 1); XCTAssertEqual(f.rows().first!.content.recordId, id)
    }
    func testFirstAutomaticCopyAfterReconnectIsFreshThenAdjacentReuseReturns() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        write(f, "same-after-reconnect"); until("first record missing") { f.rows().count == 1 }; f.acknowledge()
        let original = f.rows().first!.content.recordId
        f.reconnect(); write(f, "same-after-reconnect")
        until("first post-reconnect copy reused old record") { f.rows().count == 2 }
        XCTAssertNotEqual(original, f.rows().first!.content.recordId); f.acknowledge()
        let revision = f.queue.sync { f.core.noticeRevision }
        write(f, "same-after-reconnect")
        until("following adjacent copy not processed") { f.queue.sync { f.core.noticeRevision >= revision + 2 } }
        XCTAssertEqual(f.rows().count, 2)
    }
    func testFreshCopyDuringHandshakeStaysLiveWhenHelloWinsSnapshotRace() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        write(f, "old-before-handshake"); until("old copy missing") { f.rows().count == 1 }; f.acknowledge()
        f.reconnectBeforeHello(); let hold = f.blockIO(); defer { hold.signal() }
        write(f, "new-different-during-handshake")
        until("new capture not started") { f.queue.sync { f.core.notice == "正在准备剪贴板记录…" } }
        f.finishHello(); hold.signal(); until("new copy missing") { f.rows().count == 2 }
        let row = f.rows().first!
        XCTAssertEqual(row.content.text, "new-different-during-handshake")
        XCTAssertEqual(f.queue.sync { f.packets.last { $0.1["recordId"] as? String == row.content.recordId }?.1["deliveryMode"] as? String }, "live")
    }
    func testUnacknowledgedAttemptedCopyCreatesNewIntentAndIsSentAfterPendingAck() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        write(f, "pending-same"); until("first copy missing") { f.rows().count == 1 }
        let first = f.rows().first!.content.recordId
        write(f, "pending-same"); until("new explicit intent missing") { f.rows().count == 2 }
        let latest = f.rows().first!.content.recordId; XCTAssertNotEqual(first, latest)
        f.acknowledge() // 只确认旧在途项；随后必须实际发送新意图。
        XCTAssertEqual(f.queue.sync { f.packets.last { $0.1["type"] as? String == "clip.record" }?.1["recordId"] as? String }, latest)
        f.acknowledge(); XCTAssertEqual(f.queue.sync { f.core.notice }, "已同步到 1 台设备")
    }
    func testSameUnstartedQueuedCopyReusesRecordWithoutClaimingDelivery() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        f.manual("blocking-inflight"); until("blocking copy missing") { f.rows().count == 1 }
        write(f, "queued-same"); until("queued copy missing") { f.rows().count == 2 }
        let queued = f.rows().first!.content.recordId
        let revision = f.queue.sync { f.core.noticeRevision }; write(f, "queued-same")
        until("repeat queued copy missing") { f.queue.sync { f.core.noticeRevision >= revision + 2 } }
        XCTAssertEqual(f.rows().count, 2); XCTAssertEqual(f.rows().first!.content.recordId, queued)
        XCTAssertFalse(f.queue.sync { f.core.notice?.contains("已同步到") == true })
        f.acknowledge()
        XCTAssertEqual(f.queue.sync { f.packets.last { $0.1["type"] as? String == "clip.record" }?.1["recordId"] as? String }, queued)
    }
    func testPreHelloCopyCannotBePromotedAcrossLaterReceiverPolicyEpoch() throws {
        try assertPreHelloCopyCannotCrossPolicy(firstAccepts: true)
    }
    func testInitiallyRejectedHelloCannotPromoteOldCaptureAfterPolicyEnablesReceive() throws {
        try assertPreHelloCopyCannotCrossPolicy(firstAccepts: false)
    }
    private func assertPreHelloCopyCannotCrossPolicy(firstAccepts: Bool) throws {
        let f = try Fixture(); defer { f.close() }; ready(f); f.reconnectBeforeHello()
        let hold = f.blockIO(); defer { hold.signal() }
        write(f, "copy-before-permission-change")
        until("capture not started") { f.queue.sync { f.core.notice == "正在准备剪贴板记录…" } }
        f.finishHello(accept: firstAccepts)
        f.queue.sync {
            f.core.control(peer: "phone", channel: f.channels["phone"]!, message: ["type": "clip.policy", "acceptRecords": true,
                "receiverEpoch": String(repeating: "b", count: 32), "acceptedKinds": ["text"], "syncEnabled": true, "enabledKinds": ["text"]])
        }
        hold.signal(); until("record missing") { f.rows().count == 1 }
        let id = f.rows().first!.content.recordId
        XCTAssertEqual(f.queue.sync { f.packets.last { $0.1["recordId"] as? String == id }?.1["deliveryMode"] as? String }, "history")
    }
    func testUnacknowledgedAttemptedCopyAfterReconnectUsesNewRecordID() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        write(f, "pending-across-reconnect"); until("first copy missing") { f.rows().count == 1 }
        let id = f.rows().first!.content.recordId
        f.reconnect(); let revision = f.queue.sync { f.core.noticeRevision }; write(f, "pending-across-reconnect")
        until("repeat capture missing") { f.queue.sync { f.core.noticeRevision >= revision + 2 } }
        XCTAssertEqual(f.rows().count, 2); XCTAssertNotEqual(f.rows().first!.content.recordId, id)
        f.acknowledge() // 先完成重连时已在途的旧记录，再核对新意图。
        XCTAssertEqual(f.queue.sync { f.packets.last { $0.1["type"] as? String == "clip.record" }?.1["deliveryMode"] as? String }, "live")
    }
    func testStoredAckReplacesWaitingNotice() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        f.manual("notice-ack"); until("record not prepared") { f.rows().count == 1 }; f.acknowledge()
        XCTAssertEqual(f.queue.sync { f.core.notice }, "已同步到 1 台设备")
        XCTAssertTrue(f.queue.sync { f.core.noticeIsReceipt })
    }
    func testOneOfflinePeerDoesNotHideConfirmedOnlineDelivery() throws {
        let f = try Fixture(peerIDs: ["phone", "other"]); defer { f.close() }; ready(f)
        f.queue.sync { f.core.disconnected(f.channels["other"]!) }
        f.manual("online-and-offline"); until("record not prepared") { f.rows().count == 1 }; f.acknowledge()
        XCTAssertEqual(f.queue.sync { f.core.notice }, "已同步到 1 台设备；另 1 台设备连接后自动同步")
    }
    func testOldAckCannotOverwriteNewPreparation() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        f.manual("first"); until("first record missing") { f.rows().count == 1 }
        let hold = f.blockIO(); defer { hold.signal() }
        f.manual("second"); f.acknowledge()
        XCTAssertEqual(f.queue.sync { f.core.notice }, "正在准备剪贴板记录…")
        hold.signal(); until("second record missing") { f.rows().count == 2 }; f.acknowledge()
        XCTAssertEqual(f.queue.sync { f.core.notice }, "已同步到 1 台设备")
    }
    func testOnlinePeersWithDifferentReceivePoliciesHaveSeparateCounts() throws {
        let f = try Fixture(peerIDs: ["phone", "other"]); defer { f.close() }; ready(f)
        f.queue.sync {
            f.core.control(peer: "other", channel: f.channels["other"]!, message: ["type": "clip.policy", "acceptRecords": false,
                "receiverEpoch": "", "acceptedKinds": [], "syncEnabled": true, "enabledKinds": ["text"]])
        }
        f.manual("mixed-online-policies"); until("record not prepared") { f.rows().count == 1 }
        XCTAssertEqual(f.queue.sync { f.core.notice }, "正在同步到 1 台设备；等待 1 台设备开启剪贴板同步")
        f.acknowledge()
        XCTAssertEqual(f.queue.sync { f.core.notice }, "已同步到 1 台设备；等待 1 台设备开启剪贴板同步")
    }
    func testConnectedPeerBeforeClipboardHandshakeIsNotReportedAsDisabled() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        f.queue.sync {
            f.core.disconnected(f.channels["phone"]!); let channel = UUID(); f.channels["phone"] = channel
            f.core.authenticated(peer: "phone", channel: channel)
        }
        f.manual("before-clipboard-handshake"); until("record not prepared") { f.rows().count == 1 }
        XCTAssertEqual(f.queue.sync { f.core.notice }, "1 台设备剪贴板尚未就绪")
    }
    func testOldAckCannotOverwriteNewOperationError() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        f.manual("first"); until("first record missing") { f.rows().count == 1 }
        f.manual("rejected", context: "stale-context"); let error = f.queue.sync { f.core.notice }
        f.acknowledge(); XCTAssertEqual(f.queue.sync { f.core.notice }, error)
        XCTAssertFalse(f.queue.sync { f.core.noticeIsReceipt })
    }
    func testRemovingOfflineTargetRefreshesPendingNoticeWithoutAnotherEvent() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        f.queue.sync { f.core.disconnected(f.channels["phone"]!) }
        f.manual("removed-offline-target"); until("record missing") { f.rows().count == 1 }
        XCTAssertEqual(f.queue.sync { f.core.notice }, "1 台设备连接后自动同步")
        f.queue.sync { f.core.updatePeers([]) }
        XCTAssertEqual(f.queue.sync { f.core.notice }, "已保存到本机，原设备授权已变化")
        XCTAssertEqual(f.rows().count, 1)
    }
    func testRemovingOfflineTargetDoesNotClaimAllOriginalTargetsReceived() throws {
        let f = try Fixture(peerIDs: ["phone", "other"]); defer { f.close() }; ready(f)
        f.queue.sync { f.core.disconnected(f.channels["other"]!) }
        f.manual("partial-with-revoked-target"); until("record missing") { f.rows().count == 1 }; f.acknowledge()
        f.queue.sync { f.core.updatePeers([StoredPeer(id: "phone", name: "test", clipboardTrustGeneration: "g", tokenHash: "unused", paused: false, lastSeen: Date())]) }
        XCTAssertEqual(f.queue.sync { f.core.notice }, "已同步到 1 台设备；1 台设备授权已变化")
    }
    func testStoredRecordWithApplyErrorDoesNotClaimSystemClipboardSuccess() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        f.manual("apply-error"); until("record missing") { f.rows().count == 1 }; f.acknowledge(applyError: true)
        XCTAssertTrue(f.queue.sync { f.core.notice?.contains("系统剪贴板写入未完成") == true })
    }
    func testLateOldConnectionCaptureCannotConsumeFreshCopyOnNewConnection() throws {
        let f = try Fixture(); defer { f.close() }; ready(f)
        write(f, "same-late"); until("first copy missing") { f.rows().count == 1 }; f.acknowledge()
        let hold = f.blockIO(); defer { hold.signal() }
        write(f, "same-late"); until("old capture not started") { f.queue.sync { f.core.notice == "正在准备剪贴板记录…" } }
        f.reconnect(); hold.signal(); f.io.sync {}; f.queue.sync {}
        write(f, "same-late"); until("old capture consumed fresh-copy marker") { f.rows().count == 2 }
    }
    func testReconnectingOnePeerCreatesOnlyOneFreshSharedRecord() throws {
        let f = try Fixture(peerIDs: ["phone", "other"]); defer { f.close() }; ready(f)
        write(f, "same-multi"); until("first copy missing") { f.rows().count == 1 }; f.acknowledge(); f.acknowledge("other")
        f.reconnect(); write(f, "same-multi"); until("fresh shared record missing") { f.rows().count == 2 }
        f.acknowledge(); f.acknowledge("other")
        let revision = f.queue.sync { f.core.noticeRevision }; write(f, "same-multi")
        until("later copy not processed") { f.queue.sync { f.core.noticeRevision >= revision + 2 } }
        XCTAssertEqual(f.rows().count, 2)
    }
    func testOfflineUnacknowledgedPeerCannotHideFreshCopyFromReconnectedAcknowledgedPeer() throws {
        let f = try Fixture(peerIDs: ["phone", "other"]); defer { f.close() }; ready(f)
        write(f, "mixed-ack-across-reconnect"); until("first copy missing") { f.rows().count == 1 }; f.acknowledge()
        let original = f.rows().first!.content.recordId
        f.queue.sync { f.core.disconnected(f.channels["other"]!) }; f.reconnect()
        write(f, "mixed-ack-across-reconnect"); until("reconnected confirmed peer lost its fresh copy") { f.rows().count == 2 }
        let latest = f.rows().first!.content.recordId; XCTAssertNotEqual(original, latest)
        XCTAssertEqual(f.queue.sync { f.packets.last { $0.0 == f.channels["phone"] && $0.1["recordId"] as? String == latest }?.1["deliveryMode"] as? String }, "live")
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
