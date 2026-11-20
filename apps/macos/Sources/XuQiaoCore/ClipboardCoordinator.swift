import Foundation
import Darwin

private final class RecordSession {
    let channel: UUID
    var capable = false
    var localEpoch = ""
    var remoteEpoch = ""
    var initialRemoteEpoch: String?
    var remoteAccept = false
    var remoteKinds = Set<String>()
    var previewCapable = false
    var resumeTextCapable = false
    var resumePrepared = false
    var resumePreparing = false
    var resumeRecord: ClipboardRecord?
    var resumeReceived = false
    var resumeGuard: ClipboardResumeGuard?
    var needsFreshCapture = true
    var incoming = ClipboardPermit()
    var receiving = 0
    var preparingDownloads = 0
    var retryAt: Date?
    var historyBoundary: Int64?
    var historyRecordIDs = Set<String>()
    var historyGeneration = ""
    func resetHistoryWindow() { historyBoundary = nil; historyRecordIDs.removeAll(); historyGeneration = "" }
    var inflight: (delivery: String, record: String, hash: String, version: Int64, date: Date, manual: Bool)?
    init(_ channel: UUID) { self.channel = channel }
    func close() { incoming.cancel(); inflight = nil; retryAt = nil; resetHistoryWindow() }
}
private struct RecordPeerMemory {
    var sent = 0, received = 0, duplicates = 0
    var send = "尚未发布", receive = "尚未接收"
}
private struct CaptureTarget {
    var peer: String
    var generation: String
    var manual: Bool
    var epoch: String
    var autoVersion = ""
    var connection: UUID? = nil
    var awaitingHello = false
}
private struct CaptureNotice {
    let recordID: String
    let targets: [CaptureTarget]
    var revision: UInt64
    var applyErrors = Set<String>()
}
private struct CaptureCandidate {
    let row: ClipboardRecord
    let snapshot: ClipboardSnapshotIndex?
    let identity: stat?
}
private struct PendingCapture {
    let input: ClipboardCapture
    let targets: [CaptureTarget]
    let automatic: Bool
    let capturedAt: Int64
}

