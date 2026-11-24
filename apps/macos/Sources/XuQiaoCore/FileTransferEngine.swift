import Foundation
import Darwin

private let FILE_RECEIPT_CHECK_LIMIT = 4

private struct PendingFileExport {
    let selections: [FileTaskSelection]
    let parent: URL
    let cancellation: WorkCancellation?
    let mediaAuthorization: MediaBinding?
    let completion: () -> Void
}
private struct FilePeerSession { let control: UUID; let groupCapable: Bool; let limits: FileConcurrencyLimits }
private final class FileDataJob {
    let channel: UUID
    let control: UUID
    let taskId: String
    let attempt: String
    var incoming: IncomingFileStream?
    var outgoing: OutgoingFileStream?
    var expectedAck: Int64?
    var ended = false
    var verificationCancellation: WorkCancellation?
    var deadline = Date().addingTimeInterval(30)
    init(channel: UUID, control: UUID, task: FileTask) {
        self.channel = channel; self.control = control; taskId = task.id; attempt = task.attemptId
    }
}

/// 控制心跳在 PairingServer 队列，文件状态/SQLite/分块写入在本队列，长复制/完整哈希另用 IO 队列。
final class FileTransferEngine {
    private let queue = DispatchQueue(label: "com.chenguangyao.xuqiao.files")
    private let io = DispatchQueue(label: "com.chenguangyao.xuqiao.files.io", qos: .utility)
    private let preparationIO = DispatchQueue(label: "com.chenguangyao.xuqiao.files.prepare", qos: .userInitiated)
    private let clipboardPreparationIO = DispatchQueue(label: "com.chenguangyao.xuqiao.files.clipboard", qos: .utility)
    private let storage: FileStorage
    private let database: FileTaskStore
    private let clipboardRecords: ClipboardRecordStore
    private var clipboardTrust: [String: String] = [:]
    private var mediaRequests: [String:(MediaBinding,UUID,String,Int64)] = [:]
    private var clipboardRequests: [String: (ClipboardBinding, UUID)] = [:]
    private var tasks: [String: FileTask] = [:]
    private var hiddenHistory = Set<String>()
    private var privateCacheSizes: [String: Int64] = [:]
    private var clearedPrivateImages = Set<String>()
    private var singleExports = Set<String>()
    private let automaticSavingEnabled: Bool
    private var receiveFolder: ReceiveFolderLocation?
    private var receivedSaveQueue: [String] = []
    private var receivedSaveRunning = false
    private var exportingIDs = Set<String>()
    private var sessions: [String: FilePeerSession] = [:]
    private var jobs: [UUID: FileDataJob] = [:]
    private var deadlines: [String: Date] = [:]
    private var preparing: [String: String] = [:]
    private var clipboardPreparing: [String: String] = [:]
    private var pendingScheduling = Set<String>()
    private var busyRetryCounts: [String: Int] = [:]
    private var busyRetryWork: [String: DispatchWorkItem] = [:]
    private let busyRetryDelays: [TimeInterval]
    private var preparationTokens: [String: WorkCancellation] = [:]
    private var exportView: BatchExportView?
    private var exportCancellation: WorkCancellation?
    private var pendingExports: [PendingFileExport] = []
    private var queuedExportIDs = Set<String>()
    private var checking = Set<String>()
    private var commitRecoveryAttempts: [String: Int] = [:]
    private var commitRecoveryAt: [String: Date] = [:]
    private var savedProgress: [String: (Int64, Date)] = [:]
    private var lastEmission = Date.distantPast
    private var noticeRevision: UInt64 = 0
    private var notice: String? { didSet { noticeRevision &+= 1 } }
    private let configuration: ServerConfiguration
    private let send: (UUID, [String: Any], Bool) -> Void
    private let closeChannel: (UUID) -> Void
    private let resumeRead: (UUID) -> Void
    private let changed: (FileTransferSnapshot) -> Void

