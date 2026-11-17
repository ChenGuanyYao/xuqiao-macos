import Foundation

struct ClipboardPreviewPeer {
    var channel: UUID
    var generation: String
    var capable: Bool
}
private struct PreviewRequest {
    var id: String, key: String, source: String, record: String, sha: String, trust: String
    var channel: UUID
    var sent: Date
    var retry: Int
}
private struct PreviewQueued { var key: String, retry: Int, ready: Date }

/// 小图只走认证控制通道，拥有独立的请求代际、背压及缓存；不创建FileTask或原件下载请求。
final class ClipboardPreviewCoordinator {
    private let database: ClipboardRecordStore
    private let snapshots: ClipboardSnapshotStore
    private let engine: FileTransferEngine
    private let localID: String
    private let queue: DispatchQueue
    private let io = DispatchQueue(label: "com.chenguangyao.xuqiao.previews", qos: .utility)
    let cache: ClipboardPreviewStore
    private let peer: (String) -> ClipboardPreviewPeer?
    private let allowed: () -> Bool
    private let send: (UUID,[String: Any]) -> Void
    private let changed: () -> Void
    private var pending: [String: PreviewRequest] = [:]
    private var queued: [PreviewQueued] = []
    private var localJobs: [String: UUID] = [:]
    private var localWork = Set<UUID>()
    private var localWorkKeys: [UUID: String] = [:]
    private var states: [String: String] = [:]
    private var epoch = UUID()
    private var context = ""
    private var serving = 0
    init(database: ClipboardRecordStore, snapshots: ClipboardSnapshotStore, engine: FileTransferEngine, localID: String,
         queue: DispatchQueue, peer: @escaping (String) -> ClipboardPreviewPeer?, allowed: @escaping () -> Bool,
         send: @escaping (UUID,[String: Any]) -> Void, changed: @escaping () -> Void) throws {
        self.database = database; self.snapshots = snapshots; self.engine = engine; self.localID = localID; self.queue = queue
        self.peer = peer; self.allowed = allowed; self.send = send; self.changed = changed
        cache = try ClipboardPreviewStore(database: database, root: snapshots.storage.root)
    }
    func url(_ row: ClipboardRecord) -> URL? { cache.url(row) }
    func state(_ row: ClipboardRecord) -> String { cache.url(row) != nil ? "ready" : states[row.key] ?? "none" }
    func invalidate() {
        let hadState = !states.isEmpty
        epoch = UUID(); pending.removeAll(); queued.removeAll(); localJobs.removeAll(); states.removeAll(); context = ""
        if hadState { changed() }
    }
    /// 连接变化只撤销此来源，其他设备的预览请求及生成许可继续有效。
    func invalidate(peer source: String) {
        let prefix = source + ":"
        pending = pending.filter { $0.value.source != source }
        queued.removeAll { $0.key.hasPrefix(prefix) }
        localJobs = localJobs.filter { !$0.key.hasPrefix(prefix) }
        states = states.filter { !$0.key.hasPrefix(prefix) }
    }
    func isBusy(_ row: ClipboardRecord) -> Bool { localWorkKeys.values.contains(row.key) }
    func remove(_ row: ClipboardRecord) throws {
        pending = pending.filter { $0.value.key != row.key }; queued.removeAll { $0.key == row.key }; localJobs.removeValue(forKey: row.key); states.removeValue(forKey: row.key)
        try cache.remove(source: row.content.sourceDeviceId, id: row.content.recordId)
    }
    func request(keys: [String], context: String) {
        guard allowed() else { return }
        let previousStates = states
        // 背压可能让新请求暂留队列，仍需显示loading；没有新状态则不刷新。
        defer { if states != previousStates { changed() } }
        if self.context != context { invalidate(); self.context = context }
        let active = Set(pending.values.map(\.key) + queued.map(\.key) + Array(localJobs.keys))
        let requested = Array(Set(keys)).prefix(50).filter { !active.contains($0) && states[$0] == nil }
        guard !requested.isEmpty else { pump(); return }
        let selected = Set(requested)
        // 命中小图会更新 LRU 索引并使 DB 记录缓存失效；同队列本轮只冻结一次已校验记录，
        // 避免逐图 find() 把整份历史重复解析。touch 不修改记录或信任，异步完成仍重新核验。
        let rows = Dictionary(((try? database.records()) ?? []).filter { selected.contains($0.key) }.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for key in requested {
            guard let row = rows[key], row.content.kind == "image" else { continue }
            if cache.url(row) != nil { cache.touch(row); continue }
            guard queued.count + pending.count + localJobs.count < 50 else { break }
            states[key] = "loading"; queued.append(PreviewQueued(key: key, retry: 0, ready: Date()))
        }
        pump()
    }
    private func find(_ key: String) -> ClipboardRecord? { ((try? database.records()) ?? []).first { $0.key == key } }
    private func pump() {
        guard allowed() else { invalidate(); return }
        var advanced = false
        // 只在真实消费队列时通知，空队列或等待重试/并发额度时保持安静。
        defer { if advanced { changed() } }
        while pending.count + localWork.count < 2, let index = queued.firstIndex(where: { $0.ready <= Date() }) {
            advanced = true
            let item = queued.remove(at: index)
            guard let row = find(item.key), row.content.kind == "image" else { states[item.key] = "failed"; continue }
            if cache.url(row) != nil { states.removeValue(forKey: row.key); continue }
            // 已有完整原件仅从校验完成的私有成品生成，绝不为预览发起下载。
            if row.content.sourceDeviceId == localID || row.downloadState == "downloaded" { makeLocal(row, retry: item.retry); continue }
            guard let remote = peer(row.content.sourceDeviceId) else { states[row.key] = "offline"; continue }
            guard remote.capable else { states[row.key] = "unsupported"; continue }
            guard let request = (try? secureBytes(16)).map(hex) else { states[row.key] = "failed"; continue }
            pending[request] = PreviewRequest(id: request, key: row.key, source: row.content.sourceDeviceId, record: row.content.recordId,
                sha: row.content.sha256, trust: remote.generation, channel: remote.channel, sent: Date(), retry: item.retry)
            send(remote.channel, wire("clip.preview.request", ["requestId": request,"recordId": row.content.recordId,"sha256": row.content.sha256]))
        }
    }
    private func makeLocal(_ row: ClipboardRecord, retry: Int) {
        let token = UUID(), captured = epoch; localJobs[row.key] = token; localWork.insert(token); localWorkKeys[token] = row.key
        if row.content.sourceDeviceId == localID, row.available,
           let index = try? database.snapshots().first(where: { $0.recordId == row.content.recordId && $0.state == "ready" && $0.expiresAt > milliseconds() }),
           let url = try? snapshots.checked(index) {
            snapshots.acquire(row.content.recordId)
            generate(row, url: url, token: token, epoch: captured, lease: row.content.recordId); return
        }
        guard !row.localTaskId.isEmpty else { localWork.remove(token); localWorkKeys.removeValue(forKey: token); localJobs.removeValue(forKey: row.key); states[row.key] = row.available ? "failed" : "expired"; return }
        // attempt由文件引擎核对，调用专用已完成剪贴板原件定位接口。
        engine.clipboardPreviewURL(taskID: row.localTaskId) { [weak self] url in self?.queue.async {
            guard let self else { return }
            guard self.epoch == captured, self.localJobs[row.key] == token else { self.localWork.remove(token); self.localWorkKeys.removeValue(forKey: token); self.pump(); return }
            guard let url else { self.localWork.remove(token); self.localWorkKeys.removeValue(forKey: token); self.localJobs.removeValue(forKey: row.key); self.states[row.key] = "failed"; self.pump(); self.changed(); return }
            self.generate(row, url: url, token: token, epoch: captured, lease: nil)
        } }
    }
    private func generate(_ row: ClipboardRecord, url: URL, token: UUID, epoch captured: UUID, lease: String?) {
        io.async {
            let result = Result { try ClipboardPreviewBytes.make(content: row.content, url: url) }
            self.queue.async {
                // 完成时即使队列已空，也要发布cache put、失败及租约释放；迟到结果仍受epoch约束。
                defer { self.pump(); self.changed() }
                if let lease { self.snapshots.release(lease) }; self.localWork.remove(token); self.localWorkKeys.removeValue(forKey: token)
                guard self.epoch == captured, self.localJobs[row.key] == token, self.allowed(), let current = self.find(row.key), current.content.sha256 == row.content.sha256 else { return }
                self.localJobs.removeValue(forKey: row.key)
                do { try self.cache.put(result.get(), row: current); self.states.removeValue(forKey: row.key) }
                catch { self.states[row.key] = "failed" }
            }
        }
    }
    func tick() {
        for request in Array(pending.values) where Date().timeIntervalSince(request.sent) >= 10 { finish(request, retryable: true) }
        pump()
    }
    private func finish(_ request: PreviewRequest, retryable: Bool) {
        pending.removeValue(forKey: request.id)
        if retryable && request.retry == 0, allowed(), peer(request.source)?.channel == request.channel {
            queued.append(PreviewQueued(key: request.key, retry: 1, ready: Date().addingTimeInterval(5))); states[request.key] = "loading"
        } else { states[request.key] = "failed" }
        changed()
    }
    func control(peer source: String, channel: UUID, message: [String: Any]) {
        guard let remote = peer(source), remote.channel == channel, remote.capable else { return }
        if message["type"] as? String == "clip.preview.request" { serve(source: source, remote: remote, message: message); return }
        guard let id = message["requestId"] as? String, let request = pending[id], request.source == source,
              request.channel == channel, request.trust == remote.generation, message["recordId"] as? String == request.record else { return }
        if message["type"] as? String == "clip.preview.error" {
            let code = message["code"] as? String ?? ""
            guard ["PREVIEW_NOT_FOUND","EXPIRED","BUSY","DISABLED","IO","INVALID"].contains(code) else { return }
            finish(request, retryable: ["BUSY","IO"].contains(code)); pump(); return
        }
        do {
            guard allowed(), message["sha256"] as? String == request.sha, message["mimeType"] as? String == "image/jpeg",
                  let sha = message["previewSha256"] as? String, let size = fileInteger(message["size"], maximum: 32_768), size > 0,
                  let width = fileInteger(message["width"], maximum: 320), let height = fileInteger(message["height"], maximum: 320),
                  let encoded = message["data"] as? String, encoded.utf8.count <= 43_692, let data = Data(base64Encoded: encoded),
                  data.base64EncodedString() == encoded, data.count == size, let row = find(request.key), row.content.sha256 == request.sha else { throw ClipboardFailure.invalid }
            let preview = try ClipboardPreviewBytes.validate(data, width: Int(width), height: Int(height), sha: sha)
            try cache.put(preview, row: row); pending.removeValue(forKey: id); states.removeValue(forKey: row.key)
            changed()
        } catch { finish(request, retryable: false) }
        pump()
    }
    private func serve(source: String, remote: ClipboardPreviewPeer, message: [String: Any]) {
        guard let request = message["requestId"] as? String, validHex(request, count: 32),
              let record = message["recordId"] as? String, validHex(record, count: 32),
              let sha = message["sha256"] as? String, validHex(sha) else { return }
        func fail(_ code: String) { send(remote.channel, wire("clip.preview.error", ["requestId":request,"recordId":record,"code":code])) }
        guard allowed() else { fail("DISABLED"); return }
        guard let row = try? database.find(source: localID, id: record), row.content.kind == "image", row.content.sha256 == sha,
              ((try? database.grants()) ?? []).contains(where: { $0.recordId == record && $0.peerId == source && $0.trustGeneration == remote.generation }) else { fail("PREVIEW_NOT_FOUND"); return }
        if let cached = cache.cached(row) { respond(cached, row: row, request: request, channel: remote.channel); return }
        guard serving < 2 else { fail("BUSY"); return }
        guard row.available, let index = try? database.snapshots().first(where: { $0.recordId == record && $0.state == "ready" && $0.expiresAt > milliseconds() }),
              let url = try? snapshots.checked(index) else { fail("EXPIRED"); return }
        snapshots.acquire(record); serving += 1; let captured = epoch; changed()
        io.async {
            let result = Result { try ClipboardPreviewBytes.make(content: row.content, url: url) }
            self.queue.async {
                defer { self.changed() }
                self.snapshots.release(record); self.serving = max(0,self.serving - 1)
                guard self.epoch == captured, self.allowed(), let latest = self.peer(source), latest.channel == remote.channel, latest.generation == remote.generation,
                      let current = try? self.database.find(source: self.localID, id: record), current.content.sha256 == sha,
                      ((try? self.database.grants()) ?? []).contains(where: { $0.recordId == record && $0.peerId == source && $0.trustGeneration == remote.generation }) else { return }
                do { let preview = try result.get(); try self.cache.put(preview, row: current); self.respond(preview, row: current, request: request, channel: remote.channel) }
                catch { fail("IO") }
            }
        }
    }
    private func respond(_ preview: ClipboardPreviewBytes, row: ClipboardRecord, request: String, channel: UUID) {
        send(channel, wire("clip.preview", ["requestId":request,"recordId":row.content.recordId,"sha256":row.content.sha256,"previewSha256":preview.sha,
            "mimeType":"image/jpeg","width":preview.width,"height":preview.height,"size":preview.data.count,"data":preview.data.base64EncodedString()]))
    }
}