/// 唯一剪贴板编排器：记录先可靠落库，投递授权与文件任务分别持久，不借旧text通道旁路。
final class ClipboardCoordinator {
    private let queue: DispatchQueue
    private let io: DispatchQueue
    private let adapter: PlatformClipboard
    private let database: ClipboardRecordStore
    private let snapshots: ClipboardSnapshotStore
    private let engine: FileTransferEngine
    private let localID: String
    private let localName: String
    private let preferencesStore: ClipboardPreferenceStore
    private var previews: ClipboardPreviewCoordinator!
    var preferences: ClipboardPreferences { preferencesStore.preferences }
    var preferencesError: String? { preferencesStore.error }
    var context: String { uiEpoch }
    private let send: (UUID, [String: Any]) -> Void
    private let changed: () -> Void
    private let newLocalContent: ([String]) -> Void
    private var peers: [StoredPeer]
    private var sessions: [String: RecordSession] = [:]
    private var disconnectGuards: [String: ClipboardResumeGuard] = [:]
    private var fileCapabilities: [String: (Bool,Bool)] = [:]
    private var memory: [String: RecordPeerMemory] = [:]
    private var active = false
    private var stopped = false
    private var observerEpoch = UUID()
    private var observing = false
    private var uiEpoch = UUID().uuidString
    private var baseline: [String: Int] = [:]
    private var autoVersions: [String: String] = [:]
    private var baselinePending = Set<String>()
    private var sourcePermit = ClipboardPermit()
    private var copyPermits: [String: ClipboardPermit] = [:]
    private var copySource: String?
    private var captureToken: WorkCancellation?
    private var pendingAutomaticCapture: PendingCapture?
    private var pendingManualCapture: PendingCapture?
    private var captureNotice: CaptureNotice?
    private var suppressed: [String: Date] = [:]
    private var tasks: [FileTaskView] = []
    private var pendingRequests: [String: (ClipboardBinding, UUID, Date)] = [:]
    private var selfRequests: [String: (ClipboardBinding,ClipboardPermit)] = [:]
    private var copyAfter = Set<String>()
    private var copying = false
    private var originalQueue: [String] = []
    private var automaticRequest: String?
    private var automaticSource: String?
    private var exportAfter = Set<String>()
    private var imageExporting = false
    private var imageExportCancellation = WorkCancellation()
    private var imageExportSource: String?
    #if DEBUG
    private(set) var deliveryScanCount = 0
    #endif
    private var lastSweep = Date.distantPast
    private var querySource = "", queryKind = "", querySearch = "", queryPage = 0
    private var batchQueue: [(String,String)] = []
    private var batchActive: (String,String)?
    private var batchTotal = 0, batchCompleted = 0, batchFailed = 0
    private var clearingPrivateImages = false
    private var privateImageCleanupCancellation = WorkCancellation()
    var queryID: String { [querySource,queryKind,String(queryPage),querySearch].joined(separator: "|") }
    var queryCount: Int { matchingRows(source: querySource, kind: queryKind, query: querySearch).count }
    func query(source: String, kind: String, page: Int, query: String = "") {
        guard source.isEmpty || validIdentifier(source) != nil, ["","text","image","file","folder","group"].contains(kind), (0...20).contains(page) else { return }
        querySource = source; queryKind = kind; queryPage = page; querySearch = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256)); changed()
    }
    func matchingRows(source: String, kind: String, query: String) -> [ClipboardRecord] {
        let search = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        return ((try? database.records()) ?? []).filter {
            (source.isEmpty || $0.content.sourceDeviceId == source) && (kind.isEmpty || $0.content.kind == kind) &&
            (search.isEmpty || ([$0.content.name, $0.content.text ?? "", $0.sourceName] + $0.content.roots).contains(where: { $0.localizedStandardContains(search) }))
        }
    }
    func allKeys(source: String, kind: String, query: String) -> [String] { matchingRows(source: source, kind: kind, query: query).map(\.key) }
    func pageViews() -> [ClipboardRecordView] { makeViews(Array(matchingRows(source: querySource, kind: queryKind, query: querySearch).dropFirst(queryPage * 50).prefix(50))) }
    private(set) var noticeRevision: UInt64 = 0
    // 同文案的连续结果也是新反馈，UI不能仅按字符串去重。
    private(set) var noticeIsReceipt = false
    private(set) var notice: String? { didSet { noticeRevision &+= 1; noticeIsReceipt = false } }

    init(configuration: ServerConfiguration, store: SecureStore, queue: DispatchQueue, localID: String, localName: String,
         engine: FileTransferEngine, peers: [StoredPeer], send: @escaping (UUID, [String: Any]) -> Void, changed: @escaping () -> Void, newLocalContent: @escaping ([String]) -> Void = { _ in },
         captureQueue: DispatchQueue? = nil, platformClipboard: PlatformClipboard? = nil) throws {
        io = captureQueue ?? DispatchQueue(label: "com.chenguangyao.xuqiao.clipboard.io", qos: .utility)
        self.queue = queue; self.localID = localID; self.localName = localName; self.engine = engine; self.peers = peers; self.send = send; self.changed = changed; self.newLocalContent = newLocalContent
        snapshots = try ClipboardSnapshotStore(configuration: configuration)
        database = try ClipboardRecordStore(root: snapshots.storage.root)
        preferencesStore = ClipboardPreferenceStore(root: snapshots.storage.root)
        #if DEBUG
        // 新版默认开启时，任何隔离DEBUG配置都不能意外观察用户系统剪贴板。
        let name = configuration.clipboardPasteboard ?? ((configuration.fileStoreDirectory != nil || configuration.testSessionFile != nil || !configuration.keychainSuffix.isEmpty) ? "xuqiao-isolated-" + digest(Data((configuration.keychainSuffix + snapshots.storage.root.path).utf8)).prefix(24) : nil)
        #else
        let name: String? = nil
        #endif
        adapter = platformClipboard ?? PlatformClipboard(name: name)
        try database.run("UPDATE clipboard_deliveries SET liveEpoch=''")
        // 尚未可靠关联task的请求不能因重启继续下载；已经持久task由文件恢复流程负责。
        try database.run("UPDATE clipboard_records SET downloadState='failed',error='下载请求已失效，请重新下载' WHERE downloadState='requesting' AND localTaskId=''")
        adapter.onRuntime = { [weak self] value in self?.queue.async { self?.runtime(value) } }
        adapter.onCapture = { [weak self] epoch, count, capture in self?.queue.async { self?.automatic(epoch: epoch, count: count, capture: capture) } }
        try snapshots.recoverOrphans(indices: database.snapshots())
        previews = try ClipboardPreviewCoordinator(database: database, snapshots: snapshots, engine: engine, localID: localID, queue: queue,
            peer: { [weak self] id in
                guard let self, let session = self.sessions[id], session.capable, let generation = self.generation(id) else { return nil }
                return ClipboardPreviewPeer(channel: session.channel, generation: generation, capable: session.previewCapable)
            }, allowed: { [weak self] in guard let self else { return false }; return !self.stopped && self.active && self.preferences.enabled && self.preferences.previewsEnabled && self.preferences.kinds.contains("image") }, send: send, changed: changed)
        adapter.start(); try sweep()
    }
    private func invalidateUI() {
        pendingAutomaticCapture = nil; pendingManualCapture = nil
        privateImageCleanupCancellation.cancel()
        previews?.invalidate(); uiEpoch = UUID().uuidString; copyPermits.values.forEach { $0.cancel() }; copyPermits.removeAll(); copySource = nil; copying = false; copyAfter.removeAll()
        batchQueue.removeAll(); batchActive = nil; batchTotal = 0
        invalidateOriginalIntents()
        invalidateSelfIntents()
    }
    private func invalidateOriginalIntents() {
        originalQueue.removeAll(); exportAfter.removeAll()
        imageExportCancellation.cancel(); imageExportCancellation = WorkCancellation()
        if let request = automaticRequest {
            engine.cancelClipboardRequest(request, cancelTask: true)
            if let intent = pendingRequests.removeValue(forKey: request), var row = try? database.find(source: intent.0.sourceDeviceId, id: intent.0.recordId), row.downloadState == "requesting", row.localTaskId.isEmpty {
                row.downloadState = "failed"; row.error = "自动原图缓存已取消，可手动下载"; try? database.save(row)
            }
        }
        automaticRequest = nil; automaticSource = nil
    }
    /// peer会话更替不能旋转全局UI/复制代际，否则会打断另一来源已确认的保存。
    private func invalidatePeerIntents(_ peer: String) {
        previews?.invalidate(peer: peer)
        let prefix = peer + ":"
        originalQueue.removeAll { $0.hasPrefix(prefix) }; exportAfter = exportAfter.filter { !$0.hasPrefix(prefix) }
        copyAfter = copyAfter.filter { !$0.hasPrefix(prefix) }
        copyPermits.removeValue(forKey: peer)?.cancel()
        if copySource == peer { copying = false; copySource = nil }
        let removed = batchQueue.filter { $0.0 == peer }.count
        batchQueue.removeAll { $0.0 == peer }; batchFailed += removed
        if batchActive?.0 == peer { batchActive = nil; batchFailed += 1 }
        if imageExportSource == peer { imageExportCancellation.cancel() }
        if automaticSource == peer, let request = automaticRequest {
            engine.cancelClipboardRequest(request, cancelTask: true)
            automaticRequest = nil; automaticSource = nil
        }
        for (id, item) in pendingRequests where item.0.sourceDeviceId == peer {
            engine.cancelClipboardRequest(id, cancelTask: item.0.privateOnly == true)
            pendingRequests.removeValue(forKey: id)
            if var row = try? database.find(source: peer, id: item.0.recordId), row.downloadState == "requesting", row.localTaskId.isEmpty {
                row.downloadState = "failed"; row.error = "来源连接已变化，请重新下载"; try? database.save(row)
            }
        }
    }
    private func copyPermit(for source: String) -> ClipboardPermit {
        if let permit = copyPermits[source] { return permit }
        let permit = ClipboardPermit(); copyPermits[source] = permit; return permit
    }
    private func invalidateSelfIntents() {
        for (_, intent) in selfRequests {
            intent.1.cancel()
            if var row = try? database.find(source: intent.0.sourceDeviceId, id: intent.0.recordId), row.downloadState == "requesting", row.localTaskId.isEmpty {
                row.downloadState = "failed"; row.error = "本机下载请求已失效，请重新下载"; try? database.save(row)
            }
        }
        selfRequests.removeAll()
    }
    private func generation(_ peer: String) -> String? { peers.first { $0.id == peer }.map { $0.clipboardTrustGeneration ?? "legacy" } }
    private func scope(_ peer: String, _ generation: String) -> String { Data(peer.utf8).base64EncodedString() + ":" + generation }
    private func setting(_ peer: String) -> ClipboardSettings { ClipboardSettings(autoSend: preferences.enabled, receiveEnabled: preferences.enabled) }
    private func remoteAllows(_ peer: String, kind: String) -> Bool {
        guard let gen = generation(peer), let intent = preferencesStore.remoteIntents[scope(peer,gen)] else { return true }
        return intent.syncEnabled && intent.enabledKinds.contains(kind)
    }
    /// 用户设置先原子持久化，再统一旋转所有接收/采集许可，迟到回调不能恢复已关闭的写入。
    func savePreferences(_ value: ClipboardPreferences, expectedContext: String) -> String? {
        guard !stopped, expectedContext == uiEpoch else { return "页面状态已变化，请重试" }
        do { try preferencesStore.save(value) } catch { notice = "设置保存失败，开关未更改"; changed(); return notice }
        invalidateUI(); sourcePermit.cancel(); sourcePermit = ClipboardPermit(); captureToken?.cancel()
        baseline.removeAll(); baselinePending.removeAll()
        for peer in peers { autoVersions[scope(peer.id,peer.clipboardTrustGeneration ?? "legacy")] = UUID().uuidString }
        for (peer, session) in sessions {
            session.incoming.cancel(); session.incoming = ClipboardPermit(); session.localEpoch = receiverEpoch(peer); session.inflight = nil; session.resetHistoryWindow()
            if session.capable { send(session.channel, wire("clip.policy", policy(peer,session))) }
        }
        try? database.run("UPDATE clipboard_deliveries SET liveEpoch=''")
        observerEpoch = UUID(); adapter.observe(false, epoch: observerEpoch); observing = false
        resetObserver(); pumpAll(); notice = "同步设置已保存"; changed(); return nil
    }
    private func applyRemotePolicy(_ message: [String: Any], peer: String, session: RecordSession, accept: Bool) throws {
        func kinds(_ value: Any?) throws -> [String] {
            guard let array = value as? [String], array.count <= 5, Set(array).count == array.count, array.allSatisfy(clipboardKinds.contains) else { throw ClipboardFailure.invalid }; return array
        }
        let accepted = try message["acceptedKinds"].map(kinds) ?? clipboardKinds
        if message["syncEnabled"] != nil || message["enabledKinds"] != nil {
            guard let enabled = clipboardBool(message["syncEnabled"]), let gen = generation(peer) else { throw ClipboardFailure.invalid }
            let enabledKinds = try kinds(message["enabledKinds"])
            var revised = preferencesStore.remoteIntents
            let key = scope(peer,gen), old = revised[key]
            if old?.syncEnabled != enabled || old?.enabledKinds != enabledKinds {
                revised[key] = ClipboardRemoteIntent(syncEnabled: enabled, enabledKinds: enabledKinds)
                try preferencesStore.updateRemoteIntents(revised)
                autoVersions[key] = UUID().uuidString
                session.inflight = nil; session.resetHistoryWindow()
                try database.run("UPDATE clipboard_deliveries SET liveEpoch='' WHERE peerId=? AND trustGeneration=?", [peer,gen])
            }
        }
        session.remoteKinds = accept ? Set(accepted) : []
    }
    private func update(_ peer: String, _ body: (inout RecordPeerMemory) -> Void) { var value = memory[peer] ?? RecordPeerMemory(); body(&value); memory[peer] = value }
    func updatePeers(_ value: [StoredPeer]) {
        let old = Set(peers.map { scope($0.id, $0.clipboardTrustGeneration ?? "legacy") })
        let new = Set(value.map { scope($0.id, $0.clipboardTrustGeneration ?? "legacy") })
        if old != new {
            for peer in peers where !new.contains(scope(peer.id, peer.clipboardTrustGeneration ?? "legacy")) { invalidatePeerIntents(peer.id) }
        }
        peers = value
        if old != new { baseline = baseline.filter { new.contains($0.key) }; resetObserver(); refreshCaptureNotice() }
    }
    func fileCapability(peer: String, file: Bool, group: Bool) { fileCapabilities[peer] = (file,group); pumpOriginals() }
    func detailText(source: String, id: String, context: String) -> String? {
        guard context == uiEpoch else { return nil }; return (try? database.find(source: source, id: id))?.content.text
    }
    /// 只定位本机已有内容；大文件校验放IO队列，完成后重新核对界面身份和任务尝试。
    func locateResource(source: String, id: String, expectedContext: String, completion: @escaping (ClipboardLocalResource?) -> Void) {
        guard active, !stopped, expectedContext == uiEpoch, validIdentifier(source) != nil, validHex(id, count: 32),
              let row = try? database.find(source: source, id: id), row.content.kind != "text" else { completion(nil); return }
        if row.downloadState == "downloaded", let task = tasks.first(where: { localResourceTask($0, matches: row) }) {
            // CopyURLs复用成品散列、图片属性及组提交收据校验，不对任意task或外部路径放行。
            engine.clipboardCopyURLs(taskID: task.id, expectedAttempt: task.attemptId) { [weak self] urls in
                guard let self else { completion(nil); return }
                self.queue.async {
                    guard self.active, !self.stopped, self.uiEpoch == expectedContext,
                          let current = try? self.database.find(source: source, id: id), current.content == row.content,
                          current.downloadState == "downloaded", current.localTaskId == task.id,
                          self.tasks.contains(where: { $0.id == task.id && $0.attemptId == task.attemptId && self.localResourceTask($0, matches: current) }),
                          let urls, let first = urls.first else { completion(nil); return }
                    let url = urls.count == 1 ? first : first.deletingLastPathComponent()
                    completion(ClipboardLocalResource(url: url, isSnapshot: false))
                }
            }
            return
        }
        guard source == localID, row.available,
              let index = try? database.snapshots().first(where: { $0.recordId == id && $0.state == "ready" }),
              index.expiresAt > milliseconds(), index.byteSize == row.content.size,
              let url = try? snapshots.checked(index) else { completion(nil); return }
        snapshots.acquire(id); changed()
        io.async {
            let valid = Result { () throws -> Void in
                guard try hashFile(url, expectedSize: row.content.size) == row.content.sha256 else { throw ClipboardFailure.invalid }
                try ClipboardImage.validate(row.content, at: url)
                if let expected = row.content.group {
                    let group = try GroupZIP.scan(url, expected: expected, cancellation: WorkCancellation())
                    if row.content.kind == "folder" {
                        guard group.roots.count == 1, group.entries.contains(where: { $0.isDirectory && $0.path == group.roots[0] + "/" }) else { throw ClipboardFailure.invalid }
                    }
                }
            }
            self.queue.async {
                var transferred = false
                defer { if !transferred { self.snapshots.release(id); self.changed() } }
                guard case .success = valid, self.active, !self.stopped, self.uiEpoch == expectedContext,
                      let current = try? self.database.find(source: source, id: id), current.content == row.content, current.available,
                      let latest = try? self.database.snapshots().first(where: { $0.recordId == id && $0.state == "ready" }),
                      latest.expiresAt > milliseconds(), latest.byteSize == index.byteSize, latest.createdAt == index.createdAt,
                      latest.relativePath == index.relativePath else { completion(nil); return }
                let lease = ClipboardLocalResourceLease { [weak owner = self] in
                    guard let owner else { return }
                    owner.queue.async { [weak owner = owner] in
                        guard let owner else { return }; owner.snapshots.release(id); owner.changed()
                    }
                }
                transferred = true
                completion(ClipboardLocalResource(url: url, isSnapshot: true, lease: lease))
            }
        }
    }
    private func localResourceTask(_ task: FileTaskView, matches row: ClipboardRecord) -> Bool {
        guard task.id == row.localTaskId, task.direction == .incoming, task.state == .completed, !task.privateOriginalCleared,
              task.peerId == row.content.sourceDeviceId, task.clipboardRecordId == row.content.recordId,
              task.clipboardSourceDeviceId == row.content.sourceDeviceId,
              let request = task.clipboardRequestId, validHex(request, count: 32),
              task.name.utf8.elementsEqual(row.content.name.utf8), task.size == row.content.size, task.sha256 == row.content.sha256 else { return false }
        if row.content.group != nil {
            return task.kind == "group" && task.groupHash == row.content.groupHash && task.entryCount == row.content.entryCount && task.totalBytes == row.content.totalBytes && groupStringsEqual(task.roots, row.content.roots)
        }
        return task.kind == "file"
    }
    func authenticated(peer: String, channel: UUID) {
        guard !stopped, let generation = generation(peer) else { return }
        invalidatePeerIntents(peer); sessions[peer]?.close(); sessions[peer] = RecordSession(channel)
        sessions[peer]?.resumeGuard = disconnectGuards.removeValue(forKey: scope(peer, generation)) ?? adapter.makeResumeGuard()
        fileCapabilities.removeValue(forKey: peer)
        engine.setClipboardTrust(peer: peer, generation: generation)
        pumpBatch(); pumpOriginals(); pumpImageExports()
        try? database.run("UPDATE clipboard_deliveries SET liveEpoch='' WHERE peerId=? AND trustGeneration=?", [peer,generation]); refreshCaptureNotice(); changed()
    }
    func disconnected(_ channel: UUID) {
        for (peer, session) in sessions where session.channel == channel {
            if let gen = generation(peer) { disconnectGuards[scope(peer, gen)] = adapter.makeResumeGuard() }
            invalidatePeerIntents(peer)
            session.close(); sessions.removeValue(forKey: peer); fileCapabilities.removeValue(forKey: peer); update(peer) { $0.send = "连接已断开，原授权记录保留待补送" }
            try? database.run("UPDATE clipboard_deliveries SET liveEpoch='' WHERE peerId=?", [peer])
        }
        invalidateRequests(channel); pumpBatch(); pumpOriginals(); pumpImageExports(); refreshCaptureNotice(); changed()
    }
    private func invalidateRequests(_ channel: UUID? = nil) {
        for (id, item) in pendingRequests where channel == nil || item.1 == channel {
            engine.cancelClipboardRequest(id, cancelTask: item.0.privateOnly == true); pendingRequests.removeValue(forKey: id)
            if automaticRequest == id { automaticRequest = nil; automaticSource = nil }
            exportAfter.remove(item.0.key)
            if var row = try? database.find(source: item.0.sourceDeviceId, id: item.0.recordId), row.downloadState == "requesting", row.localTaskId.isEmpty {
                row.downloadState = "failed"; row.error = "下载请求已失效，请重新下载"; try? database.save(row)
            }
        }
    }
    func resetTrust(_ peer: String) throws {
        invalidatePeerIntents(peer); sessions.removeValue(forKey: peer)?.close(); memory.removeValue(forKey: peer)
        let prefix = Data(peer.utf8).base64EncodedString() + ":"
        var intents = preferencesStore.remoteIntents; intents = intents.filter { !$0.key.hasPrefix(prefix) }
        try preferencesStore.updateRemoteIntents(intents)
        baseline = baseline.filter { !$0.key.hasPrefix(prefix) }; autoVersions = autoVersions.filter { !$0.key.hasPrefix(prefix) }
        try database.run("DELETE FROM clipboard_deliveries WHERE peerId=?", [peer])
        for (id, request) in pendingRequests where request.0.sourceDeviceId == peer { engine.cancelClipboardRequest(id); pendingRequests.removeValue(forKey: id) }
        fileCapabilities.removeValue(forKey: peer)
        resetObserver(); pumpBatch(); pumpOriginals(); pumpImageExports(); refreshCaptureNotice(); changed()
    }
    func stop() {
        pendingAutomaticCapture = nil; pendingManualCapture = nil
        stopped = true; privateImageCleanupCancellation.cancel(); invalidateOriginalIntents(); previews.invalidate(); captureToken?.cancel(); sourcePermit.cancel(); copyPermits.values.forEach { $0.cancel() };
        invalidateSelfIntents(); for session in sessions.values { session.close() }; sessions.removeAll()
        invalidateRequests(); adapter.observe(false, epoch: UUID()); copyAfter.removeAll()
    }
    private func effective(_ peer: String) -> Bool { active && preferences.enabled && !preferences.kinds.isEmpty }
    private func receiverEpoch(_ peer: String) -> String { effective(peer) ? ((try? secureBytes(16)).map(hex) ?? "") : "" }
    private func policy(_ peer: String, _ session: RecordSession) -> [String: Any] {
        ["acceptRecords": effective(peer) && !session.localEpoch.isEmpty, "receiverEpoch": session.localEpoch,
         "acceptedKinds": effective(peer) ? preferences.kinds : [], "syncEnabled": preferences.enabled, "enabledKinds": preferences.kinds, "previewProtocol": "xq-preview/1"]
    }
    private func runtime(_ value: Bool) {
        guard !stopped, value != active else { return }; active = value; invalidateUI()
        sourcePermit.cancel(); sourcePermit = ClipboardPermit(); baseline.removeAll(); baselinePending.removeAll()
        if !value { captureToken?.cancel(); copyAfter.removeAll() }
        for (peer, session) in sessions {
            session.incoming.cancel(); session.incoming = ClipboardPermit(); session.localEpoch = receiverEpoch(peer); session.inflight = nil; session.resetHistoryWindow()
            if session.capable { send(session.channel, wire("clip.policy", policy(peer, session))) }
        }
        try? database.run("UPDATE clipboard_deliveries SET liveEpoch=''")
        resetObserver(); pumpAll(); changed()
    }
    private func resetObserver() {
        let candidates = peers.filter { peer in setting(peer.id).autoSend && preferences.kinds.contains(where: { remoteAllows(peer.id,kind: $0) }) }
        let enabled = active && !candidates.isEmpty
        if observing != enabled { observing = enabled; observerEpoch = UUID(); adapter.observe(enabled, epoch: observerEpoch) }
        guard enabled else { return }
        for peer in candidates {
            let key = scope(peer.id, peer.clipboardTrustGeneration ?? "legacy")
            guard baseline[key] == nil, !baselinePending.contains(key) else { continue }
            baselinePending.insert(key); let permit = sourcePermit
            adapter.changeCount(permit: permit) { [weak self] count in self?.queue.async {
                guard let self, !self.stopped, self.sourcePermit === permit else { return }
                self.baselinePending.remove(key)
                if let count, self.peers.contains(where: { self.scope($0.id, $0.clipboardTrustGeneration ?? "legacy") == key && self.setting($0.id).autoSend }) { self.baseline[key] = count }
            } }
        }
    }
    private func automatic(epoch: UUID, count: Int, capture: ClipboardCapture) {
        guard active, !stopped, epoch == observerEpoch else { return }
        let targets = peers.compactMap { peer -> CaptureTarget? in
            let gen = peer.clipboardTrustGeneration ?? "legacy"
            guard setting(peer.id).autoSend, baseline[scope(peer.id, gen)].map({ count > $0 }) == true else { return nil }
            let key = scope(peer.id, gen)
            if autoVersions[key] == nil { autoVersions[key] = UUID().uuidString }
            return CaptureTarget(peer: peer.id, generation: gen, manual: false, epoch: sessions[peer.id]?.remoteEpoch ?? "", autoVersion: autoVersions[key]!, connection: sessions[peer.id]?.channel, awaitingHello: sessions[peer.id]?.capable == false)
        }
        guard !targets.isEmpty else { return }; self.capture(capture, targets: targets, automatic: true)
    }
    func manual(peer: String, text: String? = nil, expectedContext: String? = nil) {
        guard manualReady(expectedContext: expectedContext) else { return }
        guard let gen = generation(peer) else { notice = "设备配对已变化，本次未发送，请重新选择设备"; changed(); return }
        let target = CaptureTarget(peer: peer, generation: gen, manual: true, epoch: sessions[peer]?.remoteEpoch ?? "", connection: sessions[peer]?.channel, awaitingHello: sessions[peer]?.capable == false)
        if let text { capture(.text(text), targets: [target], automatic: false); return }
        let context = uiEpoch, permit = sourcePermit
        adapter.readCapture(permit: permit) { [weak self] item in self?.queue.async {
            guard let self else { return }
            guard self.uiEpoch == context, self.sourcePermit === permit else { self.notice = "状态已变化，本次未发送，请重新操作"; self.changed(); return }
            if let item { self.capture(item, targets: [target], automatic: false) }
            else { self.notice = "无法准备当前剪贴板，请使用可读取的文本、图片或普通文件/目录"; self.changed() }
        } }
    }
    private func hasActiveTask(_ row: ClipboardRecord) -> Bool {
        tasks.contains { ($0.id == row.localTaskId || ($0.clipboardRecordId == row.content.recordId && $0.clipboardSourceDeviceId == row.content.sourceDeviceId)) && (!$0.state.terminal || $0.state == .committing || $0.state == .interrupted || $0.managementBusy) }
    }
    private func ensureHistoryRoom() throws {
        var rows = try database.records()
        while rows.count >= CLIPBOARD_HISTORY_LIMIT {
            let grants = try database.grants()
            guard let oldest = rows.reversed().first(where: { row in
                !["requesting", "downloading"].contains(row.downloadState) && snapshots.leases[row.content.recordId, default: 0] == 0 &&
                !grants.contains(where: { $0.recordId == row.content.recordId && $0.announcedVersion < row.availabilityVersion }) &&
                !hasActiveTask(row)
            }) else { throw ClipboardFailure(code: "CLIP_BUSY") }
            if oldest.content.sourceDeviceId == localID, let index = try database.snapshots().first(where: { $0.recordId == oldest.content.recordId }), index.state == "ready" { try snapshots.remove(index) }
            try previews?.remove(oldest)
            try database.remove(source: oldest.content.sourceDeviceId, id: oldest.content.recordId, local: oldest.content.sourceDeviceId == localID)
            rows.removeAll { $0.key == oldest.key }
        }
    }
    private func capture(_ input: ClipboardCapture, targets: [CaptureTarget], automatic: Bool, capturedAt: Int64? = nil) {
        let captured = capturedAt ?? milliseconds()
        guard captureToken == nil else {
            let pending = PendingCapture(input: input, targets: targets, automatic: automatic, capturedAt: captured)
            if automatic { pendingAutomaticCapture = pending }
            else if pendingManualCapture == nil {
                // 只替换同一目标的旧自动意图；其他手机仍应收到自己的待同步内容。
                if let older = pendingAutomaticCapture {
                    let replaced = Set(targets.map { scope($0.peer, $0.generation) })
                    let remaining = older.targets.filter { !replaced.contains(scope($0.peer, $0.generation)) }
                    pendingAutomaticCapture = remaining.isEmpty ? nil : PendingCapture(input: older.input, targets: remaining, automatic: true, capturedAt: older.capturedAt)
                }
                pendingManualCapture = pending
                notice = "已加入发送，上一条处理完成后继续"; changed()
            }
            else { notice = "已有一条内容等待发送，本次未加入，请稍后重试"; changed() }
            return
        }
        let token = WorkCancellation(); captureToken = token
        let id = (try? secureBytes(16)).map(hex) ?? ""; guard !id.isEmpty else { captureToken = nil; return }
        // 手动发送是新的明确意图，不能复用已ACK的旧ID；自动采集继续相邻去重。
        let candidate = automatic ? try? freezeCaptureCandidate(targets: targets) : nil
        notice = "正在准备剪贴板记录…"
        for target in targets { update(target.peer) { $0.send = "正在准备剪贴板记录…" } }; changed()
        io.async {
            let result = Result { try self.snapshots.prepare(input, id: id, source: self.localID, capturedAt: captured, cancellation: token) }
            let candidateVerified: Bool
            if case .success(let prepared) = result, let candidate, candidate.row.content.sameCapture(prepared.content), !token.isCancelled {
                candidateVerified = self.verifyCaptureCandidate(candidate)
            } else { candidateVerified = false }
            self.queue.async {
                if let index = candidate?.snapshot { self.snapshots.release(index.recordId) }
                guard self.captureToken === token else {
                    if case .success(let prepared) = result { self.discardPreparedSnapshot(prepared) }
                    return
                }; self.captureToken = nil
                defer { self.drainPendingCapture() }
                do {
                    let prepared = try result.get(); guard !self.stopped, !token.isCancelled else { throw ClipboardFailure(code: "CLIP_STALE") }
                    self.suppressed = self.suppressed.filter { Date().timeIntervalSince($0.value) < 60 }
                    let eligible = targets.filter { target in
                        self.generation(target.peer) == target.generation && self.preferences.kinds.contains(prepared.content.kind) && self.remoteAllows(target.peer,kind: prepared.content.kind) &&
                        (target.manual || self.preferences.enabled && self.autoVersions[self.scope(target.peer,target.generation)] == target.autoVersion)
                    }
                    guard !eligible.isEmpty else {
                        self.discardPreparedSnapshot(prepared); self.notice = "当前内容类型或接收设备已关闭同步"; self.changed(); return
                    }
                    // 原生ownCounts仍阻止自身写入回环；重连首次真实复制不被旧内容摘要或相邻行吞掉。
                    let fresh = eligible.contains(where: self.needsFreshCapture)
                    if automatic && !fresh && self.suppressed[prepared.content.kind + ":" + prepared.content.sha256] != nil {
                        self.discardPreparedSnapshot(prepared); self.notice = nil; self.changed(); return
                    }
                    // 异步快照完成后，按提交队列此刻的最新行判断；先去重再裁历史/清配额。
                    let reused = try self.database.transaction { () throws -> String? in
                        guard let latest = try self.database.latest(), latest.content.sourceDeviceId == self.localID,
                              latest.content.sameCapture(prepared.content), let candidate, candidateVerified,
                              try self.reusableCapture(latest, candidate: candidate) else { return nil }
                        guard try self.canReuseCapture(latest, targets: eligible) else { return nil }
                        try self.saveCaptureGrants(recordId: latest.content.recordId, targets: eligible)
                        return latest.content.recordId
                    }
                    if let reused {
                        self.discardPreparedSnapshot(prepared)
                        for target in eligible { self.update(target.peer) { $0.send = "相同内容已保存" } }
                        self.consumeFreshCapture(eligible)
                        // 尚未开始发送的相同排队内容可复用；已尝试项由canReuseCapture转为新意图。
                        for target in eligible {
                            if let session = self.sessions[target.peer], session.channel == target.connection, session.inflight?.record == reused {
                                session.inflight = nil; session.retryAt = nil
                            }
                        }
                        self.newLocalContent(eligible.map(\.peer))
                        self.trackCaptureNotice(recordID: reused, targets: eligible)
                        self.pumpAll(); self.refreshCaptureNotice(); self.changed(); return
                    }
                    try self.ensureHistoryRoom()
                    if let snapshot = prepared.snapshot {
                        try self.sweep(required: snapshot.byteSize)
                        let used = try self.database.snapshots().filter { $0.state == "ready" }.reduce(Int64(0)) { $0 + $1.byteSize }
                        guard snapshot.byteSize <= self.snapshots.maximum, used <= self.snapshots.maximum - snapshot.byteSize else { throw ClipboardFailure(code: "CLIP_BUSY") }
                    }
                    let row = ClipboardRecord(content: prepared.content, sourceName: self.localName, receivedAt: milliseconds(), cacheExpiresAt: prepared.snapshot?.expiresAt ?? 0)
                    try self.database.transaction {
                        try self.database.save(row)
                        if let snapshot = prepared.snapshot { try self.database.saveSnapshot(snapshot) }
                        try self.saveCaptureGrants(recordId: id, targets: eligible)
                    }
                    // 只在成功提交后消耗当前连接标记；旧连接迟到采集不能消耗新连接的首次机会。
                    self.consumeFreshCapture(eligible)
                    // 只在新本机内容实际落库后通知；相邻复用/刷新/接收远端内容均不制造唤醒。
                    self.newLocalContent(eligible.map(\.peer))
                    self.trackCaptureNotice(recordID: id, targets: eligible)
                    self.pumpAll(); self.refreshCaptureNotice(); self.changed()
                } catch {
                    if case .success(let prepared) = result { self.discardPreparedSnapshot(prepared) }
                    self.notice = (error as? ClipboardFailure).map { clipboardErrorText($0.code) } ?? "准备失败：文件发生变化、不可读取或超过限制，请重新复制"
                    for target in targets where self.generation(target.peer) == target.generation { self.update(target.peer) { $0.send = self.notice ?? "准备失败" } }; self.changed()
                }
            }
        }
    }
    private func drainPendingCapture() {
        guard active, !stopped, captureToken == nil else { return }
        let next = pendingManualCapture ?? pendingAutomaticCapture
        guard let next else { return }
        if next.automatic { pendingAutomaticCapture = nil } else { pendingManualCapture = nil }
        capture(next.input, targets: next.targets, automatic: next.automatic, capturedAt: next.capturedAt)
    }
    private func manualReady(expectedContext: String?) -> Bool {
        guard !stopped else { return false }
        guard expectedContext == nil || expectedContext == uiEpoch else { notice = "页面状态已变化，本次未发送，请重新操作"; changed(); return false }
        guard active else {
            adapter.requestRuntimeRefresh()
            notice = "系统剪贴板尚未恢复，本次未发送，请解锁后重试"; changed(); return false
        }
        return true
    }
    private func canReuseCapture(_ row: ClipboardRecord, targets: [CaptureTarget]) throws -> Bool {
        let grants = try database.grants(recordID: row.content.recordId)
        let attempted = try database.grants(recordID: row.content.recordId, attemptedOnly: true)
        return targets.allSatisfy { target in
            let confirmed = grants.contains { $0.peerId == target.peer && $0.trustGeneration == target.generation && $0.announcedVersion >= row.availabilityVersion }
            if confirmed { return !needsFreshCapture(target) }
            // ACK丢失时对端可能已存但未应用；新复制必须用新ID，不能依赖duplicate-live回写。
            return !attempted.contains { $0.peerId == target.peer && $0.trustGeneration == target.generation }
        }
    }
    private func freezeCaptureCandidate(targets: [CaptureTarget]) throws -> CaptureCandidate? {
        guard let row = try database.latest(), row.content.sourceDeviceId == localID, row.available else { return nil }
        // 仅复用未开始投递的同文排队项；已确认的重连首条及未确认的已尝试项均新建。
        guard try canReuseCapture(row, targets: targets) else { return nil }
        if row.content.kind == "text" { return CaptureCandidate(row: row, snapshot: nil, identity: nil) }
        guard let index = try database.snapshot(id: row.content.recordId), index.state == "ready",
              index.expiresAt > milliseconds(), row.cacheExpiresAt > milliseconds(), index.byteSize == row.content.size,
              let identity = captureSnapshotIdentity(index) else { return nil }
        // 只在服务队列操作lease；IO校验期间GC/用户清理不能移除候选原件。
        snapshots.acquire(index.recordId)
        return CaptureCandidate(row: row, snapshot: index, identity: identity)
    }
    /// 完整文件读取只在clipboard.io调用，不阻塞服务队列的心跳/投屏ACK。
    private func verifyCaptureCandidate(_ candidate: CaptureCandidate) -> Bool {
        if candidate.row.content.kind == "text" { return true }
        guard let index = candidate.snapshot, let frozen = candidate.identity,
              let before = captureSnapshotIdentity(index), sameCaptureIdentity(frozen, before),
              let url = try? snapshots.checked(index), let hash = try? hashFile(url, expectedSize: index.byteSize),
              hash == candidate.row.content.sha256, let after = captureSnapshotIdentity(index) else { return false }
        return sameCaptureIdentity(frozen, after)
    }
    private func reusableCapture(_ row: ClipboardRecord, candidate: CaptureCandidate) throws -> Bool {
        guard row.available, row.seq == candidate.row.seq, row.content.same(candidate.row.content),
              row.availabilityVersion == candidate.row.availabilityVersion, row.cacheExpiresAt == candidate.row.cacheExpiresAt else { return false }
        if row.content.kind == "text" { return true }
        // 回提交队列只核对冻结代际/索引/stat；候选改变时直接正常新增，不追查别的历史。
        guard let frozenIndex = candidate.snapshot, let frozenIdentity = candidate.identity,
              let index = try database.snapshot(id: row.content.recordId), index == frozenIndex,
              index.state == "ready", index.expiresAt > milliseconds(), row.cacheExpiresAt > milliseconds(),
              let identity = captureSnapshotIdentity(index) else { return false }
        return sameCaptureIdentity(frozenIdentity, identity)
    }
    private func captureSnapshotIdentity(_ index: ClipboardSnapshotIndex) -> stat? {
        guard let url = try? snapshots.checked(index) else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == index.byteSize else { return nil }
        return info
    }
    private func sameCaptureIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_mode == second.st_mode && first.st_size == second.st_size &&
        first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec &&
        first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
    private func saveCaptureGrants(recordId: String, targets: [CaptureTarget]) throws {
        for target in targets {
            let epoch = liveCaptureEpoch(target)
            let live = (target.manual || setting(target.peer).autoSend && autoVersions[scope(target.peer,target.generation)] == target.autoVersion) ? epoch : ""
            try database.saveGrant(ClipboardGrant(recordId: recordId, peerId: target.peer, trustGeneration: target.generation, liveEpoch: live, manual: target.manual))
            // 相邻去重复用旧seq时，只刷新此次明确捕获的投递epoch，保留已有ACK版本。
            if !live.isEmpty { try database.run("UPDATE clipboard_deliveries SET liveEpoch=? WHERE recordId=? AND peerId=? AND trustGeneration=?", [live,recordId,target.peer,target.generation]) }
        }
    }
    private func liveCaptureEpoch(_ target: CaptureTarget) -> String {
        guard let session = sessions[target.peer], session.channel == target.connection, generation(target.peer) == target.generation,
              session.capable, session.remoteAccept else { return "" }
        // 首次握手可与快照IO交错，只绑定同一连接首次协商出的epoch；旧非空epoch和旧连接绝不升级。
        guard session.remoteEpoch == target.epoch || target.awaitingHello && target.epoch.isEmpty && session.remoteEpoch == session.initialRemoteEpoch else { return "" }
        return session.remoteEpoch
    }
    private func consumeFreshCapture(_ targets: [CaptureTarget]) {
        for target in targets where needsFreshCapture(target) && !liveCaptureEpoch(target).isEmpty { sessions[target.peer]?.needsFreshCapture = false }
    }
    private func needsFreshCapture(_ target: CaptureTarget) -> Bool {
        guard let session = sessions[target.peer], session.channel == target.connection, generation(target.peer) == target.generation else { return false }
        return session.needsFreshCapture
    }
    private func trackCaptureNotice(recordID: String, targets: [CaptureTarget]) {
        notice = "已保存到剪贴板记录"
        captureNotice = CaptureNotice(recordID: recordID, targets: targets, revision: noticeRevision)
    }
    private func refreshCaptureNotice() {
        guard var tracked = captureNotice else { return }
        // 新准备、排队、清理或其他操作已经取得提示所有权，旧ACK不能覆盖它。
        guard tracked.revision == noticeRevision else { captureNotice = nil; return }
        guard let row = try? database.find(source: localID, id: tracked.recordID), let grants = try? database.grants(recordID: tracked.recordID) else { return }
        let targets = tracked.targets.filter { generation($0.peer) == $0.generation }
        guard !targets.isEmpty else { captureNotice = nil; notice = "已保存到本机，原设备授权已变化"; return }
        let pending = targets.filter { target in
            !grants.contains { $0.peerId == target.peer && $0.trustGeneration == target.generation && $0.announcedVersion >= row.availabilityVersion }
        }
        let done = targets.count - pending.count
        let offline = pending.filter { sessions[$0.peer] == nil }.count
        let online = pending.count - offline
        let preparing = pending.filter { sessions[$0.peer] != nil && sessions[$0.peer]?.capable == false }.count
        let ready = pending.filter { sessions[$0.peer]?.capable == true && sessions[$0.peer]?.remoteAccept == true && sessions[$0.peer]?.remoteKinds.contains(row.content.kind) == true && remoteAllows($0.peer, kind: row.content.kind) }.count
        var parts: [String] = []
        if done > 0 { parts.append("已同步到 \(done) 台设备") }
        // 在线不等于允许接收，混合状态分别计数，不能把等待授权的设备算成正在同步。
        if ready > 0 { parts.append("正在同步到 \(ready) 台设备") }
        if preparing > 0 { parts.append("\(preparing) 台设备剪贴板尚未就绪") }
        if online > ready + preparing { parts.append("等待 \(online - ready - preparing) 台设备开启剪贴板同步") }
        if offline > 0 { parts.append((done > 0 || online > 0 ? "另 " : "") + "\(offline) 台设备连接后自动同步") }
        let failures = targets.filter { tracked.applyErrors.contains(scope($0.peer, $0.generation)) }.count
        if failures > 0 { parts.append("\(failures) 台设备系统剪贴板写入未完成") }
        let revoked = tracked.targets.count - targets.count
        if revoked > 0 { parts.append("\(revoked) 台设备授权已变化") }
        let text = parts.joined(separator: "；")
        if notice != text { notice = text; noticeIsReceipt = true; tracked.revision = noticeRevision; captureNotice = tracked }
        // 全部确认后停止追踪，后续无关消息和空闲事件不再查询这条记录。
        if pending.isEmpty { captureNotice = nil }
    }
    private func discardPreparedSnapshot(_ prepared: ClipboardPrepared) {
        guard let index = prepared.snapshot else { return }
        // 只清本次新ID，绝不碰复用记录的共享payload或已下载成品。
        do {
            try snapshots.remove(index)
            let directory = snapshots.path(index.recordId).deletingLastPathComponent()
            guard rmdir(directory.path) == 0 else { return }
            try synchronizeDirectory(directory.deletingLastPathComponent())
        } catch { /* 启动恢复仍会回收未落库的本机快照。 */ }
    }
    private func error(_ session: RecordSession, message: [String: Any], code: String) {
        var fields: [String: Any] = ["code": code]
        for key in ["deliveryId", "recordId", "downloadRequestId"] {
            if let id = message[key] as? String, validHex(id, count: 32) { fields[key] = id }
        }
        send(session.channel, wire("clip.error", fields))
    }
    func control(peer: String, channel: UUID, message: [String: Any]) {
        guard !stopped, let session = sessions[peer], session.channel == channel else { return }
        guard peer != localID else { error(session, message: message, code: "CLIP_INVALID"); return }
        switch message["type"] as? String {
        case "clip.hello":
            guard message["protocol"] as? String == clipboardProtocol,
                  fileInteger(message["maxTextBytes"], maximum: Int64(clipboardLimit)) == Int64(clipboardLimit),
                  let accept = clipboardBool(message["acceptRecords"]), let epoch = message["receiverEpoch"] as? String,
                  accept ? validHex(epoch, count: 32) : epoch.isEmpty else {
                update(peer) { $0.send = "剪贴板协议不兼容，请升级两端应用" }; error(session, message: message, code: "CLIP_INVALID"); changed(); return
            }
            guard !session.capable else { return }
            do { try applyRemotePolicy(message,peer: peer,session: session,accept: accept) }
            catch { self.error(session,message: message,code: "CLIP_INVALID"); changed(); return }
            session.previewCapable = message["previewProtocol"] as? String == "xq-preview/1"
            session.resumeTextCapable = message["resumeTextProtocol"] as? String == "xq-resume-text/1"
            session.capable = true; session.remoteAccept = accept; session.remoteEpoch = epoch; session.initialRemoteEpoch = epoch; session.localEpoch = receiverEpoch(peer)
            var fields = policy(peer, session); fields["protocol"] = clipboardProtocol; fields["maxTextBytes"] = clipboardLimit
            fields["resumeTextProtocol"] = "xq-resume-text/1"
            send(channel, wire("clip.hello", fields)); pump(peer)
        case "clip.policy":
            guard session.capable, let accept = clipboardBool(message["acceptRecords"]), let epoch = message["receiverEpoch"] as? String,
                  accept ? validHex(epoch, count: 32) : epoch.isEmpty else { error(session, message: message, code: "CLIP_INVALID"); return }
            let previousKinds = session.remoteKinds
            do { try applyRemotePolicy(message,peer: peer,session: session,accept: accept) }
            catch { self.error(session,message: message,code: "CLIP_INVALID"); changed(); return }
            if session.remoteAccept != accept || session.remoteEpoch != epoch || previousKinds != session.remoteKinds || session.historyBoundary == nil {
                invalidatePeerIntents(peer); session.inflight = nil; session.remoteAccept = accept; session.remoteEpoch = epoch; session.resetHistoryWindow()
                try? database.run("UPDATE clipboard_deliveries SET liveEpoch='' WHERE peerId=?", [peer]); pump(peer); pumpBatch(); pumpOriginals(); pumpImageExports()
            }
        case "clip.preview.request", "clip.preview", "clip.preview.error": previews.control(peer: peer, channel: channel, message: message)
        case "clip.record": receive(peer: peer, session: session, message: message)
        case "clip.recordAck":
            guard let flight = session.inflight, message["deliveryId"] as? String == flight.delivery,
                  message["recordId"] as? String == flight.record, message["sha256"] as? String == flight.hash,
                  clipInteger(message["availabilityVersion"]) == flight.version, let status = message["status"] as? String,
                  ["stored", "applied", "duplicate"].contains(status), let gen = generation(peer) else { return }
            do {
                if let row = try database.find(source: localID, id: flight.record), row.availabilityVersion == flight.version {
                    try database.run("UPDATE clipboard_deliveries SET announcedVersion=MAX(announcedVersion,?),liveEpoch='' WHERE recordId=? AND peerId=? AND trustGeneration=?", [flight.version,flight.record,peer,gen])
                }
                if var tracked = captureNotice, tracked.revision == noticeRevision, tracked.recordID == flight.record,
                   tracked.targets.contains(where: { $0.peer == peer && $0.generation == gen }) {
                    let key = scope(peer, gen)
                    if (message["applyError"] as? String)?.isEmpty == false { tracked.applyErrors.insert(key) } else { tracked.applyErrors.remove(key) }
                    captureNotice = tracked
                }
                session.inflight = nil; update(peer) { $0.sent += 1; $0.send = (message["applyError"] as? String)?.isEmpty == false ? "记录已送达，系统剪贴板写入未完成" : "记录已同步" }; pump(peer)
            } catch { notice = "投递确认保存失败，保留待重试记录" }
        case "clip.download": serveDownload(peer: peer, session: session, message: message)
        case "clip.error":
            if let flight = session.inflight, message["deliveryId"] as? String == flight.delivery, message["recordId"] as? String == flight.record {
                session.inflight = nil; session.retryAt = Date().addingTimeInterval(1); update(peer) { $0.send = clipboardErrorText(message["code"] as? String ?? "CLIP_INVALID") }
                // 当前epoch的明确意图须跨瞬时错误/ACK超时保留；ACK、策略变化或断连才结束资格。
            }
            if let request = message["downloadRequestId"] as? String, let pending = pendingRequests[request], pending.0.sourceDeviceId == peer,
               message["recordId"] as? String == pending.0.recordId, pending.1 == channel {
                engine.cancelClipboardRequest(request); pendingRequests.removeValue(forKey: request)
                if automaticRequest == request { automaticRequest = nil }
                exportAfter.remove(pending.0.key)
                if var row = try? database.find(source: peer, id: pending.0.recordId), row.downloadState == "requesting" {
                    row.downloadState = "failed"; row.error = clipboardErrorText(message["code"] as? String ?? "CLIP_INVALID"); try? database.save(row)
                }
            }
        default: error(session, message: message, code: "CLIP_INVALID")
        }
        resetObserver(); pumpBatch(); pumpOriginals(); refreshCaptureNotice(); changed()
    }
    private func receive(peer: String, session: RecordSession, message: [String: Any]) {
        guard session.capable else { error(session, message: message, code: "CLIP_INVALID"); return }
        guard effective(peer) else { error(session, message: message, code: "CLIP_DISABLED"); return }
        guard message["receiverEpoch"] as? String == session.localEpoch, !session.localEpoch.isEmpty else { error(session, message: message, code: "CLIP_STALE"); return }
        guard session.receiving + session.preparingDownloads < 32 else { error(session, message: message, code: "CLIP_BUSY"); return }
        do {
            guard let delivery = message["deliveryId"] as? String, validHex(delivery, count: 32),
                  let mode = message["deliveryMode"] as? String, ["live", "history", "resume"].contains(mode), let available = clipboardBool(message["available"]),
                  let version = clipInteger(message["availabilityVersion"]), let expires = clipInteger(message["cacheExpiresAt"]) else { throw ClipboardFailure.invalid }
            let content = try ClipboardContent.parse(message)
            guard mode != "resume" || session.resumeTextCapable && content.kind == "text" else { throw ClipboardFailure.invalid }
            guard preferences.kinds.contains(content.kind) else { error(session,message: message,code: "CLIP_DISABLED"); return }
            guard content.sourceDeviceId == peer, content.kind == "text" ? (available && version == 0 && expires == 0) : (expires > 0 && (version == 0 ? available : !available)) else { throw ClipboardFailure.invalid }
            var existing = try database.find(source: peer, id: content.recordId)
            if let old = existing { guard old.content.same(content) else { throw ClipboardFailure.invalid } }
            if var old = existing {
                if version > old.availabilityVersion {
                    guard old.available || !available else { throw ClipboardFailure.invalid }
                    old.available = available; old.availabilityVersion = version; old.cacheExpiresAt = expires; try database.save(old); existing = old
                }
                update(peer) { $0.duplicates += 1 }
                if mode != "resume" {
                    acknowledge(session, delivery: delivery, row: existing!, version: version, status: "duplicate"); enqueueOriginal(existing!); return
                }
            }
            if existing == nil { try ensureHistoryRoom() }
            let name = peers.first(where: { $0.id == peer })?.name ?? "设备"
            let row = existing ?? ClipboardRecord(content: content, sourceName: name, receivedAt: milliseconds(), available: available, availabilityVersion: version, cacheExpiresAt: expires)
            try database.save(row); update(peer) { if existing == nil { $0.received += 1 }; $0.receive = "已保存剪贴板记录" }
            enqueueOriginal(row)
            guard preferences.autoApplyText, content.kind == "text", mode == "live" || mode == "resume" && !session.resumeReceived, let text = content.text else { acknowledge(session, delivery: delivery, row: row, version: version, status: "stored"); return }
            if mode == "resume" { session.resumeReceived = true }
            session.receiving += 1; if mode != "resume" { suppress(content) }
            let permit = session.incoming
            adapter.write(text, permit: permit, resumeGuard: mode == "resume" ? session.resumeGuard : nil) { [weak self, weak session] result in self?.queue.async {
                guard let self, let session else { return }; session.receiving = max(0, session.receiving - 1)
                guard self.sessions[peer] === session, session.incoming === permit, !self.stopped else { return }
                let protected = mode == "resume" && result == nil
                if mode == "resume", result == true { self.suppress(content) }
                self.update(peer) { $0.receive = protected ? "已保留本机新复制的内容" : result == true ? "记录已保存并写入剪贴板" : "记录已保存，自动写入失败，可手动复制" }
                if result == false { var failed = row; failed.error = "自动写入失败，可手动复制"; try? self.database.save(failed) }
                self.acknowledge(session, delivery: delivery, row: row, version: version, status: result == true ? "applied" : "stored", applyError: result == false ? "CLIP_IO" : nil); self.changed()
            } }
        } catch { self.error(session, message: message, code: (error as? ClipboardFailure)?.code ?? "CLIP_IO") }
    }
    private func acknowledge(_ session: RecordSession, delivery: String, row: ClipboardRecord, version: Int64, status: String, applyError: String? = nil) {
        var fields: [String: Any] = ["deliveryId": delivery, "recordId": row.content.recordId, "sha256": row.content.sha256, "availabilityVersion": version, "status": status]
        if let applyError { fields["applyError"] = applyError }; send(session.channel, wire("clip.recordAck", fields))
    }
    private func suppress(_ content: ClipboardContent) {
        suppressed[content.kind + ":" + content.sha256] = Date()
        suppressed = suppressed.filter { Date().timeIntervalSince($0.value) < 60 }
        while suppressed.count > 128, let key = suppressed.min(by: { $0.value < $1.value })?.key { suppressed.removeValue(forKey: key) }
    }
    /// 接收代际只冻结一次最近5条已授权ID；先选集合再判断ACK，不能边确认边向更旧历史扩窗。
    private func freezeHistoryWindow(_ peer: String, session: RecordSession, generation: String) throws {
        let rows = try database.records().filter { $0.content.sourceDeviceId == localID }.sorted { $0.seq > $1.seq }
        let grants = try database.grants().filter { $0.peerId == peer && $0.trustGeneration == generation && ($0.manual || setting(peer).autoSend) }
        let authorized = Set(grants.map(\.recordId))
        session.historyBoundary = rows.first?.seq ?? 0
        session.historyRecordIDs = Set(rows.filter { authorized.contains($0.content.recordId) && preferences.kinds.contains($0.content.kind) && session.remoteKinds.contains($0.content.kind) && remoteAllows(peer,kind: $0.content.kind) }.prefix(5).map { $0.content.recordId })
        session.historyGeneration = generation
    }
    private func pumpAll() { for peer in sessions.keys { pump(peer) } }
    /// 每次连接只读取一次当前项，不从历史寻找替代文本，也不把收到的内容转发成自己的内容。
    private func prepareResume(_ peer: String, session: RecordSession, generation: String) {
        guard !session.resumePreparing else { return }; session.resumePreparing = true
        guard setting(peer).autoSend, preferences.kinds.contains("text"), session.remoteKinds.contains("text"), remoteAllows(peer, kind: "text"),
              let row = try? database.latest(), row.content.sourceDeviceId == localID, row.content.kind == "text", row.available,
              (try? database.grants().contains { $0.recordId == row.content.recordId && $0.peerId == peer && $0.trustGeneration == generation }) == true else {
            session.resumePrepared = true; session.resumePreparing = false; pump(peer); return
        }
        let permit = session.incoming, epoch = session.remoteEpoch
        adapter.readCapture(permit: permit) { [weak self, weak session] capture in self?.queue.async {
            guard let self, let session, self.sessions[peer] === session else { return }
            guard session.incoming === permit, session.remoteEpoch == epoch else {
                session.resumePreparing = false; self.pump(peer); return
            }
            session.resumePrepared = true; session.resumePreparing = false
            if case .text(let text) = capture, text == row.content.text, self.setting(peer).autoSend { session.resumeRecord = row }
            self.pump(peer)
        } }
    }
    private func pump(_ peer: String) {
        guard !stopped, active, let session = sessions[peer], session.capable, session.remoteAccept, session.inflight == nil, let gen = generation(peer) else { return }
        // 普通空闲tick不进入历史投递扫描；只有数据/授权/ACK事件或明确失败期限才驱动。
        session.retryAt = nil
        #if DEBUG
        deliveryScanCount += 1
        #endif
        do {
            if session.resumeTextCapable && !session.resumePrepared { prepareResume(peer, session: session, generation: gen); return }
            if let row = session.resumeRecord {
                session.resumeRecord = nil
                if setting(peer).autoSend && preferences.kinds.contains("text") && session.remoteKinds.contains("text") && remoteAllows(peer, kind: "text"),
                   let latest = try database.latest(), latest.content.recordId == row.content.recordId, latest.content.same(row.content), latest.available,
                   try database.grants().contains(where: { $0.recordId == row.content.recordId && $0.peerId == peer && $0.trustGeneration == gen }) {
                    let delivery = hex(try secureBytes(16))
                    try database.run("UPDATE clipboard_deliveries SET attempted=1 WHERE recordId=? AND peerId=? AND trustGeneration=?", [row.content.recordId,peer,gen])
                    session.inflight = (delivery,row.content.recordId,row.content.sha256,row.availabilityVersion,Date(),false)
                    send(session.channel, wire("clip.record", row.wire(delivery: delivery, epoch: session.remoteEpoch, mode: "resume")))
                    refreshCaptureNotice()
                    changed(); return
                }
            }
            if session.historyBoundary == nil || session.historyGeneration != gen { try freezeHistoryWindow(peer,session: session,generation: gen) }
            guard let boundary = session.historyBoundary else { return }
            let rows = try database.records().filter { $0.content.sourceDeviceId == localID }.sorted { $0.seq < $1.seq }
            let grants = try database.grants().filter { $0.peerId == peer && $0.trustGeneration == gen && ($0.manual || setting(peer).autoSend) }
            for row in rows {
                guard preferences.kinds.contains(row.content.kind), session.remoteKinds.contains(row.content.kind), remoteAllows(peer,kind: row.content.kind) else { continue }
                guard let grant = grants.first(where: { $0.recordId == row.content.recordId && $0.announcedVersion < row.availabilityVersion }) else { continue }
                let live = !grant.liveEpoch.isEmpty && grant.liveEpoch == session.remoteEpoch
                // 新seq/当前epoch明确意图不受历史上限限制；已确认旧条目的失效更新仍须可靠公告。
                guard row.seq > boundary || session.historyRecordIDs.contains(row.content.recordId) || grant.announcedVersion >= 0 || live else { continue }
                let delivery = hex(try secureBytes(16))
                try database.run("UPDATE clipboard_deliveries SET attempted=1 WHERE recordId=? AND peerId=? AND trustGeneration=?", [row.content.recordId,peer,gen])
                session.inflight = (delivery,row.content.recordId,row.content.sha256,row.availabilityVersion,Date(),grant.manual)
                send(session.channel, wire("clip.record", row.wire(delivery: delivery, epoch: session.remoteEpoch, mode: live ? "live" : "history")))
                update(peer) { $0.send = "正在同步记录…" }; refreshCaptureNotice(); changed(); return
            }
        } catch {
            session.retryAt = Date().addingTimeInterval(1)
            if notice != "无法读取待同步记录" { notice = "无法读取待同步记录"; changed() }
        }
    }
    private func serveDownload(peer: String, session: RecordSession, message: [String: Any]) {
        guard session.receiving + session.preparingDownloads < 32 else { error(session, message: message, code: "CLIP_BUSY"); return }
        do {
            guard session.capable, let id = message["recordId"] as? String, validHex(id, count: 32), let request = message["downloadRequestId"] as? String, validHex(request, count: 32),
                  let gen = generation(peer), let row = try database.find(source: localID, id: id), row.content.kind != "text",
                  try database.grants().contains(where: { $0.recordId == id && $0.peerId == peer && $0.trustGeneration == gen }) else { throw ClipboardFailure(code: "CLIP_NOT_FOUND") }
            guard fileCapabilities[peer]?.0 == true, row.content.group == nil || fileCapabilities[peer]?.1 == true else { throw ClipboardFailure.invalid }
            guard row.available, let index = try database.snapshots().first(where: { $0.recordId == id }), index.state == "ready", index.expiresAt > milliseconds() else { throw ClipboardFailure(code: "CLIP_EXPIRED") }
            let url = try snapshots.checked(index); snapshots.acquire(id); session.preparingDownloads += 1
            let binding = ClipboardBinding(sourceDeviceId: localID, recordId: id, downloadRequestId: request, trustGeneration: gen)
            engine.prepareClipboardSend(peer: peer, control: session.channel, content: row.content, binding: binding, snapshot: url) { [weak self, weak session] error in self?.queue.async {
                guard let self else { return }; self.snapshots.release(id)
                defer { self.changed() }
                session?.preparingDownloads = max(0, (session?.preparingDownloads ?? 1) - 1)
                guard let session, self.sessions[peer] === session else { return }
                if let error { self.error(session, message: message, code: error) }
            } }
        } catch { self.error(session, message: message, code: (error as? ClipboardFailure)?.code ?? "CLIP_IO") }
    }
    func downloadMany(keys: [String], context: String) {
        guard context == uiEpoch, batchActive == nil, batchQueue.isEmpty else { notice = "请等待当前批量下载完成"; changed(); return }
        let selected = Set(keys), rows = ((try? database.records()) ?? []).filter { selected.contains($0.key) && $0.content.kind != "text" }
        guard !rows.isEmpty else { return }
        batchQueue = rows.map { ($0.content.sourceDeviceId,$0.content.recordId) }; batchTotal = rows.count; batchCompleted = 0; batchFailed = 0
        pumpBatch()
    }
    private func pumpBatch() {
        guard !clearingPrivateImages else { return }
        if let active = batchActive {
            if let row = try? database.find(source: active.0, id: active.1) {
                guard ["downloaded","failed"].contains(row.downloadState) else { return }
                if row.downloadState == "downloaded" { batchCompleted += 1 } else { batchFailed += 1 }
            } else { batchFailed += 1 }
            batchActive = nil
        }
        guard !batchQueue.isEmpty else {
            if batchTotal > 0 { notice = "批量下载：已完成\(batchCompleted)/\(batchTotal)项；跳过或失败\(batchFailed)项"; batchTotal = 0 }; return
        }
        let next = batchQueue.removeFirst(); batchActive = next
        download(source: next.0, id: next.1)
        if let row = try? database.find(source: next.0, id: next.1) {
            if ["downloaded","failed"].contains(row.downloadState) { pumpBatch() }
        } else { pumpBatch() }
    }
    func download(source: String, id: String, expectedContext: String? = nil, privateOnly: Bool = false) {
        guard !stopped, active, expectedContext == nil || expectedContext == uiEpoch else { return }
        guard !clearingPrivateImages else { notice = "正在清理内部原图，请完成后再下载"; changed(); return }
        do {
            guard var row = try database.find(source: source, id: id), row.content.kind != "text" else { throw ClipboardFailure.invalid }
            if row.content.kind == "image", !privateOnly, !copyAfter.contains(row.key) { exportAfter.insert(row.key) }
            if row.downloadState == "downloaded", tasks.contains(where: { localResourceTask($0, matches: row) }) {
                if copyAfter.remove(row.key) != nil { copyRecord(source: source, id: id) }
                pumpImageExports(); return
            }
            guard !["requesting", "downloading"].contains(row.downloadState) else { notice = row.content.kind == "image" ? "原图就绪后保存到 Downloads/续桥" : "所选记录已有下载任务"; changed(); return }
            let request = hex(try secureBytes(16))
            if source == localID {
                guard row.available, let index = try database.snapshots().first(where: { $0.recordId == id }), index.state == "ready", index.expiresAt > milliseconds() else { throw ClipboardFailure(code: "CLIP_EXPIRED") }
                let path = try snapshots.checked(index); snapshots.acquire(id)
                row.downloadState = "requesting"; row.localTaskId = ""; row.error = ""; try database.save(row)
                let binding = ClipboardBinding(sourceDeviceId: source, recordId: id, downloadRequestId: request, trustGeneration: "self")
                let permit = ClipboardPermit(); selfRequests[request] = (binding,permit)
                engine.materializeClipboard(content: row.content, binding: binding, snapshot: path, permit: permit) { [weak self] failure in self?.queue.async {
                    guard let self else { return }; self.snapshots.release(id)
                    guard self.selfRequests.removeValue(forKey: request) != nil else { self.changed(); return }
                    if let failure, var latest = try? self.database.find(source: source, id: id), latest.downloadState == "requesting", latest.localTaskId.isEmpty {
                        latest.downloadState = "failed"; latest.error = clipboardErrorText(failure); try? self.database.save(latest)
                    }
                    if failure != nil { self.exportAfter.remove(source + ":" + id) }
                    self.pumpBatch(); self.pumpImageExports(); self.changed()
                } }
            } else {
                guard let session = sessions[source], session.capable, let gen = generation(source) else { throw ClipboardFailure(code: "CLIP_NOT_FOUND") }
                guard fileCapabilities[source]?.0 == true, row.content.group == nil || fileCapabilities[source]?.1 == true else {
                    row.downloadState = "failed"; row.error = "原来源尚未协商所需文件/目录传输能力"; try database.save(row); exportAfter.remove(row.key); notice = row.error; changed(); return
                }
                guard row.available else { throw ClipboardFailure(code: "CLIP_EXPIRED") }
                let binding = ClipboardBinding(sourceDeviceId: source, recordId: id, downloadRequestId: request, trustGeneration: gen, privateOnly: privateOnly ? true : nil)
                row.downloadState = "requesting"; row.localTaskId = ""; row.error = ""; try database.save(row)
                pendingRequests[request] = (binding,session.channel,Date())
                if privateOnly { automaticRequest = request; automaticSource = source }
                engine.registerClipboardRequest(binding, control: session.channel)
                send(session.channel, wire("clip.download", ["recordId": id, "downloadRequestId": request]))
            }
            if !privateOnly { notice = row.content.kind == "image" ? "原图就绪后保存到 Downloads/续桥" : "已明确请求原来源内容" }; changed()
        } catch {
            exportAfter.remove(source + ":" + id)
            if var row = try? database.find(source: source, id: id), row.downloadState != "downloaded" { row.downloadState = "failed"; row.error = source != localID && sessions[source] == nil ? "来源设备未连接，请连接原来源设备" : clipboardErrorText((error as? ClipboardFailure)?.code ?? "CLIP_IO"); try? database.save(row) }
            notice = source != localID && sessions[source] == nil ? "来源设备未连接，未向其它设备发送请求" : clipboardErrorText((error as? ClipboardFailure)?.code ?? "CLIP_IO"); changed()
        }
    }
    func tasksChanged(_ value: [FileTaskView]) {
        tasks = value
        do {
            let keys = Set(value.filter { $0.direction == .incoming && $0.clipboardRecordId != nil }.map { ($0.clipboardSourceDeviceId ?? "") + ":" + ($0.clipboardRecordId ?? "") })
            for var row in try database.records() where keys.contains(row.key) {
                let matching = value.filter { $0.clipboardRecordId == row.content.recordId && $0.clipboardSourceDeviceId == row.content.sourceDeviceId && $0.direction == .incoming }
                guard let task = matching.first(where: { $0.id == row.localTaskId }) ?? matching.first else { continue }
                // 新明确请求还未匹配task时，不能拿旧失败记录抢占关联。
                let request = pendingRequests.values.first(where: { $0.0.key == row.key })?.0 ?? selfRequests.values.first(where: { $0.0.key == row.key })?.0
                if row.downloadState == "requesting", let request, request.downloadRequestId != task.clipboardRequestId { continue }
                if row.downloadState == "downloaded", row.localTaskId != task.id { continue }
                let previousState = row.downloadState, previousTask = row.localTaskId, previousError = row.error
                row.localTaskId = task.id
                if task.state == .completed {
                    row.downloadState = task.privateOriginalCleared || (task.clipboardPrivateOnly && task.privateCacheBytes == 0) ? "failed" : "downloaded"
                    row.error = row.downloadState == "failed" ? "内部原图已清理或丢失，可重新下载" : ""
                }
                else if [.cancelled, .failed, .rejected].contains(task.state) || (task.state == .interrupted && row.content.sourceDeviceId == localID) { row.downloadState = "failed"; row.error = task.error ?? "下载未完成" }
                else { row.downloadState = "downloading"; row.error = task.state == .interrupted ? "连接中断，等待原来源恢复" : "" }
                if previousState != row.downloadState || previousTask != row.localTaskId || previousError != row.error { try database.save(row) }
                if let request = task.clipboardRequestId {
                    pendingRequests.removeValue(forKey: request)
                    if automaticRequest == request, task.state.terminal { automaticRequest = nil; automaticSource = nil }
                }
                if row.downloadState == "failed" { exportAfter.remove(row.key) }
                if row.content.kind == "image", row.downloadState == "downloaded", previousState != "downloaded" {
                    // 原图就绪后让可见列表从完整成品下采样，替换不支持或失败的小图请求状态。
                    previews.invalidate(); previews.request(keys: [row.key], context: uiEpoch)
                }
                if row.downloadState == "downloaded", copyAfter.remove(row.key) != nil { copyRecord(source: row.content.sourceDeviceId, id: row.content.recordId) }
            }
        } catch { notice = "下载关联状态保存失败，将在重启后核对" }
        pumpBatch(); pumpImageExports(); pumpOriginals(); changed()
    }
    func copyRecord(source: String, id: String, expectedContext: String? = nil) {
        guard active, !stopped, !copying, expectedContext == nil || expectedContext == uiEpoch else { return }
        guard !clearingPrivateImages else { notice = "正在清理内部原图，请完成后再复制"; changed(); return }
        do {
            guard let row = try database.find(source: source, id: id) else { throw ClipboardFailure.invalid }
            if let text = row.content.text {
                suppress(row.content); let permit = copyPermit(for: source), context = uiEpoch
                adapter.write(text, permit: permit) { [weak self] success in self?.queue.async {
                    guard let self, self.uiEpoch == context, self.copyPermits[source] === permit, !self.stopped else { return }
                    self.notice = success == true ? "已复制文本" : "系统剪贴板写入失败"; self.changed()
                } }; return
            }
            guard row.downloadState == "downloaded", let task = tasks.first(where: { $0.id == row.localTaskId && $0.state == .completed }) else {
                if source == localID { copyAfter.insert(row.key); download(source: source, id: id); return }
                notice = "请先下载原来源内容，再复制"; changed(); return
            }
            copying = true; copySource = source; let permit = copyPermit(for: source), context = uiEpoch
            engine.clipboardCopyURLs(taskID: task.id, expectedAttempt: task.attemptId) { [weak self] urls in
                guard let self else { return }
                self.io.async {
                    let capture = Result { () throws -> ClipboardCapture in
                        guard let urls, !urls.isEmpty else { throw ClipboardFailure.io }
                        if row.content.kind == "image" {
                            let directory = self.snapshots.storage.root.appendingPathComponent("ClipboardCopies")
                            try FileStorage.directory(directory)
                            let url = directory.appendingPathComponent(UUID().uuidString + ".png"); defer { try? FileManager.default.removeItem(at: url) }
                            _ = try ClipboardImage.png(Data(contentsOf: urls[0], options: .mappedIfSafe), to: url)
                            let bytes = try Data(contentsOf: url); guard bytes.count <= FILE_MAX_SIZE else { throw ClipboardFailure.invalid }; return .image(bytes)
                        }
                        return .paths(urls)
                    }
                    self.queue.async {
                        guard !self.stopped, self.uiEpoch == context, self.copyPermits[source] === permit else { return }
                        switch capture {
                        case .failure: self.copying = false; self.copySource = nil; self.notice = "本地内容校验失败，请重新下载或先保存"; self.changed()
                        case .success(let item):
                            self.suppress(row.content)
                            self.adapter.writeContent(item, permit: permit) { success in self.queue.async {
                                guard self.uiEpoch == context, self.copyPermits[source] === permit, !self.stopped else { return }
                                self.copying = false; self.copySource = nil
                                self.notice = success == true ? "已写入系统剪贴板；如目标应用不能访问文件，请先保存后复制" : "系统无法复制此内容，请先保存"; self.changed()
                            } }
                        }
                    }
                }
            }
        } catch { notice = "无法复制该记录，请检查来源和本地下载内容"; changed() }
    }
    func cancelDownload(source: String, id: String, expectedContext: String) {
        guard expectedContext == uiEpoch else { return }
        if let row = try? database.find(source: source, id: id) {
            for (request, value) in pendingRequests where value.0.key == row.key { engine.cancelClipboardRequest(request, cancelTask: true); pendingRequests.removeValue(forKey: request) }
            for (request, intent) in selfRequests where intent.0.key == row.key { intent.1.cancel(); engine.cancelClipboardRequest(request, cancelTask: true); selfRequests.removeValue(forKey: request) }
            if let task = tasks.first(where: { $0.id == row.localTaskId }) { engine.cancel(task.id, expectedAttempt: task.attemptId) }
            if var current = try? database.find(source: source, id: id), current.downloadState != "downloaded" { current.downloadState = "failed"; current.error = "用户已取消下载"; try? database.save(current) }
        }
        let key = source + ":" + id
        copyAfter.remove(key); exportAfter.remove(key); originalQueue.removeAll { $0 == key }
        if let request = automaticRequest, !pendingRequests.keys.contains(request) { automaticRequest = nil; automaticSource = nil }
        pumpBatch(); pumpOriginals(); changed()
    }
    func delete(source: String, id: String, expectedContext: String) {
        guard expectedContext == uiEpoch else { return }
        do {
            guard let row = try database.find(source: source, id: id), !copying, !["requesting", "downloading"].contains(row.downloadState), snapshots.leases[id, default: 0] == 0, !hasActiveTask(row) else { notice = "请先取消或完成该记录的活动下载或复制"; changed(); return }
            try removeRecordAndUnusedCache(row)
            // 删除在途记录会释放投递槽位，由本次事件继续投递，空闲计时器不扫描历史。
            pumpAll()
            let failures = engine.cleanHiddenHistoryCache()
            notice = failures == 0 ? "记录已删除，无引用的临时内容已清理；用户保存的文件保留" : "记录已删除，部分旧临时内容清理失败；用户保存的文件保留"
            changed()
        } catch { notice = "记录删除失败"; changed() }
    }

    func manualToAll(text: String?, expectedContext: String) {
        guard manualReady(expectedContext: expectedContext) else { return }
        let targets = peers.compactMap { peer -> CaptureTarget? in
            guard let generation = generation(peer.id) else { return nil }
            return CaptureTarget(peer: peer.id, generation: generation, manual: true, epoch: sessions[peer.id]?.remoteEpoch ?? "", connection: sessions[peer.id]?.channel, awaitingHello: sessions[peer.id]?.capable == false)
        }
        guard !targets.isEmpty else { notice = "请先连接或配对一台手机"; changed(); return }
        if let text { capture(.text(text), targets: targets, automatic: false); return }
        let permit = sourcePermit
        adapter.readCapture(permit: permit) { [weak self] item in self?.queue.async {
            guard let self else { return }
            guard self.uiEpoch == expectedContext, self.sourcePermit === permit else { self.notice = "状态已变化，本次未发送，请重新操作"; self.changed(); return }
            if let item { self.capture(item, targets: targets, automatic: false) }
            else { self.notice = "当前剪贴板没有可同步的内容"; self.changed() }
        } }
    }
    func requestPreviews(keys: [String], context: String) {
        guard context == uiEpoch, !clearingPrivateImages else { return }
        let selected = Set(keys.prefix(50))
        for row in ((try? database.records()) ?? []) where selected.contains(row.key) { enqueueOriginal(row, pump: false) }
        pumpOriginals(); previews.request(keys: keys, context: context)
    }
    /// 仅记录接收、文件能力就绪、用户可见列表与任务状态事件推进；失败记录不再自动入队。
    private func enqueueOriginal(_ row: ClipboardRecord, pump: Bool = true) {
        guard row.content.kind == "image", row.content.sourceDeviceId != localID, row.available, row.cacheExpiresAt > milliseconds(),
              row.downloadState == "none", !originalQueue.contains(row.key), originalQueue.count < CLIPBOARD_HISTORY_LIMIT,
              active, !stopped, preferences.enabled, preferences.kinds.contains("image"),
              generation(row.content.sourceDeviceId) != nil, sessions[row.content.sourceDeviceId]?.capable == true else { return }
        originalQueue.append(row.key)
        if pump { pumpOriginals() }
    }
    private func pumpOriginals() {
        guard !stopped, active, !clearingPrivateImages, preferences.enabled, preferences.kinds.contains("image"), automaticRequest == nil,
              !originalQueue.isEmpty, !engine.automaticPrivateCacheBusy() else { return }
        // 队列最多一个自动请求在途；能力/普通文件忙碌时等真实状态事件，不用定时器重扫。
        while let index = originalQueue.firstIndex(where: { key in
            guard let separator = key.lastIndex(of: ":") else { return true }
            let source = String(key[..<separator])
            return fileCapabilities[source]?.0 == true && !tasks.contains { $0.peerId == source && !$0.state.terminal }
        }) {
            let key = originalQueue.remove(at: index)
            guard let separator = key.lastIndex(of: ":"), let row = try? database.find(source: String(key[..<separator]), id: String(key[key.index(after: separator)...])),
                  row.content.kind == "image", row.downloadState == "none", row.available, row.cacheExpiresAt > milliseconds(),
                  generation(row.content.sourceDeviceId) != nil, sessions[row.content.sourceDeviceId]?.capable == true else { continue }
            let used = ((try? database.snapshots()) ?? []).filter { $0.state == "ready" }.reduce(Int64(0)) { $0 + $1.byteSize } + engine.privateImageCacheBytes() + previews.cache.bytes
            guard row.content.size <= FILE_MAX_SIZE, row.content.size <= snapshots.maximum, used <= snapshots.maximum - row.content.size else {
                var denied = row; denied.downloadState = "failed"; denied.error = "原图未自动缓存：内部缓存空间不足，可清理历史或手动下载"; try? database.save(denied); changed(); continue
            }
            download(source: row.content.sourceDeviceId, id: row.content.recordId, privateOnly: true)
            if automaticRequest != nil { return }
        }
    }
    private func pumpImageExports() {
        guard !stopped, active, !clearingPrivateImages, !imageExporting, !exportAfter.isEmpty else { return }
        for key in exportAfter.sorted() {
            guard let separator = key.lastIndex(of: ":"), let row = try? database.find(source: String(key[..<separator]), id: String(key[key.index(after: separator)...])) else { exportAfter.remove(key); continue }
            if row.downloadState == "failed" { exportAfter.remove(key); continue }
            guard row.downloadState == "downloaded", let task = tasks.first(where: { localResourceTask($0, matches: row) }) else { continue }
            exportAfter.remove(key); imageExporting = true
            let cancellation = WorkCancellation(), context = uiEpoch
            imageExportCancellation = cancellation; imageExportSource = row.content.sourceDeviceId
            engine.exportClipboardImage(task, cancellation: cancellation) { [weak self] failure in self?.queue.async {
                guard let self else { return }; self.imageExporting = false; self.imageExportSource = nil
                if self.uiEpoch == context, !cancellation.isCancelled, !self.stopped { self.notice = failure ?? "原图已保存到 Downloads/续桥"; self.changed() }
                self.pumpImageExports()
            } }
            return
        }
    }
    func cancelPreviews(context: String) { guard context == uiEpoch else { return }; previews.invalidate() }
    private func removeRecordAndUnusedCache(_ row: ClipboardRecord) throws {
        try engine.deletingClipboardRecord(row) {
            if row.content.sourceDeviceId == localID, let index = try database.snapshot(id: row.content.recordId) { try snapshots.remove(index) }
            try previews.remove(row)
            try database.remove(source: row.content.sourceDeviceId, id: row.content.recordId, local: row.content.sourceDeviceId == localID)
        }
        originalQueue.removeAll { $0 == row.key }; exportAfter.remove(row.key)
        for session in sessions.values where session.inflight?.record == row.content.recordId { session.inflight = nil }
    }
    func deleteMany(keys: [String], context: String) -> ManagementResult {
        var result = ManagementResult()
        guard context == uiEpoch, keys.count <= CLIPBOARD_HISTORY_LIMIT else { result.failed = keys.count; return result }
        let selected = Set(keys), rows = ((try? database.records()) ?? []).filter { selected.contains($0.key) }
        result.failed = selected.count - rows.count
        for row in rows {
            guard !copying, !["requesting","downloading"].contains(row.downloadState), snapshots.leases[row.content.recordId,default:0] == 0, !hasActiveTask(row) else { result.keptActive += 1; continue }
            do {
                try removeRecordAndUnusedCache(row)
                result.removed += 1
            } catch let failure as FileFailure where failure.code == "FILE_BUSY" { result.keptActive += 1 }
            catch { result.failed += 1 }
        }
        result.failed += engine.cleanHiddenHistoryCache()
        notice = "已清理\(result.removed)条，保留活动\(result.keptActive)条，失败\(result.failed)项；用户保存的文件保留"
        pumpAll(); changed(); return result
    }
    /// 仅由用户确认后的管理入口调用，保留记录、小图和公共导出；跳过唯一原件及其他使用者。
    func clearPrivateImages(context: String, completion: @escaping (ManagementResult) -> Void) {
        guard context == uiEpoch, !stopped, !clearingPrivateImages else {
            notice = "页面已变化或已有原图清理任务，请重试"; changed(); completion(ManagementResult(failed: 1)); return
        }
        do {
            let rows = try database.records().filter { $0.content.kind == "image" }
            clearingPrivateImages = true; privateImageCleanupCancellation = WorkCancellation()
            clearNextPrivateImage(rows, index: 0, context: context, result: ManagementResult(), completion: completion)
        } catch { notice = "无法读取原图索引，未执行清理"; changed(); completion(ManagementResult(failed: 1)) }
    }
    private func finishPrivateImageCleanup(_ result: ManagementResult, completion: (ManagementResult) -> Void) {
        clearingPrivateImages = false
        notice = "已清理\(result.removed)项内部原图，跳过活动、其他引用或不可重取且未导出的原图\(result.keptActive)项，失败\(result.failed)项；记录、缩图和公共成品保留"
        pumpAll(); pumpBatch(); pumpOriginals(); pumpImageExports(); changed(); completion(result)
    }
    private func privateImageInUse(_ row: ClipboardRecord) -> Bool {
        copying || hasActiveTask(row) || previews.isBusy(row) || snapshots.leases[row.content.recordId, default: 0] > 0 ||
            ["requesting", "downloading"].contains(row.downloadState) || originalQueue.contains(row.key) || exportAfter.contains(row.key) ||
            imageExportSource == row.content.sourceDeviceId || copyAfter.contains(row.key)
    }
    private func clearNextPrivateImage(_ rows: [ClipboardRecord], index: Int, context: String, result: ManagementResult, completion: @escaping (ManagementResult) -> Void) {
        guard context == uiEpoch, !stopped else {
            var cancelled = result; cancelled.keptActive += rows.count - index
            finishPrivateImageCleanup(cancelled, completion: completion); return
        }
        guard index < rows.count else { finishPrivateImageCleanup(result, completion: completion); return }
        let row = rows[index]
        if privateImageInUse(row) {
            var skipped = result; skipped.keptActive += 1
            // 逐项异步让出服务队列，长历史不能阻塞心跳或授权撤销。
            queue.async { self.clearNextPrivateImage(rows, index: index + 1, context: context, result: skipped, completion: completion) }; return
        }
        engine.independentImageExportExists(row) { [weak self] exported in self?.queue.async {
            guard let self else { return }
            var outcome = result
            guard context == self.uiEpoch, !self.stopped, let current = try? self.database.find(source: row.content.sourceDeviceId, id: row.content.recordId), current.content.same(row.content), !self.privateImageInUse(current) else {
                outcome.keptActive += 1
                self.clearNextPrivateImage(rows, index: index + 1, context: context, result: outcome, completion: completion); return
            }
            if current.content.sourceDeviceId == self.localID, var snapshot = try? self.database.snapshot(id: current.content.recordId), snapshot.state == "ready" {
                // 本机快照不可向对端重新索取；没有仍有效的独立导出就保留，不能凭“曾发送”推断可重取。
                if exported {
                    do {
                        try self.snapshots.remove(snapshot); snapshot.state = "cleared"
                        var revised = current; revised.available = false; revised.availabilityVersion += 1
                        try self.database.transaction {
                            try self.database.saveSnapshot(snapshot); try self.database.save(revised)
                            try self.database.run("UPDATE clipboard_deliveries SET liveEpoch='' WHERE recordId=?", [current.content.recordId])
                        }
                        for session in self.sessions.values where session.inflight?.record == current.content.recordId { session.inflight = nil }
                        outcome.removed += 1
                    } catch { outcome.failed += 1 }
                } else { outcome.keptActive += 1 }
            }
            let source = current.content.sourceDeviceId
            let online = self.sessions[source]
            let refetchControl = source != self.localID && current.available && current.cacheExpiresAt > milliseconds() && self.generation(source) != nil && online?.capable == true ? online?.channel : nil
            // 信任不等于在线可重取：绑定此刻已认证通道，IO等待后由文件队列复核同一通道及信任代际。
            let accumulated = outcome
            self.engine.clearClipboardPrivateImage(current, refetchControl: refetchControl, cancellation: self.privateImageCleanupCancellation) { partial in self.queue.async {
                var combined = accumulated
                combined.removed += partial.removed; combined.keptActive += partial.keptActive; combined.failed += partial.failed
                if partial.removed > 0, var latest = try? self.database.find(source: current.content.sourceDeviceId, id: current.content.recordId) {
                    latest.downloadState = "failed"; latest.error = "内部原图已清理，可从原来源重新下载或打开已保存成品"
                    do { try self.database.save(latest) } catch { combined.failed += 1 }
                }
                self.clearNextPrivateImage(rows, index: index + 1, context: context, result: combined, completion: completion)
            } }
        } }
    }
    func clearCache(previews clearPreviews: Bool, sources: Bool, context: String) -> ManagementResult {
        var result = ManagementResult()
        guard context == uiEpoch else { result.failed = 1; return result }
        previews.invalidate()
        if clearPreviews { result = previews.cache.clear() }
        if sources {
            for var index in (try? database.snapshots()) ?? [] where index.state == "ready" {
                guard snapshots.leases[index.recordId,default:0] == 0 else { result.keptActive += 1; continue }
                do {
                    try snapshots.remove(index); index.state = "cleared"
                    try database.transaction {
                        try database.saveSnapshot(index)
                        if var row = try database.find(source: localID,id: index.recordId) {
                            row.available = false; row.availabilityVersion += 1; try database.save(row)
                            try database.run("UPDATE clipboard_deliveries SET liveEpoch='' WHERE recordId=?",[index.recordId])
                        }
                    }
                    for session in sessions.values where session.inflight?.record == index.recordId { session.inflight = nil }
                    result.removed += 1
                } catch { result.failed += 1 }
            }
            result.failed += engine.cleanHiddenHistoryCache()
        }
        notice = "已清理\(result.removed)项缓存，保留活动\(result.keptActive)项，失败\(result.failed)项"
        pumpAll(); changed(); return result
    }
    private func sweep(required: Int64 = 0) throws {
        var cacheChanged = false
        // 清理途中抛错也可能已经删除快照，不能依赖tick兜底发布。
        defer { if cacheChanged { pumpAll(); changed() } }
        let indices = try database.snapshots(), now = milliseconds()
        var ready = indices.filter { $0.state == "ready" }, used = ready.reduce(Int64(0)) { $0 + $1.byteSize }
        for index in ready {
            guard snapshots.leases[index.recordId, default: 0] == 0 else { continue }
            var info = stat(), missing = false
            let path: URL
            do { path = try snapshots.checked(index) }
            catch let failure as ClipboardFailure where failure.code == "CLIP_EXPIRED" { path = snapshots.path(index.recordId); missing = true }
            missing = missing || lstat(path.path, &info) != 0 || info.st_mode & S_IFMT != S_IFREG || info.st_size != index.byteSize
            let expired = index.expiresAt <= now, overQuota = required > snapshots.maximum || used > snapshots.maximum - required
            guard missing || expired || overQuota else { continue }
            cacheChanged = true
            if !missing { try snapshots.remove(index) }
            var revised = index; revised.state = missing ? "missing" : expired ? "expired" : "evicted"
            try database.transaction {
                try database.saveSnapshot(revised)
                if var row = try database.find(source: localID, id: index.recordId), row.available {
                    row.available = false; row.availabilityVersion = max(1, row.availabilityVersion); try database.save(row)
                    try database.run("UPDATE clipboard_deliveries SET liveEpoch='' WHERE recordId=?", [index.recordId])
                }
            }
            used -= index.byteSize
            for session in sessions.values where session.inflight?.record == index.recordId { session.inflight = nil }
        }
        ready.removeAll(); lastSweep = Date()
    }
    func tick() {
        guard !stopped else { return }
        var timedOut = false
        let previousNotice = notice
        defer { if timedOut || notice != previousNotice { changed() } }
        for (peer, session) in sessions {
            if let flight = session.inflight, Date().timeIntervalSince(flight.date) >= 10 {
                timedOut = true
                session.inflight = nil; session.retryAt = Date(); update(peer) { $0.send = "记录确认超时，保留原授权重试" }
                // 当前epoch的明确意图须跨瞬时错误/ACK超时保留；ACK、策略变化或断连才结束资格。
            }
        }
        for (_, pending) in pendingRequests where Date().timeIntervalSince(pending.2) > 30 { timedOut = true; invalidateRequests(pending.1) }
        if timedOut { refreshCaptureNotice() }
        if Date().timeIntervalSince(lastSweep) >= 60 { do { try sweep() } catch { notice = "缓存清理失败，未删除用户收件箱" } }
        if timedOut { pumpOriginals() }
        previews.tick()
        for (peer, session) in sessions where session.retryAt.map({ $0 <= Date() }) == true { pump(peer) }
        pumpBatch()
    }
    func views(_ ids: [String]) -> [ClipboardPeerView] {
        let grants = (try? database.grants()) ?? [], records = (try? database.records()) ?? []
        return ids.map { id in
            let setting = setting(id), session = sessions[id], saved = memory[id] ?? RecordPeerMemory()
            let pending = grants.contains { grant in grant.peerId == id && grant.trustGeneration == generation(id) && records.contains { $0.content.recordId == grant.recordId && $0.content.sourceDeviceId == localID && $0.availabilityVersion > grant.announcedVersion } }
            return ClipboardPeerView(id: id, context: uiEpoch, capable: session?.capable == true, autoSend: setting.autoSend, receiveEnabled: setting.receiveEnabled,
                effectiveReceive: session?.capable == true && effective(id), remoteAccept: session?.remoteAccept == true, lastSendStatus: saved.send, lastReceiveStatus: saved.receive,
                sentCount: saved.sent, receivedCount: saved.received, duplicateCount: saved.duplicates, inflight: session?.inflight != nil, hasPending: pending, preview: "", hasReceived: false)
        }
    }
    func recordViews() -> [ClipboardRecordView] { makeViews((try? database.records()) ?? []) }
    private func makeViews(_ rows: [ClipboardRecord]) -> [ClipboardRecordView] {
        rows.map { row in
            let item = row.content, task = tasks.first { $0.id == row.localTaskId }
            var view = ClipboardRecordView(key: row.key, recordId: item.recordId, sourceDeviceId: item.sourceDeviceId, sourceName: row.sourceName, capturedAt: item.capturedAt,
                receivedAt: row.receivedAt, kind: item.kind, name: item.name, size: item.size, sha256: item.sha256, available: row.available, availabilityVersion: row.availabilityVersion,
                cacheExpiresAt: row.cacheExpiresAt, downloadState: row.downloadState, taskId: row.localTaskId, originLocal: item.sourceDeviceId == localID,
                groupHash: item.groupHash, entryCount: item.entryCount, roots: item.roots, totalBytes: item.totalBytes, imageWidth: item.imageWidth, imageHeight: item.imageHeight,
                sourceOnline: item.sourceDeviceId == localID || sessions[item.sourceDeviceId]?.capable == true, preview: String((item.text ?? "").prefix(160)), error: row.error,
                context: uiEpoch, progress: task.map { $0.size == 0 ? ($0.state == .completed ? 1 : 0) : Double($0.progress) / Double($0.size) } ?? 0)
            view.privateOriginal = task?.clipboardPrivateOnly == true && row.downloadState == "downloaded"
            view.previewURL = previews?.url(row); view.previewState = previews?.state(row) ?? "none"; return view
        }
    }
    func cacheView() -> ClipboardCacheView {
        let values = (try? database.snapshots()) ?? []
        var result = ClipboardCacheView(); result.ttlSeconds = snapshots.ttl; result.maxBytes = snapshots.maximum
        result.bytes = values.filter { $0.state == "ready" }.reduce(0) { $0 + $1.byteSize }; result.snapshotCount = values.filter { $0.state == "ready" }.count
        result.expiredCount = values.filter { $0.state != "ready" }.count; result.activeLeases = snapshots.leases.values.reduce(0,+); result.historyCount = (try? database.count(source: "", kind: "")) ?? 0
        result.privateImageBytes = engine.privateImageCacheBytes(); result.privateImageCount = tasks.filter { $0.clipboardPrivateOnly && $0.state == .completed && $0.privateCacheBytes > 0 }.count
        result.previewBytes = previews.cache.bytes; result.previewCount = previews.cache.indices.count
        return result
    }
    #if DEBUG
    func debugWrite(_ text: String) { guard !stopped, clipboardBytes(text) != nil else { return }; adapter.write(text, permit: sourcePermit, markOwn: false) { _ in } }
    func debugPaths(peer: String, paths: [String]) {
        guard let gen = generation(peer), (1...GROUP_MAX_ROOTS).contains(paths.count), paths.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) else { return }
        capture(.paths(paths.map { URL(fileURLWithPath: $0) }), targets: [CaptureTarget(peer: peer, generation: gen, manual: true, epoch: sessions[peer]?.remoteEpoch ?? "", connection: sessions[peer]?.channel, awaitingHello: sessions[peer]?.capable == false)], automatic: false)
    }
    func debugSweep() { do { try sweep(); changed() } catch { notice = "缓存清理失败"; changed() } }
    #endif
}