    init(configuration: ServerConfiguration, send: @escaping (UUID, [String: Any], Bool) -> Void,
         close: @escaping (UUID) -> Void, resume: @escaping (UUID) -> Void,
         changed: @escaping (FileTransferSnapshot) -> Void,
         busyRetryDelays: [TimeInterval] = [2, 4, 8, 16, 30], receiveFolder: ReceiveFolderLocation? = nil) throws {
        self.busyRetryDelays = busyRetryDelays
        automaticSavingEnabled = configuration.fileStoreDirectory == nil || receiveFolder != nil
        self.receiveFolder = receiveFolder ?? (configuration.fileStoreDirectory == nil ? try? ReceiveFolderLocation.load() : nil)
        self.configuration = configuration; self.send = send; closeChannel = close; resumeRead = resume; self.changed = changed
        storage = try FileStorage(directory: configuration.fileStoreDirectory)
        database = try FileTaskStore(url: storage.root.appendingPathComponent("tasks.sqlite3"))
        clipboardRecords = try ClipboardRecordStore(root: storage.root)
        hiddenHistory = try database.hiddenIDs()
        clearedPrivateImages = try database.clearedPrivateImages()
        for var task in try database.all() {
            guard storage.validatePaths(task) else { throw FileFailure(code: "FILE_IO", message: "文件任务路径与私有收件箱不匹配") }
            if task.media != nil && !task.state.terminal && task.state != .committing {
                storage.cleanPartial(task);task.state = .failed;task.error = "相册授权已失效，请从相册重新下载";task.progress=0;try database.save(task)
            }
            if !task.state.terminal && task.state != .committing {
                if task.direction == .outgoing { task.state = .waitingConnection }
                else { storage.cleanPartial(task); task.state = .interrupted }
                task.progress = 0; task.updatedAt = Date(); try database.save(task)
            }
            if task.clipboard?.privateOnly == true, task.direction == .incoming {
                if task.state == .interrupted { task.state = .failed; task.error = "自动原图缓存已中断，可手动下载"; try database.save(task) }
                if task.state == .completed, let size = try? storage.final(task).resourceValues(forKeys: [.fileSizeKey]).fileSize { privateCacheSizes[task.id] = Int64(size) }
            }
            if task.direction == .incoming, task.state == .completed, task.group == nil, let binding = task.clipboard,
               (try clipboardRecords.find(source: binding.sourceDeviceId, id: binding.recordId))?.content.kind == "image" {
                var info = stat()
                if lstat(storage.final(task).path, &info) != 0 && errno == ENOENT {
                    // unlink之后、清理标记落库之前崩溃：启动在发布任何历史前按可靠任务路径补齐标记与记录。
                    try database.markPrivateImageCleared(task.id); clearedPrivateImages.insert(task.id)
                    if var row = try clipboardRecords.find(source: binding.sourceDeviceId, id: binding.recordId),row.localTaskId == task.id {
                        row.downloadState = "failed"; row.error = "内部原图已清理或丢失，可重新下载"
                        try clipboardRecords.save(row)
                    }
                }
            }
            // 复制途中崩溃可能已有部分公共文件，不能重启后静默再复制一遍。
            if var receipt = task.receivedSave, receipt.state == .saving {
                receipt.state = .failed; receipt.error = "上次保存被中断，请检查接收文件夹后重试"
                task.receivedSave = receipt; try database.save(task)
            }
            tasks[task.id] = task
            if task.clipboard != nil && task.direction == .outgoing && task.state.terminal { storage.cleanSource(task) }
        }
        // 必须先完整读取任务库再回收，读取失败绝不能把恢复日志当成无引用。
        do { try storage.recoverOrphanStages(referencedIDs: Set(tasks.keys)) }
        catch { notice = "部分无引用发送副本无法清理，已保留任务与恢复日志" }
        queue.async { [weak self] in
            guard let self else { return }
            for task in self.tasks.values {
                if task.state == .committing { self.recover(task) }
                if task.state == .completed, task.direction == .incoming, task.clipboard?.privateOnly == true, !self.hiddenHistory.contains(task.id) {
                    self.hideHistory([FileTaskSelection(id: task.id, attemptId: task.attemptId)], completion: { _ in })
                }
            }
            for task in Array(self.tasks.values) where task.receivedSave?.state == .pending { self.queueReceivedSave(task) }
            self.emit()
        }
    }
    func registerMediaRequest(_ binding:MediaBinding,control:UUID,name:String,size:Int64,completion:@escaping(Bool)->Void) {
        queue.async {
            guard binding.valid, binding.controlId == control.uuidString,
                  self.sessions[binding.peerId]?.control == control,
                  self.ordinaryTaskCount(peer: binding.peerId) + self.mediaRequests.values.filter({ $0.0.peerId == binding.peerId }).count < FILE_PENDING_LIMIT else { completion(false); return }
            self.mediaRequests[binding.requestId] = (binding, control, name, size); completion(true)
        }
    }
    func cancelMediaRequest(_ request:String) { queue.async {self.mediaRequests.removeValue(forKey:request);for task in self.tasks.values where task.media?.requestId==request && !task.state.terminal && task.state != .committing {self.terminate(task,state:.cancelled,text:"共享内容下载请求已取消")}} }
    func cancelMediaRequests(peer:String,control:UUID) {queue.async {self.mediaRequests=self.mediaRequests.filter{$0.value.0.peerId != peer || $0.value.1 != control};for task in self.tasks.values where task.peerId==peer && task.media?.controlId==control.uuidString && !task.state.terminal && task.state != .committing {self.terminate(task,state:.cancelled,text:"共享内容已结束，请重新选择下载")}}}
    // ArkTS Wire会序列化未使用的空字符串字段；空值视为未绑定，非字符串仍必须拒绝。
    private func hasBindingField(_ message:[String:Any],_ key:String)->Bool {guard let value=message[key] else{return false};if let text=value as? String{return !text.isEmpty};return true}
    private func authorizeMediaOffer(peer:String,channel:UUID,taskID:String,message:[String:Any],name:String,size:Int64,group:GroupMetadata?)throws->MediaBinding? {
        let has=["mediaGrantId","mediaAssetId","mediaRequestId"].contains{hasBindingField(message,$0)}
        guard has else {guard tasks[taskID]?.media==nil else{throw FileFailure.io};return nil}
        guard group==nil,!hasBindingField(message,"clipboardRecordId"),!hasBindingField(message,"clipboardRequestId"),
              let grant=message["mediaGrantId"] as? String,validHex(grant,count:32),let asset=message["mediaAssetId"] as? String,validHex(asset,count:32),let request=message["mediaRequestId"] as? String,validHex(request,count:32),
              let intent=mediaRequests[request],intent.0.peerId==peer,intent.0.grantId==grant,intent.0.assetId==asset,intent.1==channel,intent.2==name,intent.3==size,clipboardTrust[peer]==intent.0.trustGeneration else {throw FileFailure(code:"FILE_INVALID",message:"共享内容下载授权无效")}
        return intent.0
    }
    func setClipboardTrust(peer: String, generation: String) {
        queue.async {
            self.clipboardTrust[peer] = generation
            for task in self.tasks.values where task.peerId == peer && task.clipboard != nil && task.clipboard?.trustGeneration != generation && task.state != .completed && task.state != .committing {
                if task.state == .interrupted {
                    var failed = task; failed.state = .failed; failed.error = "原剪贴板授权域已失效，请明确重新下载"; try? self.put(failed)
                } else { self.terminate(task, state: .failed, text: "原剪贴板授权域已失效，请明确重新下载") }
            }
        }
    }
    func registerClipboardRequest(_ binding: ClipboardBinding, control: UUID) {
        queue.async { self.clipboardRequests[binding.downloadRequestId] = (binding, control) }
    }
    func cancelClipboardRequest(_ request: String, cancelTask: Bool = false) {
        queue.async {
            self.clipboardRequests.removeValue(forKey: request)
            if cancelTask {
                for task in self.tasks.values where task.direction == .incoming && task.clipboard?.downloadRequestId == request && !task.state.terminal && task.state != .committing {
                    self.terminate(task, state: .cancelled, text: "用户取消下载")
                    if let channel = self.sessions[task.peerId]?.control { self.send(channel, fileMessage("file.cancel", task: task, extra: ["reason": "user"]), false) }
                }
            }
        }
    }
    private func authorizeClipboardOffer(peer: String, channel: UUID, taskID: String, message: [String: Any], name: String, size: Int64, hash: String, group: GroupMetadata?) throws -> ClipboardBinding? {
        let has = hasBindingField(message,"clipboardRecordId") || hasBindingField(message,"clipboardRequestId")
        guard has else {
            guard tasks[taskID]?.clipboard == nil else { throw ClipboardFailure.invalid }; return nil
        }
        guard let id = message["clipboardRecordId"] as? String, validHex(id, count: 32), let request = message["clipboardRequestId"] as? String, validHex(request, count: 32),
              let generation = clipboardTrust[peer], generation != "self",
              let record = try clipboardRecords.find(source: peer, id: id), record.content.matchesFile(name: name, size: size, sha: hash, group: group) else { throw ClipboardFailure.invalid }
        var binding = ClipboardBinding(sourceDeviceId: peer, recordId: id, downloadRequestId: request, trustGeneration: generation)
        // privateOnly来自本地已授权意图或持久task，绝不从对端字段推导。
        if let intent = clipboardRequests[request], intent.1 == channel {
            binding.privateOnly = intent.0.privateOnly
            if intent.0 == binding { return intent.0 }
        }
        binding.privateOnly = tasks[taskID]?.clipboard?.privateOnly
        // 已持久task的恢复授权与临时请求分开；仍严守原任务/来源/本地信任域和非终止状态。
        guard let task = tasks[taskID], task.direction == .incoming, task.peerId == peer, task.clipboard == binding,
              ![.cancelled, .failed, .rejected, .interrupted].contains(task.state) || (task.state == .interrupted && record.localTaskId == taskID && record.downloadState != "failed") else { throw ClipboardFailure.invalid }
        return binding
    }
    func prepareClipboardSend(peer: String, control: UUID, content: ClipboardContent, binding: ClipboardBinding, snapshot: URL, completion: @escaping (String?) -> Void) {
        queue.async {
            guard self.sessions[peer]?.control == control, self.clipboardTrust[peer] == binding.trustGeneration else { completion("CLIP_STALE"); return }
            if let old = self.tasks.values.first(where: { $0.peerId == peer && $0.direction == .outgoing && $0.clipboard?.recordId == content.recordId && [.queued, .waitingConnection, .waitingAcceptance].contains($0.state) }) {
                self.terminate(old, state: .cancelled, text: "新的明确下载请求替换了旧等待任务")
            }
            guard self.sessions[peer]?.control == control, self.clipboardTrust[peer] == binding.trustGeneration,
                  !self.tasks.values.contains(where: { $0.peerId == peer && $0.direction == .outgoing && $0.clipboard != nil && !$0.state.terminal }),
                  self.clipboardPreparing[peer] == nil else { completion("CLIP_BUSY"); return }
            let id = UUID().uuidString.lowercased(), cancellation = WorkCancellation()
            self.clipboardPreparing[peer] = id; self.preparationTokens[id] = cancellation; self.emit()
            self.clipboardPreparationIO.async {
                let result = Result { try self.storage.prepare(snapshot, id: id, cancellation: cancellation) }
                self.queue.async {
                    let currentPreparation = self.clipboardPreparing[peer] == id
                    if currentPreparation { self.clipboardPreparing.removeValue(forKey: peer) }; self.preparationTokens.removeValue(forKey: id)
                    guard currentPreparation, self.sessions[peer]?.control == control, self.clipboardTrust[peer] == binding.trustGeneration, !cancellation.isCancelled else {
                        self.clipboardPreparationIO.async { try? self.storage.removeUnpublishedStage(id) }; completion("CLIP_STALE"); return
                    }
                    do {
                        let prepared = try result.get(); guard prepared.size == content.size, prepared.hash == content.sha256 else { throw ClipboardFailure.invalid }
                        var task = FileTask(id: id, peerId: peer, direction: .outgoing, name: content.name, size: content.size, sha256: content.sha256,
                            sourcePath: self.storage.source(id).path, destinationPath: "", state: .queued, progress: 0, attemptId: UUID().uuidString.lowercased(), updatedAt: Date(), error: nil)
                        task.group = content.group; task.clipboard = binding
                        try self.put(task); completion(nil)
                    } catch { self.clipboardPreparationIO.async { try? self.storage.removeUnpublishedStage(id) }; completion("CLIP_IO") }
                }
            }
        }
    }
    func materializeClipboard(content: ClipboardContent, binding: ClipboardBinding, snapshot: URL, permit: ClipboardPermit, completion: @escaping (String?) -> Void) {
        queue.async {
            guard binding.trustGeneration == "self", binding.sourceDeviceId == content.sourceDeviceId,
                  self.clipboardPreparing[content.sourceDeviceId] == nil, !self.tasks.values.contains(where: { $0.peerId == content.sourceDeviceId && $0.clipboard != nil && !$0.state.terminal }) else { completion("CLIP_BUSY"); return }
            let id = UUID().uuidString.lowercased(), cancellation = WorkCancellation()
            var task = FileTask(id: id, peerId: content.sourceDeviceId, direction: .incoming, name: content.name, size: content.size, sha256: content.sha256,
                sourcePath: "", destinationPath: "", state: .verifying, progress: 0, attemptId: UUID().uuidString.lowercased(), updatedAt: Date(), error: nil)
            task.clipboard = binding; task.group = content.group; task.destinationPath = self.storage.final(task).path
            // 主线程/协调器可在排队期间撤销self intent；持久task前与取消原子核对。
            let admitted = permit.perform { () -> Bool in
                do { try self.put(task); return true } catch { return false }
            }
            guard admitted == true else { completion(admitted == nil ? "CLIP_STALE" : "CLIP_IO"); return }
            self.clipboardPreparing[content.sourceDeviceId] = id; self.preparationTokens[id] = cancellation
            let captured = task
            self.clipboardPreparationIO.async {
                let result = Result { () throws -> GroupMetadata? in
                    try self.storage.ensureReceived(captured); self.storage.cleanPartial(captured)
                    let input = try openRegular(snapshot); defer { close(input) }
                    let output = try IncomingFileStream(url: self.storage.partial(captured)); var count: Int64 = 0
                    while true {
                        try cancellation.check(); let bytes = try readBlock(input, limit: 65_536); if bytes.isEmpty { break }
                        count += Int64(bytes.count); guard count <= captured.size else { throw ClipboardFailure.invalid }; try output.append(bytes)
                    }
                    guard count == captured.size, try output.finish() == captured.sha256 else { throw ClipboardFailure.invalid }
                    try self.validateClipboardPayload(captured, at: self.storage.partial(captured))
                    if captured.group != nil {
                        let group = try self.storage.extractGroup(captured, archive: self.storage.partial(captured), cancellation: cancellation)
                        try self.validateClipboardGroup(captured, group: group); return group
                    }
                    return nil
                }
                self.queue.async {
                    if self.clipboardPreparing[content.sourceDeviceId] == id { self.clipboardPreparing.removeValue(forKey: content.sourceDeviceId) }; self.preparationTokens.removeValue(forKey: id)
                    guard var current = self.tasks[id], current.state == .verifying, !cancellation.isCancelled else { self.storage.cleanPartial(captured); completion("CLIP_STALE"); return }
                    do {
                        current.group = try result.get(); current.state = .committing; try self.put(current)
                    } catch { self.fail(current, failure: .io); completion("CLIP_IO"); return }
                    let committing = current
                    self.clipboardPreparationIO.async {
                        let result = Result { if committing.group != nil { try self.storage.commitGroup(committing) } else { try self.storage.commit(committing) } }
                        self.queue.async {
                            do {
                                try result.get(); var completed = committing; completed.state = .completed; completed.progress = completed.size; completed.error = nil
                                try self.put(completed); completion(nil)
                            } catch { self.fail(committing, failure: .io); completion("CLIP_IO") }
                        }
                    }
                }
            }
        }
    }
    private func validateClipboardPayload(_ task: FileTask, at url: URL) throws {
        guard let binding = task.clipboard else { return }
        guard let record = try clipboardRecords.find(source: binding.sourceDeviceId, id: binding.recordId), record.content.matchesFile(name: task.name, size: task.size, sha: task.sha256, group: task.group) else { throw ClipboardFailure.invalid }
        try ClipboardImage.validate(record.content, at: url)
    }
    private func validateClipboardGroup(_ task: FileTask, group: GroupMetadata) throws {
        guard let binding = task.clipboard, let record = try clipboardRecords.find(source: binding.sourceDeviceId, id: binding.recordId) else { return }
        if record.content.kind == "folder" {
            guard group.roots.count == 1, group.entries.contains(where: { $0.isDirectory && $0.path == group.roots[0] + "/" }) else { throw ClipboardFailure.invalid }
        }
    }
    func clipboardCopyURLs(taskID: String, expectedAttempt: String, completion: @escaping ([URL]?) -> Void) {
        queue.async {
            guard let task = self.tasks[taskID], task.attemptId == expectedAttempt, task.direction == .incoming, task.state == .completed, !self.clearedPrivateImages.contains(task.id), !self.checking.contains(task.id) else { completion(nil); return }
            self.io.async {
                do {
                    guard try self.storage.groupReceiptOrFileMatches(task) else { completion(nil); return }
                    try self.validateClipboardPayload(task, at: self.storage.final(task))
                    completion(task.group.map { group in group.roots.map { self.storage.groupTree(task).appendingPathComponent($0) } } ?? [self.storage.final(task)])
                } catch { completion(nil) }
            }
        }
    }
    func prepareSend(peer: String, source: URL, completion: @escaping (String?) -> Void) {
        prepareSources(peer: peer, sources: [source], singleOnly: true, completion: completion)
    }
    func prepareMany(peer: String, sources: [URL], completion: @escaping (String?) -> Void) {
        prepareSources(peer: peer, sources: sources, singleOnly: false, completion: completion)
    }
    private func prepareSources(peer: String, sources: [URL], singleOnly: Bool, completion: @escaping (String?) -> Void) {
        queue.async {
            guard self.preparing[peer] == nil, self.ordinaryTaskCount(peer: peer) < FILE_PENDING_LIMIT else {
                self.notice = "FILE_BUSY：正在准备本次发送，或该设备普通任务已达50项"; self.emit(); completion(self.notice); return
            }
            let id = UUID().uuidString.lowercased(), cancellation = WorkCancellation()
            self.preparing[peer] = id; self.preparationTokens[id] = cancellation; self.notice = nil; self.emit()
            self.preparationIO.async {
                let result = Result { () throws -> (PreparedPayload, FileOfferImagePreview?) in
                    let payload: PreparedPayload
                    if singleOnly {
                        guard let source = sources.first else { throw groupInvalid("未选择文件") }
                        let file = try self.storage.prepare(source, id: id, cancellation: cancellation)
                        payload = PreparedPayload(name: file.name, size: file.size, sha256: file.hash, group: nil)
                    } else {
                        payload = try self.storage.prepareMany(sources, id: id, cancellation: cancellation)
                    }
                    let preview = payload.group == nil ? FileOfferImagePreview.make(name: payload.name, snapshot: self.storage.source(id), cancellation: cancellation) : nil
                    try cancellation.check()
                    return (payload, preview)
                }
                self.queue.async {
                    self.preparationTokens.removeValue(forKey: id)
                    guard self.preparing[peer] == id, !cancellation.isCancelled else {
                        try? self.storage.removeUnpublishedStage(id)
                        completion("准备已取消"); return
                    }
                    self.preparing.removeValue(forKey: peer)
                    self.schedulePending(peer: peer)
                    switch result {
                    case .success(let (data, preview)):
                        if data.group != nil, self.sessions[peer]?.groupCapable == false {
                            self.notice = "FILE_UNSUPPORTED：对端尚未协商文件组能力"
                            try? self.storage.removeUnpublishedStage(id)
                            self.emit(); completion(self.notice); return
                        }
                        var task = FileTask(id: id, peerId: peer, direction: .outgoing, name: data.name, size: data.size, sha256: data.sha256,
                                            sourcePath: self.storage.source(id).path, destinationPath: "", state: self.sessions[peer] == nil ? .waitingConnection : .queued,
                                            progress: 0, attemptId: UUID().uuidString.lowercased(), updatedAt: Date(), error: nil)
                        task.group = data.group; task.imagePreview = preview
                        do {
                            guard self.ordinaryTaskCount(peer: peer) < FILE_PENDING_LIMIT else { throw FileFailure(code: "FILE_BUSY", message: "该设备普通任务已达50项") }
                            try self.put(task); completion(nil)
                        }
                        catch {
                            // 首次put失败没有发布任务；只回收本次ID，不碰任何已持久任务副本。
                            try? self.storage.removeUnpublishedStage(id)
                            self.notice = self.explain(error); self.emit(); completion(self.notice)
                        }
                    case .failure(let error):
                        self.notice = error is WorkCancelled ? "准备已取消" : self.explain(error)
                        try? self.storage.removeUnpublishedStage(id)
                        self.emit(); completion(self.notice)
                    }
                }
            }
        }
    }
    func cancelPreparation(peer: String, expected: String) {
        queue.async {
            guard self.preparing[peer] == expected else { return }
            self.preparationTokens[expected]?.cancel(); self.preparing.removeValue(forKey: peer)
            self.notice = "正在取消准备…"; self.schedulePending(peer: peer); self.emit()
        }
    }
    func control(peer: String, channel: UUID, message: [String: Any], completion: @escaping () -> Void) {
        queue.async {
            defer { completion() }
            guard let type = message["type"] as? String else { return }
            if type == "file.hello" {
                guard message["protocol"] as? String == "xq-file/1" else {
                    self.error(channel, "FILE_UNSUPPORTED", "对端不支持此文件传输协议"); return
                }
                let newSession = self.sessions[peer]?.control != channel
                let groupCapable = message["groupProtocol"] as? String == "xq-group/1"
                let limits: FileConcurrencyLimits
                do { limits = try FileConcurrencyLimits(hello: message) }
                catch { self.error(channel, "FILE_INVALID", "文件并发能力无效"); return }
                self.sessions[peer] = FilePeerSession(control: channel, groupCapable: groupCapable, limits: limits)
                var hello: [String: Any] = ["protocol": "xq-file/1", "maxSize": FILE_MAX_SIZE, "chunkSize": FILE_CHUNK_SIZE, "maxConcurrentFiles": 3, "maxConcurrentClipboard": 1]
                if groupCapable { hello["groupProtocol"] = "xq-group/1"; hello["maxEntries"] = GROUP_MAX_ENTRIES; hello["maxRoots"] = GROUP_MAX_ROOTS }
                self.send(channel, wire("file.hello", hello), false)
                // 网络自动重试只在新控制认证+hello发生一次，旧会话不会因数据断流自旋重发。
                if newSession {
                    for var task in self.tasks.values where task.peerId == peer && task.direction == .outgoing && task.state == .waitingConnection {
                        task.state = .queued; try? self.put(task)
                    }
                }
                self.schedulePending(peer: peer); self.emit(); return
            }
            if type == "file.error", message["taskId"] == nil {
                if self.sessions[peer]?.control == channel {
                    self.sessions.removeValue(forKey: peer); self.cancelPeerPreparations(peer)
                    for task in self.tasks.values where task.peerId == peer && !task.state.terminal && task.state != .committing {
                        self.terminate(task, state: .failed, text: self.remoteError(message))
                    }
                }
                self.notice = self.remoteError(message); self.emit(); return
            }
            guard self.sessions[peer]?.control == channel else {
                self.error(channel, "FILE_UNSUPPORTED", "请先协商文件能力", message: message); return
            }
            guard let id = fileID(message["taskId"]), let attempt = fileID(message["attemptId"]) else {
                self.error(channel, "FILE_INVALID", "文件任务标识无效"); return
            }
            if type == "file.offer" { self.receiveOffer(peer: peer, channel: channel, id: id, attempt: attempt, message: message); return }
            guard let task = self.tasks[id], task.peerId == peer else {
                if type != "file.error" { self.error(channel, "FILE_NOT_FOUND", "文件任务不存在", message: message) }; return
            }
            if type == "file.cancel", task.direction == .incoming, task.state == .completed {
                self.receipt(task, attempt: attempt, control: channel, missing: { self.error(channel, "FILE_NOT_FOUND", "本地已保存文件不可用", message: message) }); return
            }
            guard task.attemptId == attempt else { return }
            switch type {
            case "file.accept":
                guard task.direction == .outgoing, task.state == .waitingAcceptance else { return }
                var accepted = task; accepted.state = .awaitingData
                do {
                    try self.put(accepted); self.deadlines[id] = Date().addingTimeInterval(15)
                    self.send(channel, fileMessage("file.accepted", task: accepted), false)
                } catch { self.fail(task, failure: .io) }
            case "file.reject":
                guard task.direction == .outgoing, task.state == .waitingAcceptance, message["reason"] as? String == "user" else { return }
                self.terminate(task, state: .rejected, text: "对方拒绝接收")
            case "file.cancel":
                guard message["reason"] as? String == "user", task.state != .committing, task.state != .completed else { return }
                self.terminate(task, state: .cancelled, text: "对方取消了传输")
            case "file.receipt":
                guard task.direction == .outgoing else { self.error(channel, "FILE_INVALID", "收据方向无效", message: message); return }
                self.completeSender(task, message: message)
            case "file.error":
                guard task.state != .completed, task.state != .committing else { return }
                if message["code"] as? String == "FILE_BUSY", task.direction == .outgoing, task.state == .queued { return }
                if message["code"] as? String == "FILE_BUSY", task.direction == .outgoing, task.state == .waitingAcceptance {
                    self.retryAfterBusy(task, control: channel)
                } else { self.terminate(task, state: .failed, text: self.remoteError(message)) }
            default:
                self.fail(task, failure: FileFailure(code: "FILE_INVALID", message: "文件消息不适用于当前控制通道"))
            }
        }
    }
    private func receiveOffer(peer: String, channel: UUID, id: String, attempt: String, message: [String: Any]) {
        guard let name = fileName(message["name"]), let size = fileInteger(message["size"]),
              let hash = message["sha256"] as? String, validHex(hash) else {
            error(channel, "FILE_INVALID", "文件名、大小或校验值无效", message: message); return
        }
        let group: GroupMetadata?
        do { group = try GroupMetadata.parse(message) }
        catch { let f = failure(error); self.error(channel, f.code, f.message, message: message); return }
        guard group == nil || sessions[peer]?.groupCapable == true else { error(channel, "FILE_UNSUPPORTED", "请先协商文件组能力", message: message); return }
        let mediaBinding: MediaBinding?
        do { mediaBinding = try authorizeMediaOffer(peer:peer,channel:channel,taskID:id,message:message,name:name,size:size,group:group) }
        catch { self.error(channel,"FILE_INVALID","共享内容下载授权或内容绑定无效",message:message);return }
        let clipBinding: ClipboardBinding?
        do { clipBinding = try authorizeClipboardOffer(peer: peer, channel: channel, taskID: id, message: message, name: name, size: size, hash: hash, group: group) }
        catch { self.error(channel, "FILE_INVALID", "剪贴板下载授权或内容绑定无效", message: message); return }
        let preview = group == nil && clipBinding == nil && mediaBinding == nil && FileOfferImagePreview.imageName(name)
            ? FileOfferImagePreview.parse(message["imagePreview"]) : nil
        if let existing = tasks[id] {
            let sameGroup = (existing.group == nil && group == nil) || (existing.group != nil && group != nil && existing.group!.sameSummary(group!))
            guard sameGroup, existing.peerId == peer, existing.direction == .incoming, existing.name.utf8.elementsEqual(name.utf8), existing.size == size, existing.sha256 == hash else {
                error(channel, "FILE_INVALID", "重复任务的文件信息不一致", message: message); return
            }
            if existing.state == .committing { error(channel, "FILE_BUSY", "文件正在可靠提交，请稍后再试", message: message); return }
            if existing.state == .completed {
                receipt(existing, attempt: attempt, control: channel) { [weak self] in
                    self?.makeIncoming(peer: peer, channel: channel, id: id, attempt: attempt, name: name, size: size, hash: hash, group: group, clipboard: clipBinding, media: mediaBinding, imagePreview: preview)
                }
                return
            }
        }
        makeIncoming(peer: peer, channel: channel, id: id, attempt: attempt, name: name, size: size, hash: hash, group: group, clipboard: clipBinding, media: mediaBinding, imagePreview: preview)
    }
    private func makeIncoming(peer: String, channel: UUID, id: String, attempt: String, name: String, size: Int64, hash: String, group: GroupMetadata?, clipboard: ClipboardBinding?, media:MediaBinding?, imagePreview: FileOfferImagePreview?) {
        guard sessions[peer]?.control == channel else { return }
        var task = FileTask(id: id, peerId: peer, direction: .incoming, name: name, size: size, sha256: hash,
                            sourcePath: "", destinationPath: "", state: .awaitingUser, progress: 0, attemptId: attempt, updatedAt: Date(), error: nil)
        task.group = group; task.clipboard = clipboard; task.media = media; task.imagePreview = imagePreview
        task.destinationPath = storage.final(task).path
        guard (clipboard != nil || ordinaryTaskCount(peer: peer, excluding: id) < FILE_PENDING_LIMIT),
              sessions[peer]?.limits.permits(task, among: Array(tasks.values)) == true else {
            error(channel, "FILE_BUSY", "该设备的传输通道已满，请排队重试", message: task.wireFields); return
        }
        if let old = tasks[id] { removeJob(old); storage.cleanPartial(old) }
        do {
            try put(task); deadlines[id] = Date().addingTimeInterval(120)
            if let media { mediaRequests.removeValue(forKey:media.requestId);acceptOnQueue(id,expectedAttempt:task.attemptId) }
            if let clipboard { clipboardRequests.removeValue(forKey: clipboard.downloadRequestId); acceptOnQueue(id, expectedAttempt: task.attemptId) }
            #if DEBUG
            if configuration.autoAcceptFiles { acceptOnQueue(id, expectedAttempt: task.attemptId) }
            #endif
        } catch { self.error(channel, "FILE_IO", "接收任务未能保存", message: task.wireFields) }
    }
    /// 用户操作绑定点击时的尝试；队列延迟或新offer替换后，旧页面不能操作新一代任务。
    func accept(_ id: String, expectedAttempt: String) { queue.async { self.acceptOnQueue(id, expectedAttempt: expectedAttempt) } }
    func respondToOffer(_ id: String, expectedAttempt: String, peer: String, control: UUID, accept: Bool) {
        queue.async {
            guard let task = self.tasks[id], task.peerId == peer, task.attemptId == expectedAttempt,
                  task.clipboard == nil, task.media == nil, self.sessions[peer]?.control == control else { return }
            if accept { self.acceptOnQueue(id, expectedAttempt: expectedAttempt) }
            else { self.rejectOnQueue(id, expectedAttempt: expectedAttempt) }
        }
    }
    private func acceptOnQueue(_ id: String, expectedAttempt: String) {
        guard var task = tasks[id], task.attemptId == expectedAttempt, task.direction == .incoming, task.state == .awaitingUser,
              let control = sessions[task.peerId]?.control else { return }
        do {
            try storage.ensureReceived(task); storage.cleanPartial(task)
            task.state = .awaitingData; try put(task); deadlines[id] = Date().addingTimeInterval(15)
            send(control, fileMessage("file.accept", task: task), false)
        } catch { fail(task, failure: .io) }
    }
    func reject(_ id: String, expectedAttempt: String) {
        queue.async { self.rejectOnQueue(id, expectedAttempt: expectedAttempt) }
    }
    private func rejectOnQueue(_ id: String, expectedAttempt: String) {
            guard let task = self.tasks[id], task.attemptId == expectedAttempt, task.state == .awaitingUser else { return }
            do {
                var rejected = task; rejected.state = .rejected; rejected.error = "已拒绝接收"; try self.put(rejected)
                if let control = self.sessions[task.peerId]?.control { self.send(control, fileMessage("file.reject", task: task, extra: ["reason": "user"]), false) }
                self.deadlines.removeValue(forKey: id); self.storage.cleanPartial(task)
            } catch { self.fail(task, failure: .io) }
    }
    func cancel(_ id: String, expectedAttempt: String) {
        queue.async {
            guard let task = self.tasks[id], task.attemptId == expectedAttempt, task.state != .committing, task.state != .completed, !task.state.terminal else { return }
            self.terminate(task, state: .cancelled, text: "已取消；已交付的文件不会删除")
            if let control = self.sessions[task.peerId]?.control { self.send(control, fileMessage("file.cancel", task: task, extra: ["reason": "user"]), false) }
        }
    }
    func retry(_ id: String, expectedAttempt: String) {
        queue.async {
            guard let task = self.tasks[id], task.attemptId == expectedAttempt else { return }
            if task.state == .committing {
                // 显式重试仅重新核对可靠提交，绝不取消或删除可能已rename的成品。
                guard !self.checking.contains(id) else { return }
                self.commitRecoveryAt.removeValue(forKey: id); self.commitRecoveryAttempts.removeValue(forKey: id)
                self.recover(task); return
            }
            guard task.direction == .outgoing,
                  [.failed, .rejected, .interrupted, .waitingConnection].contains(task.state),
                  self.ordinaryTaskCount(peer: task.peerId, excluding: id) < FILE_PENDING_LIMIT else { return }
            guard self.sessions[task.peerId] != nil else { self.notice = "请先连接设备并协商文件能力"; self.emit(); return }
            self.clearBusyRetry(id)
            var queued = task; queued.state = .queued; queued.error = nil
            do { try self.put(queued) } catch { self.fail(task, failure: .io) }
        }
    }
    private func offer(_ id: String) {
        guard var task = tasks[id], task.state == .queued, let session = sessions[task.peerId],
              session.limits.permits(task, among: Array(tasks.values)) else { return }
        let control = session.control
        // 旧对端仅一个共享槽，前台普通准备结束后再考虑后台剪贴板队列。
        guard task.clipboard == nil || !session.limits.legacy || preparing[task.peerId] == nil else { return }
        do {
            _ = try openSourceForProbe(task)
            guard task.group == nil || sessions[task.peerId]?.groupCapable == true else { throw FileFailure(code: "FILE_UNSUPPORTED", message: "对端尚未协商文件组能力") }
            task.attemptId = UUID().uuidString.lowercased(); task.progress = 0; task.state = .waitingAcceptance; task.error = nil
            removeJob(task); try put(task); deadlines[id] = Date().addingTimeInterval(120)
            var fields: [String: Any] = ["name": task.name, "size": task.size, "sha256": task.sha256]
            if let group = task.group { fields.merge(group.offerFields) { _, new in new } }
            if let clip = task.clipboard {
                guard clipboardTrust[task.peerId] == clip.trustGeneration else { throw FileFailure(code: "FILE_INVALID", message: "原剪贴板授权已失效") }
                if task.group == nil { fields["kind"] = "file" }
                fields["clipboardRecordId"] = clip.recordId; fields["clipboardRequestId"] = clip.downloadRequestId
            }
            if task.group == nil, task.clipboard == nil, task.media == nil, let preview = task.imagePreview {
                fields["imagePreview"] = preview.wireFields
                // 可选缩图绝不扩大现有帧上限，超限只移除缩图。
                let message = fileMessage("file.offer", task: task, extra: fields)
                if (try? JSONSerialization.data(withJSONObject: message).count).map({ $0 > 65_536 }) ?? true {
                    fields.removeValue(forKey: "imagePreview")
                }
            }
            send(control, fileMessage("file.offer", task: task, extra: fields), false)
        } catch { fail(task, failure: failure(error)) }
    }
    private func openSourceForProbe(_ task: FileTask) throws -> Bool {
        let stream = try OutgoingFileStream(url: storage.source(task.id), size: task.size)
        return stream.fd >= 0
    }
    func bind(peer: String, control: UUID, channel: UUID, server: String, id: String, attempt: String, direction: String) {
        queue.async {
            guard self.sessions[peer]?.control == control, let task = self.tasks[id], task.peerId == peer,
                  task.attemptId == attempt, task.wireDirection == direction, task.state == .awaitingData,
                  task.group == nil || self.sessions[peer]?.groupCapable == true,
                  !self.jobs.values.contains(where: { $0.taskId == id }) else {
                self.error(channel, "FILE_INVALID", "文件通道与当前已同意的任务不匹配", message: ["taskId": id, "attemptId": attempt], close: true); return
            }
            let job = FileDataJob(channel: channel, control: control, task: task)
            do {
                if task.direction == .incoming {
                    try self.storage.ensureReceived(task); self.storage.cleanPartial(task)
                    job.incoming = try IncomingFileStream(url: self.storage.partial(task))
                } else { job.outgoing = try OutgoingFileStream(url: self.storage.source(id), size: task.size) }
                self.jobs[channel] = job
                var active = task; active.state = .transferring; active.progress = 0; try self.put(active)
                self.deadlines.removeValue(forKey: id)
                self.send(channel, fileMessage("file.ready", task: active, extra: ["serverId": server]), false)
                if task.direction == .outgoing { try self.sendNext(job) }
                self.resumeRead(channel)
            } catch {
                self.fail(task, failure: self.failure(error))
                self.error(channel, self.failure(error).code, self.failure(error).message, message: task.wireFields, close: true)
            }
        }
    }
    func data(channel: UUID, message: [String: Any]) {
        queue.async {
            defer { self.resumeRead(channel) }
            guard let job = self.jobs[channel], let task = self.tasks[job.taskId], task.attemptId == job.attempt,
                  self.sessions[task.peerId]?.control == job.control else { self.closeChannel(channel); return }
            guard fileID(message["taskId"]) == task.id, fileID(message["attemptId"]) == task.attemptId else {
                self.fail(task, failure: FileFailure(code: "FILE_INVALID", message: "文件帧与当前任务不匹配")); return
            }
            do {
                switch message["type"] as? String {
                case "file.chunk":
                    guard task.direction == .incoming, !job.ended, let offset = fileInteger(message["offset"]), offset == task.progress,
                          let encoded = message["data"] as? String, encoded.utf8.count <= 21_848,
                          let bytes = Data(base64Encoded: encoded), (1...FILE_CHUNK_SIZE).contains(bytes.count), bytes.base64EncodedString() == encoded,
                          task.progress + Int64(bytes.count) <= task.size, let input = job.incoming else {
                        throw FileFailure(code: "FILE_INVALID", message: "文件分块顺序、编码或大小无效")
                    }
                    try input.append(bytes)
                    var revised = task; revised.progress += Int64(bytes.count); try self.progress(revised)
                    job.deadline = Date().addingTimeInterval(30)
                    self.send(channel, fileMessage("file.chunkAck", task: revised, extra: ["offset": revised.progress]), false)
                case "file.chunkAck":
                    guard task.direction == .outgoing, !job.ended, let offset = fileInteger(message["offset"]), let expected = job.expectedAck, offset == expected else {
                        throw FileFailure(code: "FILE_INVALID", message: "文件分块确认偏移无效")
                    }
                    job.expectedAck = nil; job.deadline = Date().addingTimeInterval(30)
                    var revised = task; revised.progress = offset; try self.progress(revised)
                    try self.sendNext(job)
                case "file.end":
                    guard task.direction == .incoming, !job.ended, task.progress == task.size, let input = job.incoming else {
                        throw FileFailure(code: "FILE_SIZE", message: "文件未完整接收")
                    }
                    job.ended = true
                    var verified = task; verified.state = .verifying; try self.put(verified)
                    let hash = try input.finish(); job.incoming = nil
                    guard hash == task.sha256 else { throw FileFailure(code: "FILE_HASH", message: "文件校验失败，未保存为完成文件") }
                    if verified.group != nil {
                        job.deadline = Date().addingTimeInterval(300)
                        self.verifyIncomingGroup(verified, job: job)
                    } else {
                        try self.validateClipboardPayload(verified, at: self.storage.partial(verified))
                        verified.state = .committing; try self.put(verified)
                        try self.storage.commit(verified)
                        verified.state = .completed; verified.progress = task.size; try self.put(verified)
                        self.jobs.removeValue(forKey: channel)
                        self.send(channel, fileMessage("file.complete", task: verified, extra: ["size": verified.size, "sha256": verified.sha256]), true)
                    }
                case "file.complete":
                    guard task.direction == .outgoing, job.ended, task.state == .verifying, task.progress == task.size else {
                        throw FileFailure(code: "FILE_INVALID", message: "完成消息与传输进度不一致")
                    }
                    self.completeSender(task, message: message)
                case "file.error":
                    self.terminate(task, state: .failed, text: self.remoteError(message))
                default: throw FileFailure(code: "FILE_INVALID", message: "文件数据通道消息无效")
                }
            } catch { self.fail(task, failure: self.failure(error)) }
        }
    }
    private func verifyIncomingGroup(_ task: FileTask, job: FileDataJob) {
        let cancellation = WorkCancellation(); job.verificationCancellation = cancellation
        io.async {
            let result = Result {
                let group = try self.storage.extractGroup(task, archive: self.storage.partial(task), cancellation: cancellation)
                try self.validateClipboardGroup(task, group: group); return group
            }
            self.queue.async {
                guard var current = self.tasks[task.id], current.attemptId == task.attemptId, current.state == .verifying,
                      self.jobs[job.channel] === job, !cancellation.isCancelled else {
                    self.io.async { self.storage.cleanGroupPreparation(task) }; return
                }
                switch result {
                case .failure(let error): self.fail(current, failure: self.failure(error))
                case .success(let group):
                    current.group = group; current.state = .committing
                    do { try self.put(current) }
                    catch { self.fail(task, failure: .io); self.io.async { self.storage.cleanGroupPreparation(task) }; return }
                    job.verificationCancellation = nil
                    let committing = current
                    self.io.async {
                        let commit = Result { try self.storage.commitGroup(committing) }
                        self.queue.async {
                            guard var stored = self.tasks[task.id], stored.attemptId == task.attemptId, stored.state == .committing else { return }
                            switch commit {
                            case .failure(let error): self.fail(stored, failure: self.failure(error))
                            case .success:
                                stored.state = .completed; stored.progress = stored.size; stored.error = nil
                                do {
                                    try self.put(stored); self.jobs.removeValue(forKey: job.channel)
                                    self.send(job.channel, fileMessage("file.complete", task: stored, extra: ["size": stored.size, "sha256": stored.sha256]), true)
                                    self.io.async { self.storage.finishGroupCleanup(stored) }
                                } catch { self.fail(committing, failure: .io) }
                            }
                        }
                    }
                }
            }
        }
    }
    private func sendNext(_ job: FileDataJob) throws {
        guard let task = tasks[job.taskId], let stream = job.outgoing else { throw FileFailure.io }
        if task.progress == task.size {
            job.ended = true
            job.deadline = Date().addingTimeInterval(task.group == nil ? 30 : 300)
            var verifying = task; verifying.state = .verifying; try put(verifying)
            send(job.channel, fileMessage("file.end", task: verifying), false); return
        }
        guard job.expectedAck == nil else { throw FileFailure(code: "FILE_INVALID", message: "分块仍在等待确认") }
        let count = min(FILE_CHUNK_SIZE, Int(task.size - task.progress))
        let bytes = try readBlock(stream.fd, limit: count)
        guard bytes.count == count else { throw FileFailure(code: "FILE_SIZE", message: "发送副本大小发生变化") }
        job.expectedAck = task.progress + Int64(bytes.count)
        send(job.channel, fileMessage("file.chunk", task: task, extra: ["offset": task.progress, "data": bytes.base64EncodedString()]), false)
    }
    private func completeSender(_ task: FileTask, message: [String: Any]) {
        guard fileInteger(message["size"]) == task.size, message["sha256"] as? String == task.sha256 else {
            fail(task, failure: FileFailure(code: "FILE_HASH", message: "对方完成收据与文件校验值不一致")); return
        }
        var completed = task; completed.state = .completed; completed.progress = task.size
        completed.error = task.state == .cancelled ? "对方已保存；取消不会删除已交付文件" : nil
        do { try put(completed); deadlines.removeValue(forKey: task.id); removeJob(task) }
        catch { fail(task, failure: .io) }
    }
    func dataClosed(_ channel: UUID, protocolViolation: Bool = false) {
        queue.async {
            guard let job = self.jobs.removeValue(forKey: channel), let task = self.tasks[job.taskId], task.attemptId == job.attempt,
                  !task.state.terminal, task.state != .committing else { return }
            job.incoming?.abort(); job.verificationCancellation?.cancel()
            if protocolViolation { self.fail(task, failure: FileFailure(code: "FILE_INVALID", message: "文件帧格式或版本无效")) }
            else { self.networkInterrupted(task) }
        }
    }
    func controlClosed(_ control: UUID, revoked: Bool = false, protocolViolation: Bool = false) {
        queue.async {
            let affected = self.sessions.filter { $0.value.control == control }.map(\.key)
            for peer in affected {
                self.sessions.removeValue(forKey: peer)
                self.mediaRequests = self.mediaRequests.filter { $0.value.1 != control }
                self.clipboardRequests = self.clipboardRequests.filter { $0.value.1 != control }
                if revoked { self.cancelPeerPreparations(peer) }
                else if let id = self.clipboardPreparing.removeValue(forKey: peer) { self.preparationTokens[id]?.cancel() }
                for task in self.tasks.values where task.peerId == peer && !task.state.terminal && task.state != .committing {
                    self.removeJob(task)
                    if task.media != nil {self.terminate(task,state:.failed,text:"共享内容会话已失效，请重新下载")}
                    else if revoked { self.terminate(task, state: .failed, text: "设备信任已移除，请重新配对后手动重试") }
                    else if protocolViolation { self.terminate(task, state: .failed, text: "FILE_INVALID：控制帧格式或版本无效") }
                    else { self.networkInterrupted(task) }
                }
            }
            self.emit()
        }
    }
    func revoke(peer: String) {
        queue.async {
            self.mediaRequests = self.mediaRequests.filter { $0.value.0.peerId != peer }
            self.clipboardTrust.removeValue(forKey: peer)
            self.clipboardRequests = self.clipboardRequests.filter { $0.value.0.sourceDeviceId != peer }
            self.cancelPeerPreparations(peer)
            if let session = self.sessions.removeValue(forKey: peer) {
                for job in Array(self.jobs.values) where job.control == session.control { self.closeChannel(job.channel) }
            }
            for task in self.tasks.values where task.peerId == peer && !task.state.terminal && task.state != .committing {
                self.terminate(task, state: .failed, text: "设备信任已移除，请重新配对后手动重试")
            }
            self.emit()
        }
    }
    private func networkInterrupted(_ task: FileTask) {
        guard !task.state.terminal, task.state != .committing else { return }
        clearBusyRetry(task.id)
        if task.direction == .incoming, task.clipboard?.privateOnly == true {
            terminate(task, state: .failed, text: "自动原图缓存已中断，可手动下载"); return
        }
        var interrupted = task; interrupted.state = task.direction == .outgoing ? .waitingConnection : .interrupted
        interrupted.progress = 0; interrupted.error = "连接中断，已保留任务"
        storage.cleanPartial(task); deadlines.removeValue(forKey: task.id)
        do {
            try put(interrupted)
            // 故障项等待控制重连或显式重试；已释放的槽位立即推进其它排队任务。
            schedulePending(peer: task.peerId)
        } catch { notice = FileFailure.io.localizedDescription; emit() }
    }
    func tick(now: Date? = nil) {
        queue.async {
            let now = now ?? Date()
            for (id, retryAt) in self.commitRecoveryAt where retryAt <= now {
                self.commitRecoveryAt.removeValue(forKey: id)
                if let task = self.tasks[id], task.state == .committing { self.recover(task) }
            }
            for (id, deadline) in self.deadlines where deadline <= now {
                if let task = self.tasks[id], !task.state.terminal, task.state != .committing {
                    self.fail(task, failure: FileFailure(code: "FILE_TIMEOUT", message: "文件确认或通道绑定等待超时"))
                }
            }
            for job in Array(self.jobs.values) where job.deadline <= now {
                if let task = self.tasks[job.taskId] {
                    if task.state == .committing { self.jobs.removeValue(forKey: job.channel); self.closeChannel(job.channel) }
                    else { self.fail(task, failure: FileFailure(code: "FILE_TIMEOUT", message: "文件数据或确认等待超时")) }
                }
            }
        }
    }
    func setReceiveFolder(_ url: URL, completion: @escaping (String?) -> Void) {
        queue.async {
            do {
                let folder = try ReceiveFolderLocation.selected(url)
                if self.configuration.fileStoreDirectory == nil { try folder.persist() }
                self.receiveFolder = folder; self.emit(); completion(nil)
            } catch { completion("无法使用这个文件夹，请重新选择可写的接收文件夹") }
        }
    }
    func retryReceivedSave(_ id: String, expectedAttempt: String) {
        queue.async {
            guard let task = self.tasks[id], task.attemptId == expectedAttempt, task.ordinaryIncoming,
                  task.state == .completed, !self.hiddenHistory.contains(id),
                  task.receivedSave == nil || task.receivedSave?.state == .failed,
                  !self.singleExports.contains(id), !self.exportingIDs.contains(id), !self.queuedExportIDs.contains(id) else { return }
            var updated = task; updated.receivedSave = ReceivedFileSaveReceipt(attempt: task.attemptId)
            do { try self.put(updated) } catch { self.notice = "无法记录保存任务，请稍后重试"; self.emit() }
        }
    }
    private func queueReceivedSave(_ task: FileTask) {
        guard automaticSavingEnabled, task.ordinaryIncoming, task.state == .completed,
              task.receivedSave?.state == .pending, !hiddenHistory.contains(task.id), !singleExports.contains(task.id) else { return }
        singleExports.insert(task.id); receivedSaveQueue.append(task.id)
        startNextReceivedSave()
    }
    private func startNextReceivedSave() {
        guard !receivedSaveRunning, !receivedSaveQueue.isEmpty else { return }
        let id = receivedSaveQueue.removeFirst()
        guard var task = tasks[id], task.ordinaryIncoming, task.state == .completed,
              var receipt = task.receivedSave, receipt.state == .pending, !hiddenHistory.contains(id) else {
            singleExports.remove(id); startNextReceivedSave(); return
        }
        receivedSaveRunning = true
        receipt.state = .saving; receipt.folder = receiveFolder; receipt.error = nil
        task.receivedSave = receipt
        do { try put(task) }
        catch {
            // 尚未开始复制，可安全显式重试；数据库暂不可写时先让界面脱离pending。
            receipt.state = .failed; receipt.error = "无法记录保存状态，内部副本仍保留，请稍后重试"
            task.receivedSave = receipt; tasks[id] = task
            try? database.save(task)
            singleExports.remove(id); receivedSaveRunning = false
            emit(); startNextReceivedSave(); return
        }
        let captured = task, folder = receiveFolder
        // 复用现有校验复制及IO队列，不占网络控制队列，也不借用剪贴板的下载意图。
        io.async {
            var resolved: ReceiveFolderLocation?
            let result: BatchTaskOutcome
            do {
                guard let folder else { throw FileFailure.io }
                let access = try ReceiveFolderAccess(folder, create: true)
                resolved = access.location
                result = withExtendedLifetime(access) {
                    self.storage.exportReceivedTask(captured, applicationDirectory: access.url, cancellation: WorkCancellation())
                }
            } catch { result = BatchTaskOutcome(state: "failed", savedRoots: 0, message: "无法访问接收文件夹") }
            self.queue.async {
                defer { self.singleExports.remove(id); self.receivedSaveRunning = false; self.emit(); self.startNextReceivedSave() }
                guard var current = self.tasks[id], current.attemptId == captured.attemptId,
                      current.receivedSave?.state == .saving else { return }
                var saved = receipt
                saved.folder = resolved ?? folder
                saved.roots = result.exportedRoots.map(\.lastPathComponent)
                saved.state = result.state == "completed" ? .saved : .failed
                saved.error = saved.state == .saved ? nil : result.savedRoots > 0 ? "部分文件已保存，请检查接收文件夹后重试" : "自动保存未完成，内部副本仍保留；请检查文件夹的权限和空间后重试"
                current.receivedSave = saved
                do {
                    try self.put(current)
                    if let resolved, self.receiveFolder == folder, resolved != folder {
                        if self.configuration.fileStoreDirectory == nil { try resolved.persist() }
                        self.receiveFolder = resolved
                    }
                } catch {
                    saved.state = .failed; saved.error = "文件保存位置未能记录，请检查接收文件夹后重试"
                    current.receivedSave = saved; self.tasks[id] = current
                    self.notice = saved.error
                }
            }
        }
    }
    /// 普通文件优先打开公共成品；旧历史仍可打开原内部成品，不重复导出。
    func receivedLocations(_ id: String, expectedAttempt: String, completion: @escaping ([URL]?, String?) -> Void) {
        queue.async {
            guard let task = self.tasks[id], task.attemptId == expectedAttempt, task.ordinaryIncoming, task.state == .completed else {
                completion(nil, "记录已更新，请重新打开"); return
            }
            guard let receipt = task.receivedSave else {
                self.location(id: id, expectedAttempt: expectedAttempt) { completion($0.map { [$0] }, $0 == nil ? "本地文件已不存在" : nil) }; return
            }
            guard receipt.state == .saved, let folder = receipt.folder else {
                completion(nil, receipt.error ?? "文件已收到，正在保存到接收文件夹"); return
            }
            self.io.async {
                do {
                    let access = try ReceiveFolderAccess(folder, create: false)
                    let urls = receipt.roots.map { access.url.appendingPathComponent($0) }
                    try withExtendedLifetime(access) {
                        for url in urls {
                            var info = stat()
                            guard lstat(url.path, &info) == 0, [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else { throw FileFailure.io }
                        }
                    }
                    // 用户可编辑已保存文件，打开时只核对存在性，不以原哈希拒绝用户修改。
                    completion(urls, nil)
                } catch { completion(nil, "已保存的文件已移动或删除，可通过“另存为”重新保存") }
            }
        }
    }
    /// 忙时保留完整请求及回调，只有实际执行或逐项失败后才消费用户保存意图。
    func exportMany(_ selections: [FileTaskSelection], parent: URL, cancellation: WorkCancellation? = nil, mediaAuthorization: MediaBinding? = nil, completion: @escaping () -> Void) {
        queue.async {
            self.pendingExports.append(PendingFileExport(selections: selections, parent: parent, cancellation: cancellation, mediaAuthorization: mediaAuthorization, completion: completion))
            self.queuedExportIDs.formUnion(selections.map(\.id))
            if self.exportView?.state == "exporting" { self.notice = "保存请求已排队，当前保存结束后继续"; self.emit() }
            self.startNextExport()
        }
    }
    private func startNextExport() {
        guard exportView?.state != "exporting", !pendingExports.isEmpty else { return }
        let request = pendingExports.removeFirst()
        queuedExportIDs = Set(pendingExports.flatMap { $0.selections.map(\.id) })
        startExport(request.selections, parent: request.parent, cancellation: request.cancellation, mediaAuthorization: request.mediaAuthorization) {
            // 回调先观察本请求结果，再推进下一批，不能把另一批回执当成本次成功。
            request.completion(); self.startNextExport()
        }
    }
    private func rejectExport(_ selections: [FileTaskSelection], message: String, completion: () -> Void) {
        exportView = BatchExportView(id: UUID().uuidString.lowercased(), state: "failed", total: selections.count, completed: 0, failed: selections.count, cancelled: false, message: message,
            items: selections.map { BatchExportItem(id: $0.id, name: tasks[$0.id]?.name ?? "已更新记录", state: "failed", savedRoots: 0, message: message) })
        notice = message; emit(); completion()
    }
    private func startExport(_ selections: [FileTaskSelection], parent: URL, cancellation requestedCancellation: WorkCancellation?, mediaAuthorization: MediaBinding?, completion: @escaping () -> Void) {
        guard !selections.isEmpty, selections.count <= 10_000, Set(selections.map(\.id)).count == selections.count else {
            self.rejectExport(selections, message: "请先选择已完成的接收记录", completion: completion); return
        }
        // 等待队列期间清理历史或身份失效时，不能再使用先前捕获的导出许可。
        if requestedCancellation != nil || mediaAuthorization != nil {
            let authorized: Bool
            if let binding=mediaAuthorization {
                // 媒体显式保存仍绑定原控制连接、信任代际和完成任务；不借剪贴板授权。
                authorized = binding.valid && self.sessions[binding.peerId]?.control.uuidString==binding.controlId && self.clipboardTrust[binding.peerId]==binding.trustGeneration && selections.allSatisfy { selection in
                    guard let task=self.tasks[selection.id] else{return false}
                    return task.attemptId==selection.attemptId && task.media==binding && task.state == .completed && task.direction == .incoming
                }
            } else {
                authorized = selections.allSatisfy { selection in
                    guard let task = self.tasks[selection.id], task.attemptId == selection.attemptId,
                          let binding = task.clipboard, let row = try? self.clipboardRecords.find(source: binding.sourceDeviceId, id: binding.recordId) else { return false }
                    return row.localTaskId == task.id && row.content.kind == "image" && row.content.matchesFile(name: task.name, size: task.size, sha: task.sha256, group: task.group)
                }
            }
            guard requestedCancellation?.isCancelled != true, authorized else { self.rejectExport(selections, message: "原件保存意图已失效", completion: completion); return }
        }
        let id = UUID().uuidString.lowercased(), cancellation = requestedCancellation ?? WorkCancellation()
        self.exportCancellation = cancellation
        self.exportingIDs = Set(selections.map(\.id))
        self.exportView = BatchExportView(id: id, state: "exporting", total: selections.count, completed: 0, failed: 0,
                                         cancelled: false, message: "正在准备保存…", items: [])
        let captured = selections.map { selection -> (FileTaskSelection, FileTask?) in
            let task = self.tasks[selection.id]
            return (selection, task?.attemptId == selection.attemptId && task?.direction == .incoming && task?.state == .completed && !self.clearedPrivateImages.contains(selection.id) && !self.checking.contains(selection.id) ? task : nil)
        }
        self.emit()
        self.io.async {
            let destination = Result { try cancellation.check(); return try self.storage.exportApplicationDirectory(parent: parent) }
            for (selection, task) in captured {
                let result: BatchTaskOutcome
                if cancellation.isCancelled { result = BatchTaskOutcome(state: "cancelled", savedRoots: 0, message: "剩余保存已取消") }
                else if let task {
                    switch destination {
                    case .success(let directory): result = self.storage.exportReceivedTask(task, applicationDirectory: directory, cancellation: cancellation)
                    case .failure(let error): result = BatchTaskOutcome(state: "failed", savedRoots: 0, message: self.explain(error))
                    }
                } else { result = BatchTaskOutcome(state: "failed", savedRoots: 0, message: "记录已更新或不是已完成接收项") }
                let item = BatchExportItem(id: selection.id, name: task?.name ?? "已更新记录", state: result.state, savedRoots: result.savedRoots, message: result.message)
                self.queue.async {
                    guard var view = self.exportView, view.id == id else { return }
                    if let task, let path = result.exportedFile, result.state == "completed" {
                        do { try self.database.recordPublicExport(task, url: path) }
                        catch { self.notice = "文件已保存，但导出凭据未持久化；清理时将保守保留原图" }
                    }
                    view.items.append(item)
                    if item.state == "completed" { view.completed += 1 }
                    if item.state == "failed" { view.failed += 1 }
                    view.cancelled = cancellation.isCancelled
                    view.message = "已完整保存\(view.completed)/\(view.total)项；失败\(view.failed)项"
                    self.exportView = view; self.emit()
                }
            }
            self.queue.async {
                guard var view = self.exportView, view.id == id else { completion(); return }
                view.cancelled = cancellation.isCancelled
                view.state = view.cancelled ? "cancelled" : "completed"
                let partial = view.items.filter { $0.state != "completed" && $0.savedRoots > 0 }.count
                view.message = "已完整保存\(view.completed)/\(view.total)项；失败\(view.failed)项"
                if partial > 0 { view.message += "；\(partial)组部分已保存" }
                if view.cancelled { view.message += "；其余保存已取消" }
                self.exportView = view; self.exportCancellation = nil; self.exportingIDs.removeAll(); self.emit(); completion()
            }
        }
    }
    /// 显式下载只导出校验完成的绑定成品，复用应用目录及同名编号，不重新请求网络。
    func exportClipboardImage(_ view: FileTaskView, cancellation: WorkCancellation, completion: @escaping (String?) -> Void) {
        queue.async {
            guard !cancellation.isCancelled,
                  let task = self.tasks[view.id], task.attemptId == view.attemptId, task.direction == .incoming, task.state == .completed,
                  let binding = task.clipboard, let row = try? self.clipboardRecords.find(source: binding.sourceDeviceId, id: binding.recordId),
                  row.localTaskId == task.id, row.content.kind == "image", row.content.matchesFile(name: task.name, size: task.size, sha: task.sha256, group: task.group),
                  let parent = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { completion("暂时无法保存原图，请等待当前保存结束后重试"); return }
            let previousExportID = self.exportView?.id
            self.exportMany([FileTaskSelection(id: task.id, attemptId: task.attemptId)], parent: parent, cancellation: cancellation) {
                let saved = self.exportView?.id != previousExportID && self.exportView?.items.contains(where: { $0.id == task.id && $0.state == "completed" }) == true
                completion(saved ? nil : "原图保存未完成，请查看保存结果后重试")
            }
        }
    }
    func cancelExport(_ expected: String) {
        queue.async {
            guard self.exportView?.id == expected, self.exportView?.state == "exporting" else { return }
            self.exportCancellation?.cancel(); self.exportView?.cancelled = true
            self.exportView?.message = "正在取消剩余保存，已保存内容保留…"; self.emit()
        }
    }
    #if DEBUG
    func debugExportMany(_ selections: [FileTaskSelection], path: String?) {
        queue.async {
            do {
                let parent = try self.storage.debugExportDirectory(path)
                self.exportMany(selections, parent: parent, completion: {})
            } catch { self.notice = self.explain(error); self.emit() }
        }
    }
    #endif
    func export(id: String, expectedAttempt: String, destination: URL, replace: Bool, completion: @escaping (String?) -> Void) {
        queue.async {
            guard let task = self.tasks[id], task.attemptId == expectedAttempt, task.state == .completed else { completion("文件尚未完成或任务已更新，无法导出"); return }
            guard task.group == nil else { completion("请使用文件组的保存全部"); return }
            guard !self.singleExports.contains(task.id), !self.checking.contains(task.id), !self.clearedPrivateImages.contains(task.id) else { completion("内容正在使用或内部原件已清理，请稍后重试"); return }
            self.singleExports.insert(task.id); self.emit()
            self.io.async {
                let failure: String?
                do { try self.storage.export(task, to: destination, replace: replace); failure = nil } catch { failure = self.explain(error) }
                self.queue.async {
                    if failure == nil {
                        do { try self.database.recordPublicExport(task, url: destination) }
                        catch { self.notice = "文件已保存，但导出凭据未持久化；清理时将保守保留原图" }
                    }
                    self.singleExports.remove(task.id); self.emit(); completion(failure)
                }
            }
        }
    }
    func location(id: String, expectedAttempt: String, completion: @escaping (URL?) -> Void) {
        queue.async {
            guard let task = self.tasks[id], task.attemptId == expectedAttempt, task.state == .completed else { completion(nil); return }
            let url = task.direction == .incoming ? self.storage.final(task) : self.storage.source(task.id)
            self.io.async {
                if task.group != nil && task.direction == .incoming {
                    completion((try? self.storage.groupReceiptMatches(task, cancellation: WorkCancellation())) == true ? self.storage.groupTree(task) : nil)
                } else { completion(self.storage.matches(url, task: task) ? url : nil) }
            }
        }
    }
    private func receipt(_ task: FileTask, attempt: String, control: UUID, missing: @escaping () -> Void) {
        guard checking.count < FILE_RECEIPT_CHECK_LIMIT, !checking.contains(task.id) else {
            error(control, "FILE_BUSY", "正在核对已有完成收据", message: ["taskId": task.id, "attemptId": attempt]); return
        }
        checking.insert(task.id)
        io.async {
            let checked = Result { try self.storage.groupReceiptMatches(task, cancellation: WorkCancellation()) }
            self.queue.async {
                self.checking.remove(task.id)
                guard self.sessions[task.peerId]?.control == control, self.tasks[task.id]?.state == .completed else { return }
                switch checked {
                case .success(true): self.send(control, fileMessage("file.receipt", task: task, extra: ["attemptId": attempt, "size": task.size, "sha256": task.sha256]), false)
                case .success(false): missing()
                case .failure(let error): let f = self.failure(error); self.error(control, f.code, f.message, message: ["taskId": task.id, "attemptId": attempt])
                }
            }
        }
    }
    private func scheduleCommitRecovery(_ task: FileTask) {
        guard task.state == .committing, commitRecoveryAt[task.id] == nil else { return }
        let attempts = commitRecoveryAttempts[task.id, default: 0]
        guard attempts < 6 else {
            notice = "可靠保存仍未完成，已保留提交日志；请恢复存储条件后重试"
            return
        }
        commitRecoveryAt[task.id] = Date().addingTimeInterval(pow(2, Double(attempts)))
    }
    private func recover(_ task: FileTask) {
        guard task.state == .committing, !checking.contains(task.id), commitRecoveryAttempts[task.id, default: 0] < 6 else { return }
        checking.insert(task.id); commitRecoveryAttempts[task.id, default: 0] += 1
        io.async {
            let result = Result { () throws -> GroupMetadata? in
                if task.group != nil { return try self.storage.recoverGroup(task, cancellation: WorkCancellation()) }
                try self.storage.recoverCommit(task); return nil
            }
            self.queue.async {
                self.checking.remove(task.id)
                guard var current = self.tasks[task.id], current.state == .committing, current.attemptId == task.attemptId else { return }
                switch result {
                case .success(let group): current.state = .completed; current.progress = current.size; current.error = nil; if let group { current.group = group }
                case .failure(let error):
                    current.error = self.explain(error)
                    if self.failure(error).code == "FILE_HASH" {
                        current.state = .failed; self.storage.cleanPartial(current)
                    } else {
                        // 已持久化的提交遇到目录同步/存储异常时保留日志，不能降级或伪造收据。
                        current.state = .committing; self.notice = current.error
                    }
                }
                do {
                    try self.put(current)
                    if current.state == .completed {
                        if current.group != nil { self.storage.finishGroupCleanup(current) }
                        if let control = self.sessions[current.peerId]?.control,
                           current.clipboard.map({ $0.trustGeneration == self.clipboardTrust[current.peerId] }) ?? true,
                           current.media.map({ $0.trustGeneration == self.clipboardTrust[current.peerId] && $0.controlId == control.uuidString }) ?? true {
                            self.send(control, fileMessage("file.receipt", task: current, extra: ["size": current.size, "sha256": current.sha256]), false)
                        }
                    } else if current.state == .committing { self.scheduleCommitRecovery(current); self.emit() }
                } catch {
                    self.scheduleCommitRecovery(task)
                    self.notice = "可靠保存收据尚未持久化，保留提交日志重试"; self.emit()
                }
            }
        }
    }
    private func clearBusyRetry(_ id: String) {
        busyRetryWork.removeValue(forKey: id)?.cancel(); busyRetryCounts.removeValue(forKey: id)
    }
    /// BUSY是瞬态容量冲突，只为该尝试安排有界单次重试；终态、断线和手动重试撤销旧回调。
    private func retryAfterBusy(_ task: FileTask, control: UUID) {
        let count = busyRetryCounts[task.id] ?? 0
        guard count < busyRetryDelays.count else {
            terminate(task, state: .failed, text: "FILE_BUSY：对端持续繁忙，自动重试已停止，请稍后手动重试"); return
        }
        busyRetryCounts[task.id] = count + 1
        deadlines.removeValue(forKey: task.id)
        var queued = task; queued.state = .queued; queued.error = "对端繁忙，稍后自动重试（\(count + 1)/\(busyRetryDelays.count)）"
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.tasks[task.id], current.attemptId == task.attemptId,
                  current.state == .queued, self.sessions[task.peerId]?.control == control else { return }
            self.busyRetryWork.removeValue(forKey: task.id)
            self.schedulePending(peer: task.peerId)
        }
        busyRetryWork[task.id]?.cancel(); busyRetryWork[task.id] = work
        do { try put(queued); queue.asyncAfter(deadline: .now() + busyRetryDelays[count], execute: work) }
        catch { clearBusyRetry(task.id); fail(task, failure: .io) }
    }
    private func ordinaryTaskCount(peer: String, excluding: String? = nil) -> Int {
        tasks.values.filter { $0.peerId == peer && $0.id != excluding && $0.clipboard == nil && !$0.state.terminal }.count
    }
    private func cancelPeerPreparations(_ peer: String) {
        for id in [preparing.removeValue(forKey: peer), clipboardPreparing.removeValue(forKey: peer)].compactMap({ $0 }) {
            preparationTokens[id]?.cancel()
        }
    }
    /// 事件推进并合并同一轮通知。先普通任务后剪贴板，旧对端仍共享唯一槽位；不做网络轮询重试。
    private func schedulePending(peer: String) {
        guard pendingScheduling.insert(peer).inserted else { return }
        queue.async {
            self.pendingScheduling.remove(peer)
            guard self.sessions[peer] != nil else { return }
            let queued = self.tasks.values.filter { $0.peerId == peer && $0.direction == .outgoing && $0.state == .queued && self.busyRetryWork[$0.id] == nil }.sorted {
                if ($0.clipboard == nil) != ($1.clipboard == nil) { return $0.clipboard == nil }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.id < $1.id
            }
            for task in queued { self.offer(task.id) }
        }
    }
    private func progress(_ task: FileTask) throws {
        tasks[task.id] = task
        let saved = savedProgress[task.id] ?? (0, Date.distantPast)
        if task.progress - saved.0 >= 1_048_576 || Date().timeIntervalSince(saved.1) >= 0.4 { try put(task, emit: false) }
        if Date().timeIntervalSince(lastEmission) >= 0.1 { emit() }
    }
    private func put(_ task: FileTask, emit shouldEmit: Bool = true) throws {
        var stored = task; stored.updatedAt = Date()
        if stored.receivedSave?.attempt != stored.attemptId { stored.receivedSave = nil }
        // 和完成收据同一行落库；旧的已完成历史没有此标记，不批量搬迁。
        if automaticSavingEnabled, stored.ordinaryIncoming, stored.state == .completed,
           tasks[stored.id]?.state != .completed, stored.receivedSave == nil {
            stored.receivedSave = ReceivedFileSaveReceipt(attempt: stored.attemptId)
        }
        // 已清理历史若收到新的活动尝试，应重新显示待接收/进度；完成去重收据仍保持隐藏。
        let showHistory = hiddenHistory.contains(stored.id) && !stored.state.terminal
        let restoringPrivateImage = stored.state == .completed && clearedPrivateImages.contains(stored.id)
        try database.save(stored, showHistory: showHistory, restoringPrivateImage: restoringPrivateImage)
        // 只有事务成功才更新内存；不能凭成品存在绕过已校验提交或提前发完成收据。
        if restoringPrivateImage { clearedPrivateImages.remove(stored.id) }
        if showHistory { hiddenHistory.remove(stored.id) }
        tasks[task.id] = stored
        if stored.state.terminal { clearBusyRetry(stored.id) }
        if stored.state != .committing { commitRecoveryAttempts.removeValue(forKey: task.id); commitRecoveryAt.removeValue(forKey: task.id) }
        if stored.direction == .incoming, stored.clipboard?.privateOnly == true, stored.state == .completed {
            privateCacheSizes[stored.id] = stored.size
            // 复用历史隐藏和最后引用回收；clipboard仍引用时保留Received成品。
            if !hiddenHistory.contains(stored.id) { hideHistory([FileTaskSelection(id: stored.id, attemptId: stored.attemptId)], completion: { _ in }) }
        }
        // 仅剪贴板下载副本在持久终态后回收；普通手动文件任务仍保留原重试语义。
        if stored.clipboard != nil && stored.direction == .outgoing && [.completed, .failed, .cancelled, .rejected].contains(stored.state) {
            removeJob(stored)
            io.async { self.storage.cleanSource(stored) }
        }
        savedProgress[task.id] = (stored.progress, Date())
        if stored.receivedSave?.state == .pending { queueReceivedSave(stored) }
        if stored.state.terminal || stored.state == .queued { schedulePending(peer: stored.peerId) }
        if shouldEmit { emit() }
    }
    private func removeJob(_ task: FileTask) {
        for job in Array(jobs.values) where job.taskId == task.id {
            jobs.removeValue(forKey: job.channel); job.incoming?.abort(); job.verificationCancellation?.cancel(); closeChannel(job.channel)
        }
    }
    private func terminate(_ task: FileTask, state: FileTaskState, text: String) {
        guard !task.state.terminal, task.state != .committing else { return }
        preparationTokens[task.id]?.cancel()
        removeJob(task); deadlines.removeValue(forKey: task.id); storage.cleanPartial(task)
        if state == .cancelled && task.direction == .outgoing { storage.cleanSource(task) }
        var revised = task; revised.state = state; revised.error = text
        do { try put(revised) } catch { notice = FileFailure.io.localizedDescription; emit() }
    }
    private func fail(_ task: FileTask, failure: FileFailure) {
        let actual = tasks[task.id] ?? task
        if actual.state != .completed && actual.state != .committing {
            for job in Array(jobs.values) where job.taskId == task.id {
                jobs.removeValue(forKey: job.channel); job.incoming?.abort(); job.verificationCancellation?.cancel()
                error(job.channel, failure.code, failure.message, message: task.wireFields, close: true)
            }
            terminate(actual, state: .failed, text: failure.localizedDescription)
        } else if actual.state == .committing {
            // 保留提交日志供下次恢复，不能把已移动的文件误当可清理的半文件。
            notice = failure.localizedDescription; removeJob(actual); scheduleCommitRecovery(actual); emit()
        }
        if let control = sessions[task.peerId]?.control { error(control, failure.code, failure.message, message: task.wireFields) }
    }
    private func failure(_ error: Error) -> FileFailure { (error as? FileFailure) ?? .io }
    private func explain(_ error: Error) -> String { failure(error).localizedDescription }
    private func remoteError(_ message: [String: Any]) -> String {
        let codes = ["FILE_INVALID", "FILE_UNSUPPORTED", "FILE_BUSY", "FILE_NOT_FOUND", "FILE_IO", "FILE_SIZE", "FILE_HASH", "FILE_TIMEOUT"]
        let code = message["code"] as? String ?? "FILE_INVALID"
        return codes.contains(code) ? "\(code)：对方报告文件任务失败" : "FILE_INVALID：对方文件响应无效"
    }
    private func error(_ channel: UUID, _ code: String, _ text: String, message: [String: Any] = [:], close: Bool = false) {
        var fields: [String: Any] = ["code": code, "message": text]
        if let id = fileID(message["taskId"]), let attempt = fileID(message["attemptId"]) { fields["taskId"] = id; fields["attemptId"] = attempt }
        send(channel, wire("file.error", fields), close)
    }
    private func emit() {
        var snapshot = FileTransferSnapshot()
        snapshot.receiveFolderPath = receiveFolder?.path
        var pending: [FileTaskView] = []
        snapshot.tasks = tasks.values.sorted { $0.updatedAt > $1.updatedAt }.map { task in
            var view = task.view; view.historyHidden = hiddenHistory.contains(task.id); view.privateCacheBytes = privateCacheSizes[task.id] ?? 0; view.privateOriginalCleared = clearedPrivateImages.contains(task.id); view.managementBusy = singleExports.contains(task.id) || exportingIDs.contains(task.id) || queuedExportIDs.contains(task.id) || checking.contains(task.id)
            if view.isFileTransferRecord, task.media == nil, task.direction == .incoming, task.state == .awaitingUser { pending.append(view) }
            return view
        }
        snapshot.pendingReceives = pending
        snapshot.preparingPeerIds = Array(preparing.keys).sorted(); snapshot.error = notice; snapshot.noticeRevision = noticeRevision
        snapshot.preparations = preparing.map { FilePreparationView(id: $0.value, peerId: $0.key) }
        snapshot.batchExport = exportView
        lastEmission = Date(); changed(snapshot)
    }
    private func cacheCanBeRemoved(_ task: FileTask) -> Bool {
        task.state.terminal && task.state != .interrupted && !checking.contains(task.id) &&
            !jobs.values.contains(where: { $0.taskId == task.id }) &&
            !singleExports.contains(task.id) && !exportingIDs.contains(task.id) && !queuedExportIDs.contains(task.id) && preparing[task.peerId] != task.id
    }
    private func hasFileHistoryReference(_ task: FileTask) -> Bool {
        // 剪贴板绑定任务不再拥有独立的文件页入口；真正的文件历史仍保护其私有副本。
        task.clipboard == nil && !hiddenHistory.contains(task.id)
    }
    private func discardPrivateCache(_ task: FileTask) throws {
        try storage.removeTaskCache(task)
        privateCacheSizes.removeValue(forKey: task.id)
        var updated = task; updated.imagePreview = nil
        try database.save(updated); tasks[task.id] = updated
    }
    func independentImageExportExists(_ row: ClipboardRecord, completion: @escaping (Bool) -> Void) {
        queue.async {
            do {
                let candidates = self.tasks.values.filter {
                    $0.clipboard?.sourceDeviceId == row.content.sourceDeviceId && $0.clipboard?.recordId == row.content.recordId &&
                        $0.group == nil && row.content.matchesFile(name: $0.name, size: $0.size, sha: $0.sha256, group: nil)
                }
                let paths = try candidates.map { task in (task, try self.database.publicExportPaths(task)) }
                self.io.async { completion(paths.contains { task, urls in urls.contains { self.storage.independentExportMatches($0, task: task) } }) }
            } catch { completion(false) }
        }
    }
    /// 此入口只清内部原图，保留任务/收据及缩图；普通可见传输历史和其他记录仍是独立引用。
    func clearClipboardPrivateImage(_ row: ClipboardRecord, refetchControl: UUID?, cancellation: WorkCancellation, completion: @escaping (ManagementResult) -> Void) {
        queue.async {
            var result = ManagementResult()
            do {
                let related = self.tasks.values.filter {
                    $0.direction == .incoming && $0.state == .completed && $0.group == nil && $0.clipboard?.sourceDeviceId == row.content.sourceDeviceId &&
                        $0.clipboard?.recordId == row.content.recordId && !self.clearedPrivateImages.contains($0.id)
                }
                let admitted = try related.filter { task in
                    guard task.state == .completed, self.cacheCanBeRemoved(task), !self.hasFileHistoryReference(task),
                          try !self.clipboardRecords.references(task: task, excludingRecordKey: row.key) else { result.keptActive += 1; return false }
                    return true
                }
                let paths = try admitted.map { task in (task, try self.database.publicExportPaths(task)) }
                for task in admitted { self.checking.insert(task.id) }
                self.emit()
                self.io.async {
                    let exported = Set(paths.filter { task, urls in urls.contains { self.storage.independentExportMatches($0, task: task) } }.map { $0.0.id })
                    self.queue.async {
                        var outcome = result
                        defer { for task in admitted { self.checking.remove(task.id) }; self.emit(); completion(outcome) }
                        for task in admitted {
                            do {
                                guard !cancellation.isCancelled, let current = try self.clipboardRecords.find(source: row.content.sourceDeviceId, id: row.content.recordId), current.content.kind == "image", current.content.same(row.content),
                                      self.tasks[task.id]?.attemptId == task.attemptId,
                                      !self.singleExports.contains(task.id), !self.exportingIDs.contains(task.id),
                                      !self.queuedExportIDs.contains(task.id),
                                      try !self.clipboardRecords.references(task: task, excludingRecordKey: row.key) else { outcome.keptActive += 1; continue }
                                // 导出核验可能长时间占用IO；离线或换通道后不能沿用入口时的可重取判断。
                                let refetchable = refetchControl != nil && self.sessions[current.content.sourceDeviceId]?.control == refetchControl && current.available && current.cacheExpiresAt > milliseconds() && self.clipboardTrust[current.content.sourceDeviceId] == task.clipboard?.trustGeneration
                                guard refetchable || exported.contains(task.id) else { outcome.keptActive += 1; continue }
                                // 只删除固定私有目录，不接收/删除公共导出路径；先删后标记，崩溃由启动缺失检查核对。
                                try self.storage.removeTaskCache(task)
                                self.clearedPrivateImages.insert(task.id); self.privateCacheSizes.removeValue(forKey: task.id)
                                try self.database.markPrivateImageCleared(task.id)
                                outcome.removed += 1
                            } catch { outcome.failed += 1 }
                        }
                    }
                }
            } catch { result.failed += 1; self.emit(); completion(result) }
        }
    }
    /// 调用方持有剪贴板串行队列；在文件队列复核活动/导出与全库引用后，才删除最后一个记录。
    func deletingClipboardRecord(_ row: ClipboardRecord, operation: () throws -> Void) throws {
        try queue.sync {
            let related = tasks.values.filter { task in
                task.id == row.localTaskId || (task.clipboard?.sourceDeviceId == row.content.sourceDeviceId && task.clipboard?.recordId == row.content.recordId)
            }
            guard related.allSatisfy(cacheCanBeRemoved) else { throw FileFailure(code: "FILE_BUSY", message: "内容正在传输或保存") }
            for task in related where !hasFileHistoryReference(task) {
                if try !clipboardRecords.references(task: task, excludingRecordKey: row.key) { try discardPrivateCache(task) }
            }
            try operation()
            emit()
        }
    }
    /// 只由用户明确清理触发，收尾旧版已隐藏、终态且无引用的私有副本，绝不在启动时扫描。
    private func reapHiddenCache(excluding ids: Set<String> = []) -> Int {
        var failures = 0
        for id in hiddenHistory {
            if ids.contains(id) { continue }
            guard let task = tasks[id], cacheCanBeRemoved(task) else { continue }
            do {
                if try !clipboardRecords.references(task: task) { try discardPrivateCache(task) }
            } catch { failures += 1 }
        }
        return failures
    }
    /// 准入只查询已维护的字节统计，不在空闲tick遍历磁盘或剪贴板历史。
    func automaticPrivateCacheBusy() -> Bool {
        queue.sync { tasks.values.contains { $0.direction == .incoming && $0.clipboard?.privateOnly == true && !$0.state.terminal } }
    }
    func privateImageCacheBytes() -> Int64 { queue.sync { privateCacheSizes.values.reduce(0, +) } }
    func cleanHiddenHistoryCache() -> Int {
        queue.sync { let failures = reapHiddenCache(); emit(); return failures }
    }
    /// 隐藏终态历史；另一入口仍引用时保留，最后一个引用释放时回收应用私有缓存。
    func hideHistory(_ selections: [FileTaskSelection], completion: @escaping (ManagementResult) -> Void) {
        queue.async {
            var result = ManagementResult()
            guard selections.count <= 10_000 else { result.failed = selections.count; completion(result); return }
            for selection in selections {
                guard let task = self.tasks[selection.id], task.attemptId == selection.attemptId else { result.failed += 1; continue }
                guard self.cacheCanBeRemoved(task) else { result.keptActive += 1; continue }
                do {
                    if try !self.clipboardRecords.references(task: task) { try self.discardPrivateCache(task) }
                    try self.database.hide(task.id); self.hiddenHistory.insert(task.id); result.removed += 1
                }
                catch { result.failed += 1 }
            }
            result.failed += self.reapHiddenCache(excluding: Set(selections.map(\.id)))
            self.emit(); completion(result)
        }
    }
    func clipboardPreviewURL(taskID: String, completion: @escaping (URL?) -> Void) {
        queue.async {
            guard let task = self.tasks[taskID], task.state == .completed, task.direction == .incoming, task.group == nil, task.clipboard != nil, !self.clearedPrivateImages.contains(task.id), !self.checking.contains(task.id) else { completion(nil); return }
            let url = self.storage.final(task)
            self.io.async { completion(self.storage.matches(url, task: task) ? url : nil) }
        }
    }

}
