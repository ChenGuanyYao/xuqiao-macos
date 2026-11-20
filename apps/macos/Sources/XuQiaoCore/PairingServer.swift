import Foundation
import Network
import CryptoKit
import Darwin

private struct PairingSession {
    let id: String
    let code: String
    let proof: String
    let expires: Date
    var mistakes = 0
    init() throws {
        id = UUID().uuidString.lowercased()
        let bytes = try secureBytes(4)
        let number = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        code = String(format: "%06u", number % 1_000_000)
        proof = hex(try secureBytes(32)); expires = Date().addingTimeInterval(120)
    }
}
private struct PendingPairing {
    let sessionID: String
    let channelID: UUID
    let clientID: String
    let clientName: String
    let verificationCode: String
    var phoneConfirmed = false
    var macConfirmed = false
}

public final class PairingServer {
    private let queue = DispatchQueue(label: "com.chenguangyao.xuqiao.server")
    private let configuration: ServerConfiguration
    private var store: SecureStore!
    private var identity: ServerIdentity?
    private var session: PairingSession?
    private var pending: PendingPairing?
    private var peers: [StoredPeer] = []
    private var channels: [UUID: TLSChannel] = [:]
    private var listener: NWListener?
    private var discovery: DiscoveryResponder?
    private var timer: DispatchSourceTimer?
    private var networkMonitor: NWPathMonitor?
    private var addresses: [String] = []
    private var generation = 0
    private var tlsRenewalPending = false
    private var nextTLSRenewalAttempt = Date.distantPast
    private var running = false
    private var ready = false
    private var issue: String?
    private var callback: ((ServerSnapshot) -> Void)?
    private var fileEngine: FileTransferEngine?
    private var clipboard: ClipboardCoordinator?
    private var media: DeviceMediaCoordinator?
    private var bluetoothWake: BluetoothWakeCoordinator?
    public let screenImages = ScreenImageHub()
    private var fileSnapshot = FileTransferSnapshot()
    private var fileControlPending: [UUID: Int] = [:]
    #if DEBUG
    private let fileCommands = DebugFileCommands()
    private var debugManagement: [String: Any] = [:]
    #endif
    private let name = Host.current().localizedName ?? "我的 Mac"

    public init(configuration: ServerConfiguration = ServerConfiguration()) { self.configuration = configuration }
    public func start(onChange: @escaping (ServerSnapshot) -> Void) {
        queue.async { [self] in
            guard !self.running else { return }
            self.running = true; self.callback = onChange
            self.startServices()
        }
    }
    /// 启动失败后显式重试：保留钥匙串身份和信任，清理旧监听及回调后再启动。
    public func retry() {
        queue.async {
            guard self.running, !self.ready, self.issue != nil else { return }
            self.stopServices()
            self.startServices()
        }
    }
    private func startServices() {
        issue = nil; session = nil; publish()
        do {
            self.store = SecureStore(suffix: self.configuration.keychainSuffix)
            self.identity = try ServerIdentity(store: self.store)
            self.peers = try self.store.readJSON("peers-v1", as: [StoredPeer].self) ?? []
            self.startFileEngine()
            if self.clipboard == nil {
                guard let engine = fileEngine, let identity else { throw CoreFailure("统一剪贴板需要可用的本地任务库") }
                self.clipboard = try ClipboardCoordinator(configuration: configuration, store: store, queue: queue,
                    localID: identity.deviceID, localName: name, engine: engine, peers: peers,
                    send: { [weak self] id, message in self?.channels[id]?.send(message) },
                    changed: { [weak self] in self?.publish() },
                    newLocalContent: { [weak self] targets in self?.wakeOfflinePeers(targets) })
            }
            if self.media == nil, let engine=fileEngine,let identity {
                self.media=DeviceMediaCoordinator(queue:queue,engine:engine,serverID:identity.deviceID,hub:screenImages,send:{[weak self] id,message in self?.channels[id]?.send(message)},close:{[weak self] id in self?.channels[id]?.close()},changed:{[weak self] in self?.publish()})
            }
            self.updateBluetoothWake()
            self.session = try PairingSession()
            self.addresses = localAddresses()
            try self.startListener()
            self.discovery = try DiscoveryResponder(port: self.configuration.discoveryPort, queue: self.queue) { [weak self] nonce in self?.advertisement(nonce: nonce) }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }; timer.resume(); self.timer = timer
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in self?.networkChanged() }
            monitor.start(queue: self.queue); self.networkMonitor = monitor
        } catch { self.issue = error.localizedDescription; self.stopServices() }
        self.publish()
    }
    private func validMediaPeer(_ peer:String,_ generation:String)->Bool {peers.contains{$0.id==peer && ($0.clipboardTrustGeneration ?? "legacy")==generation}}
    public func requestScreen(peerID:String,expectedGeneration:String){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.startScreen(peer:peerID,generation:expectedGeneration)}}
    public func stopScreen(peerID:String,expectedGeneration:String){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.stopScreen(peer:peerID,generation:expectedGeneration)}}
    public func requestFiles(peerID:String,expectedGeneration:String){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.requestFiles(peer:peerID,generation:expectedGeneration)}}
    public func authorizeFiles(peerID:String,expectedGeneration:String){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.authorizeFiles(peer:peerID,generation:expectedGeneration)}}
    public func forgetFiles(peerID:String,expectedGeneration:String){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.forgetFiles(peer:peerID,generation:expectedGeneration)}}
    public func previewAlbum(peerID:String,expectedGeneration:String,grantID:String,assetID:String,context:String,completion:@escaping(URL?)->Void){queue.async{guard self.validMediaPeer(peerID,expectedGeneration),let media=self.media else{DispatchQueue.main.async{completion(nil)};return};media.previewAlbum(peer:peerID,generation:expectedGeneration,grantID:grantID,assetID:assetID,context:context){url in DispatchQueue.main.async{completion(url)}}}}
    public func closeAlbumPreview(peerID:String,expectedGeneration:String,grantID:String,assetID:String,context:String){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.closeAlbumPreview(peer:peerID,generation:expectedGeneration,grantID:grantID,assetID:assetID,context:context)}}
    public func listFiles(peerID:String,expectedGeneration:String,folderID:String,offset:Int,query:String?=nil,sort:String?=nil){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.listFiles(peer:peerID,generation:expectedGeneration,folderID:folderID,offset:offset,query:query,sort:sort)}}
    public func downloadFiles(peerID:String,expectedGeneration:String,entryIDs:[String]){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.downloadFiles(peer:peerID,generation:expectedGeneration,entryIDs:entryIDs)}}
    public func revokeFiles(peerID:String,expectedGeneration:String){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.revokeFiles(peer:peerID,generation:expectedGeneration)}}
    public func leaveFiles(peerID:String,expectedGeneration:String){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.leaveFiles(peer:peerID,generation:expectedGeneration)}}
    public func requestAlbum(peerID:String,expectedGeneration:String,kind:String="image"){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.requestAlbum(peer:peerID,generation:expectedGeneration,kind:kind)}}
    public func listAlbum(peerID:String,expectedGeneration:String,offset:Int,query:String?=nil,sort:String?=nil){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.listAlbum(peer:peerID,generation:expectedGeneration,offset:offset,query:query,sort:sort)}}
    public func downloadAlbum(peerID:String,expectedGeneration:String,assetIDs:[String]){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.download(peer:peerID,generation:expectedGeneration,assets:assetIDs)}}
    public func leaveAlbum(peerID:String,expectedGeneration:String){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.leaveAlbum(peer:peerID,generation:expectedGeneration)}}
    public func revokeAlbum(peerID:String,expectedGeneration:String){queue.async{guard self.validMediaPeer(peerID,expectedGeneration) else{return};self.media?.revokeAlbum(peer:peerID,generation:expectedGeneration)}}
    public func stop() { queue.async { self.running = false; self.stopServices(); self.callback = nil } }
    public func refreshPairing() { queue.async { self.rotateSession(reason: "PAIRING_EXPIRED", message: "配对码已刷新，请重新扫码或输入新码") } }
    public func approve(sessionID: String, requestID: String) {
        queue.async {
            guard var request = self.pending, request.sessionID == sessionID, request.channelID.uuidString == requestID, self.session?.id == sessionID,
                  let session = self.session, session.expires > Date(),
                  let channel = self.channels[request.channelID], !channel.closing else { return }
            request.macConfirmed = true; self.pending = request
            self.finishPairingIfConfirmed(); self.publish()
        }
    }
    public func reject(sessionID: String, requestID: String) {
        queue.async {
            guard let request = self.pending, request.sessionID == sessionID, request.channelID.uuidString == requestID else { return }
            if let channel = self.channels[request.channelID] { self.fail(channel, "PAIRING_REJECTED", "Mac 已拒绝本次配对", pairingID: sessionID) }
            self.pending = nil
            self.rotateSession()
        }
    }
    public func disconnect(peerID: String, expectedGeneration: String? = nil) {
        queue.async {
            guard let index = self.peers.firstIndex(where: { $0.id == peerID && (expectedGeneration == nil || ($0.clipboardTrustGeneration ?? "legacy") == expectedGeneration) }) else { return }
            var revised = self.peers; revised[index].paused = true
            do { try self.savePeers(revised) } catch { self.issue = error.localizedDescription; self.publish(); return }
            self.closeFileChannels(peerID: peerID)
            for channel in self.channels.values where channel.authenticatedPeer == peerID {
                self.fileEngine?.controlClosed(channel.id)
                self.clipboard?.disconnected(channel.id)
                self.media?.disconnected(channel.id)
                channel.send(wire("session.disconnect", ["reason": "user"]), closeAfter: true)
            }
            self.publish()
        }
    }
    public func remove(peerID: String, expectedGeneration: String? = nil) {
        queue.async {
            guard self.peers.contains(where: { $0.id == peerID && (expectedGeneration == nil || ($0.clipboardTrustGeneration ?? "legacy") == expectedGeneration) }) else { return }
            let revised = self.peers.filter { $0.id != peerID }
            do { try self.savePeers(revised) } catch { self.issue = error.localizedDescription; self.publish(); return }
            do { try self.clipboard?.resetTrust(peerID) } catch { self.issue = "剪贴板开关清理失败，下次配对将重新初始化" }
            for channel in self.channels.values where channel.authenticatedPeer==peerID {self.media?.disconnected(channel.id)}
            self.fileEngine?.revoke(peer: peerID)
            self.closeFileChannels(peerID: peerID)
            for channel in self.channels.values where channel.authenticatedPeer == peerID {
                channel.send(wire("session.revoked", ["clientId": peerID]), closeAfter: true)
            }
            self.publish()
        }
    }
    public func allowReconnect(peerID: String, expectedGeneration: String) {
        queue.async {
            guard let index = self.peers.firstIndex(where: { $0.id == peerID && ($0.clipboardTrustGeneration ?? "legacy") == expectedGeneration }) else { return }
            var revised = self.peers; revised[index].paused = false
            do { try self.savePeers(revised) } catch { self.issue = "无法保存重连设置" }
            self.publish()
        }
    }
    private func startListener() throws {
        guard let identity else { return }
        // 先完成重签与验证，再替换监听；已有TLS通道继续使用原会话。
        let tls = try identity.tlsOptions(addresses: addresses)
        ready = false; generation += 1
        let epoch = generation
        listener?.cancel(); listener = nil
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: configuration.port)!)
        // Bonjour 只提供地址线索；手机仍须通过原 UDP nonce 校验与 TLS 配对建立信任。
        listener.service = NWListener.Service(name: "XuQiao-" + identity.deviceID, type: "_xuqiao._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.running, self.generation == epoch else { return }
            switch state {
            case .ready: self.ready = true; self.tlsRenewalPending = false; self.issue = nil; self.publish()
            case .failed(let error): self.ready = false; self.issue = "安全连接监听失败：\(error.localizedDescription)"; self.publish()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.running, self.generation == epoch else { connection.cancel(); return }
            // 限制未认证连接总量，避免空闲套接字无限堆积。
            guard self.channels.count < 32 else { connection.cancel(); return }
            let channel = TLSChannel(connection)
            self.channels[channel.id] = channel
            channel.onMessage = { [weak self] channel, message in self?.handle(channel, message) }
            channel.onClose = { [weak self] channel in
                guard let self else { return }
                self.channels.removeValue(forKey: channel.id)
                self.fileControlPending.removeValue(forKey: channel.id)
                if channel.isMediaData { self.media?.streamClosed(channel.id) }
                else if channel.isFileData { self.fileEngine?.dataClosed(channel.id, protocolViolation: channel.protocolViolation) }
                else if channel.authenticatedPeer != nil {
                    self.closeFileChannels(controlID: channel.id)
                    self.fileEngine?.controlClosed(channel.id, protocolViolation: channel.protocolViolation)
                    self.clipboard?.disconnected(channel.id)
                    self.media?.disconnected(channel.id)
                    if let peer = channel.authenticatedPeer { self.wakeOfflinePeers([peer]) }
                }
                if self.pending?.channelID == channel.id { self.pending = nil }
                self.publish()
            }
            channel.start(queue: self.queue)
        }
        self.listener = listener; listener.start(queue: queue)
    }
    private func stopServices() {
        ready = false; generation += 1
        bluetoothWake?.stop(); bluetoothWake = nil
        listener?.cancel(); listener = nil
        discovery?.stop(); discovery = nil
        timer?.cancel(); timer = nil
        networkMonitor?.cancel(); networkMonitor = nil
        for channel in Array(channels.values) { channel.close() }
        channels.removeAll(); pending = nil
        media?.stop(); media=nil
        clipboard?.stop(); clipboard = nil
    }
    private func networkChanged() {
        guard running else { return }
        let current = localAddresses()
        guard current != addresses else { return }
        addresses = current
        generation += 1; ready = false; listener?.cancel(); listener = nil
        for channel in Array(channels.values) { channel.close() }
        do { try startListener() } catch { issue = error.localizedDescription }
        publish()
    }
    private func savePeers(_ revised: [StoredPeer]) throws {
        try store.writeJSON("peers-v1", value: revised)
        peers = revised; clipboard?.updatePeers(revised)
        updateBluetoothWake()
    }
    /// 只由启动/信任变更更新目标；快照发布及 LAN 心跳不触发蓝牙轮询。
    private func updateBluetoothWake() {
        guard running, configuration.bluetoothWakeEnabled, let identity else { return }
        if bluetoothWake == nil { bluetoothWake = BluetoothWakeCoordinator(queue: queue, changed: { [weak self] in self?.publish() }) }
        bluetoothWake?.update(macID: identity.deviceID, peers: peers)
    }
    /// 设置页出现或从系统设置返回时检查一次；不使用轮询，也不改变 LAN 连接意图。
    public func refreshBluetoothWakeAuthorization() {
        queue.async {
            self.updateBluetoothWake()
            self.bluetoothWake?.refreshAuthorization()
            self.publish()
        }
    }
    public func requestBluetoothWakeAuthorization(completion: @escaping (Bool) -> Void) {
        queue.async {
            self.updateBluetoothWake()
            let openSettings = self.bluetoothWake?.requestAuthorization() ?? false
            self.publish()
            DispatchQueue.main.async { completion(openSettings) }
        }
    }
    private func wakeOfflinePeers(_ targets: [String]) {
        guard running else { return }
        for peer in Set(targets) where !channels.values.contains(where: { $0.authenticatedPeer == peer && !$0.closing && !$0.isFileData && !$0.isMediaData }) {
            bluetoothWake?.wake(peerID: peer)
        }
    }
    private func rotateSession(reason: String = "PAIRING_EXPIRED", message: String = "配对会话已失效，请重新连接") {
        if let request = pending, let channel = channels[request.channelID] { fail(channel, reason, message, pairingID: request.sessionID) }
        pending = nil
        do { session = try PairingSession() } catch { session = nil; issue = error.localizedDescription }
        publish()
    }
    private func advertisement(nonce: String? = nil) -> [String: Any]? {
        guard ready, let identity, let session else { return nil }
        var result: [String: Any] = ["service": "xuqiao.connect", "v": 1, "deviceId": identity.deviceID, "name": name, "host": lanAddress(addresses), "port": configuration.port, "caPem": identity.caPEM, "caFingerprint": identity.fingerprint, "pairingId": session.id, "expiresAt": milliseconds(session.expires)]
        if let nonce { result["type"] = "advertisement"; result["nonce"] = nonce }
        return result
    }
    private func handle(_ channel: TLSChannel, _ message: [String: Any]) {
        guard !channel.closing, let type = message["type"] as? String else { return }
        let first = !channel.receivedFirstMessage; channel.receivedFirstMessage = true
        if channel.isMediaData {media?.frame(channel:channel.id,message:message);return}
        if type == "device.screen.bind" {
            guard first,media?.bind(channel:channel.id,message:message)==true else{channel.close();return}
            channel.isMediaData=true;return
        }
        if type.hasPrefix("device.") {
            guard let peer=channel.authenticatedPeer else{channel.close();return}
            media?.control(peer:peer,channel:channel.id,message:message);return
        }
        if channel.isFileData {
            channel.pauseReceiving(); fileEngine?.data(channel: channel.id, message: message); return
        }
        if type == "file.bind" {
            guard first else { fileError(channel, code: "FILE_INVALID", text: "数据通道必须以绑定帧开始", message: message); return }
            channel.isFileData = true; channel.pauseReceiving(); bindFileChannel(channel, message); return
        }
        if type.hasPrefix("file.") { handleFileControl(channel, message); return }
        if type.hasPrefix("clip.") {
            guard let peer = channel.authenticatedPeer, let clipboard else {
                channel.send(wire("clip.error", ["code": "CLIP_INVALID"]), closeAfter: channel.authenticatedPeer == nil); return
            }
            clipboard.control(peer: peer, channel: channel.id, message: message); return
        }
        switch type {
        case "pair.begin": beginPairing(channel, message)
        case "pair.confirm":
            guard channel.authenticatedPeer == nil, var request = pending, request.channelID == channel.id,
                  message["pairingId"] as? String == request.sessionID else { fail(channel, "INVALID_MESSAGE", "没有可确认的配对请求"); return }
            guard let session, session.expires > Date() else { fail(channel, "PAIRING_EXPIRED", "配对码已过期"); pending = nil; return }
            request.phoneConfirmed = true; pending = request
            finishPairingIfConfirmed()
        case "pair.cancel":
            guard let request = pending, request.channelID == channel.id, message["pairingId"] as? String == request.sessionID else { fail(channel, "INVALID_MESSAGE", "没有可取消的配对请求"); return }
            pending = nil; channel.close(); rotateSession()
        case "session.resume": resume(channel, message)
        case "ping":
            guard channel.authenticatedPeer != nil, let request = validIdentifier(message["requestId"]) else { fail(channel, "INVALID_MESSAGE", "心跳尚未认证或缺少请求编号"); return }
            channel.send(wire("pong", ["requestId": request])); return
        case "pong":
            guard channel.authenticatedPeer != nil, let request = validIdentifier(message["requestId"]), request == channel.pingRequest else { fail(channel, "INVALID_MESSAGE", "心跳响应无效"); return }
            channel.lastPong = Date(); channel.pingRequest = nil; return
        case "session.disconnect":
            guard let peerID = channel.authenticatedPeer, message["reason"] as? String == "user", let index = peers.firstIndex(where: { $0.id == peerID }) else { fail(channel, "INVALID_MESSAGE", "断开请求无效"); return }
            var revised = peers; revised[index].paused = true
            do { try savePeers(revised); closeFileChannels(controlID: channel.id); fileEngine?.controlClosed(channel.id); clipboard?.disconnected(channel.id); channel.close() } catch { fail(channel, "AUTH_FAILED", "无法保存暂停状态"); issue = error.localizedDescription }
        default: fail(channel, "INVALID_MESSAGE", "当前消息类型不受支持")
        }
        publish()
    }
    public func sendClipboard(peerID: String, expectedContext: String, text: String? = nil) { queue.async { guard self.peers.contains(where: { $0.id == peerID }) else { return }; self.clipboard?.manual(peer: peerID, text: text, expectedContext: expectedContext) } }
    public func clipboardDetailText(source: String, recordID: String, context: String, completion: @escaping (String?) -> Void) {
        queue.async { let text = self.clipboard?.detailText(source: source, id: recordID, context: context); DispatchQueue.main.async { completion(text) } }
    }
    public func locateClipboardResource(source: String, recordID: String, context: String, completion: @escaping (ClipboardLocalResource?) -> Void) {
        queue.async {
            guard let clipboard = self.clipboard else { DispatchQueue.main.async { completion(nil) }; return }
            clipboard.locateResource(source: source, id: recordID, expectedContext: context) { resource in
                DispatchQueue.main.async { completion(resource) }
            }
        }
    }
    public func queryClipboard(source: String, kind: String, page: Int, query: String = "") { queue.async { self.clipboard?.query(source: source, kind: kind, page: page, query: query) } }
    public func downloadManyClipboard(keys: [String], context: String) { queue.async { self.clipboard?.downloadMany(keys: keys, context: context) } }
    public func downloadClipboard(source: String, recordID: String, context: String) { queue.async { self.clipboard?.download(source: source, id: recordID, expectedContext: context) } }
    public func copyClipboardRecord(source: String, recordID: String, context: String) { queue.async { self.clipboard?.copyRecord(source: source, id: recordID, expectedContext: context) } }
    public func cancelClipboardDownload(source: String, recordID: String, context: String) { queue.async { self.clipboard?.cancelDownload(source: source, id: recordID, expectedContext: context) } }
    public func deleteClipboardRecord(source: String, recordID: String, context: String) { queue.async { self.clipboard?.delete(source: source, id: recordID, expectedContext: context) } }
    public func saveClipboardPreferences(_ value: ClipboardPreferences, context: String, completion: @escaping (String?) -> Void) {
        queue.async { let error = self.clipboard?.savePreferences(value,expectedContext: context) ?? (self.clipboard == nil ? "剪贴板服务尚未就绪" : nil); DispatchQueue.main.async { completion(error) } }
    }
    public func allClipboardKeys(source: String, kind: String, query: String, completion: @escaping ([String],String) -> Void) {
        queue.async { let keys = self.clipboard?.allKeys(source: source,kind: kind,query: query) ?? [], context = self.clipboard?.context ?? ""; DispatchQueue.main.async { completion(keys,context) } }
    }
    public func deleteManyClipboard(keys: [String], context: String, completion: @escaping (ManagementResult) -> Void) {
        queue.async { let result = self.clipboard?.deleteMany(keys: keys,context: context) ?? ManagementResult(failed: keys.count); DispatchQueue.main.async { completion(result) } }
    }
    public func clearClipboardCache(previews: Bool, sources: Bool, context: String, completion: @escaping (ManagementResult) -> Void) {
        queue.async { let result = self.clipboard?.clearCache(previews: previews,sources: sources,context: context) ?? ManagementResult(failed: 1); DispatchQueue.main.async { completion(result) } }
    }
    public func clearClipboardPrivateImages(context: String, completion: @escaping (ManagementResult) -> Void) {
        queue.async {
            guard let clipboard = self.clipboard else { DispatchQueue.main.async { completion(ManagementResult(failed: 1)) }; return }
            clipboard.clearPrivateImages(context: context) { result in DispatchQueue.main.async { completion(result) } }
        }
    }
    public func requestClipboardPreviews(keys: [String], context: String) { queue.async { self.clipboard?.requestPreviews(keys: keys,context: context) } }
    public func cancelClipboardPreviews(context: String) { queue.async { self.clipboard?.cancelPreviews(context: context) } }
    public func sendClipboardToAll(text: String? = nil, context: String) { queue.async { self.clipboard?.manualToAll(text: text,expectedContext: context) } }
    public func hideFileHistory(_ selections: [FileTaskSelection], completion: @escaping (ManagementResult) -> Void) {
        queue.async {
            guard let engine = self.fileEngine else { DispatchQueue.main.async { completion(ManagementResult(failed: selections.count)) }; return }
            engine.hideHistory(selections) { result in DispatchQueue.main.async { completion(result) } }
        }
    }
    private func startFileEngine() {
        guard fileEngine == nil else { return }
        do {
            fileEngine = try FileTransferEngine(configuration: configuration, send: { [weak self] id, message, close in
                self?.queue.async {
                    guard let self, let channel = self.channels[id] else { return }
                    if message["type"] as? String == "file.hello" {
                        channel.fileCapable = true; channel.groupCapable = message["groupProtocol"] as? String == "xq-group/1"
                        if let peer = channel.authenticatedPeer { self.clipboard?.fileCapability(peer: peer, file: true, group: channel.groupCapable) }
                    }
                    if message["type"] as? String == "file.error", message["taskId"] == nil { channel.fileCapable = false; channel.groupCapable = false; if let peer = channel.authenticatedPeer { self.clipboard?.fileCapability(peer: peer, file: false, group: false) } }
                    channel.send(message, closeAfter: close)
                    if message["type"] as? String == "file.hello" || (message["type"] as? String == "file.error" && message["taskId"] == nil) { self.publish() }
                }
            }, close: { [weak self] id in
                self?.queue.async { self?.channels[id]?.close() }
            }, resume: { [weak self] id in
                self?.queue.async { self?.channels[id]?.resumeReceiving() }
            }, changed: { [weak self] snapshot in
                self?.queue.async { guard let self else { return }; self.fileSnapshot = snapshot; self.clipboard?.tasksChanged(snapshot.tasks); self.media?.tasksChanged(snapshot.tasks); self.publish() }
            })
        } catch { fileSnapshot.error = "FILE_IO：文件任务库不可用，请检查存储后重新启动" }
    }
    public func sendFile(source: URL, peerID: String, expectedGeneration: String? = nil, completion: @escaping (String?) -> Void = { _ in }) {
        queue.async {
            guard self.peers.contains(where: { $0.id == peerID && (expectedGeneration == nil || ($0.clipboardTrustGeneration ?? "legacy") == expectedGeneration) }), let engine = self.fileEngine else {
                DispatchQueue.main.async { completion("设备身份已变化或本地存储未就绪，请重新选择设备") }; return
            }
            engine.prepareSend(peer: peerID, source: source) { error in DispatchQueue.main.async { completion(error) } }
        }
    }
    public func sendMany(sources: [URL], peerID: String, expectedGeneration: String? = nil, completion: @escaping (String?) -> Void = { _ in }) {
        queue.async {
            guard self.peers.contains(where: { $0.id == peerID && (expectedGeneration == nil || ($0.clipboardTrustGeneration ?? "legacy") == expectedGeneration) }), let engine = self.fileEngine else {
                DispatchQueue.main.async { completion("设备身份已变化或本地存储未就绪，请重新选择设备") }; return
            }
            engine.prepareMany(peer: peerID, sources: sources) { error in DispatchQueue.main.async { completion(error) } }
        }
    }
    public func cancelPreparation(peerID: String, expectedPreparation: String) {
        queue.async { self.fileEngine?.cancelPreparation(peer: peerID, expected: expectedPreparation) }
    }
    public func exportMany(_ selections: [FileTaskSelection], parent: URL, completion: @escaping () -> Void) {
        queue.async {
            guard let engine = self.fileEngine else { DispatchQueue.main.async { completion() }; return }
            engine.exportMany(selections, parent: parent) { DispatchQueue.main.async { completion() } }
        }
    }
    public func cancelExport(exportID: String) { queue.async { self.fileEngine?.cancelExport(exportID) } }
    public func acceptFile(taskID: String, expectedAttempt: String) { queue.async { self.fileEngine?.accept(taskID, expectedAttempt: expectedAttempt) } }
    public func rejectFile(taskID: String, expectedAttempt: String) { queue.async { self.fileEngine?.reject(taskID, expectedAttempt: expectedAttempt) } }
    public func cancelFile(taskID: String, expectedAttempt: String) { queue.async { self.fileEngine?.cancel(taskID, expectedAttempt: expectedAttempt) } }
    public func retryFile(taskID: String, expectedAttempt: String) { queue.async { self.fileEngine?.retry(taskID, expectedAttempt: expectedAttempt) } }
    public func exportFile(taskID: String, expectedAttempt: String, destination: URL, replace: Bool, completion: @escaping (String?) -> Void) {
        queue.async {
            guard let engine = self.fileEngine else { DispatchQueue.main.async { completion("文件存储尚未就绪") }; return }
            engine.export(id: taskID, expectedAttempt: expectedAttempt, destination: destination, replace: replace) { error in DispatchQueue.main.async { completion(error) } }
        }
    }
    public func locateFile(taskID: String, expectedAttempt: String, completion: @escaping (URL?) -> Void) {
        queue.async {
            guard let engine = self.fileEngine else { DispatchQueue.main.async { completion(nil) }; return }
            engine.location(id: taskID, expectedAttempt: expectedAttempt) { url in DispatchQueue.main.async { completion(url) } }
        }
    }
    private func closeFileChannels(peerID: String? = nil, controlID: UUID? = nil) {
        for candidate in Array(channels.values) where candidate.isFileData {
            if (peerID != nil && candidate.filePeerID == peerID) || (controlID != nil && candidate.fileControlID == controlID) { candidate.close() }
        }
    }
    private func handleFileControl(_ channel: TLSChannel, _ message: [String: Any]) {
        guard let peer = channel.authenticatedPeer, !channel.isFileData else {
            fileError(channel, code: "FILE_INVALID", text: "文件能力仅对已认证控制会话开放", message: message, close: true); return
        }
        guard let engine = fileEngine else { fileError(channel, code: "FILE_IO", text: "本地文件存储不可用", message: message); return }
        if message["type"] as? String == "file.error", message["taskId"] == nil {
            channel.fileCapable = false; channel.groupCapable = false; closeFileChannels(controlID: channel.id); publish()
        }
        guard message["type"] as? String == "file.hello" || channel.fileCapable || message["type"] as? String == "file.error" else {
            fileError(channel, code: "FILE_UNSUPPORTED", text: "请先协商文件传输能力", message: message); return
        }
        guard fileControlPending[channel.id, default: 0] < 8 else {
            fileError(channel, code: "FILE_BUSY", text: "文件请求过多，请稍后再试", message: message); return
        }
        fileControlPending[channel.id, default: 0] += 1
        engine.control(peer: peer, channel: channel.id, message: message) { [weak self] in
            self?.queue.async {
                guard let self, let count = self.fileControlPending[channel.id] else { return }
                self.fileControlPending[channel.id] = max(0, count - 1)
            }
        }
    }
    private func bindFileChannel(_ channel: TLSChannel, _ message: [String: Any]) {
        guard let peerID = validIdentifier(message["clientId"]), let token = message["token"] as? String, validHex(token),
              message["serverId"] as? String == identity?.deviceID,
              let peer = peers.first(where: { $0.id == peerID }), !peer.paused,
              constantEqual(peer.tokenHash, digest(Data(token.utf8))),
              let control = channels.values.first(where: { $0.authenticatedPeer == peerID && !$0.closing && $0.fileCapable }),
              let id = fileID(message["taskId"]), let attempt = fileID(message["attemptId"]),
              let direction = message["direction"] as? String, ["upload", "download"].contains(direction),
              let engine = fileEngine, let serverID = identity?.deviceID else {
            fileError(channel, code: "FILE_INVALID", text: "数据通道身份、控制会话或任务绑定无效", message: message, close: true); return
        }
        // 数据连接仅挂靠当前控制会话，绝不设置 authenticatedPeer 或替换控制连接。
        channel.fileControlID = control.id; channel.filePeerID = peerID
        engine.bind(peer: peerID, control: control.id, channel: channel.id, server: serverID, id: id, attempt: attempt, direction: direction)
    }
    private func fileError(_ channel: TLSChannel, code: String, text: String, message: [String: Any], close: Bool = false) {
        var fields: [String: Any] = ["code": code, "message": text]
        if let id = fileID(message["taskId"]), let attempt = fileID(message["attemptId"]) { fields["taskId"] = id; fields["attemptId"] = attempt }
        channel.send(wire("file.error", fields), closeAfter: close)
    }
    #if DEBUG
    private func pollFileCommands() {
        guard let path = configuration.testFileCommand else { return }
        let commands = fileCommands.poll(path: path)
        guard !commands.isEmpty else { return }
        // 仅实际消费测试命令后更新回执，管理结果不能再依赖生产tick的全量刷新。
        defer { publish() }
        for command in commands {
            if command["action"] as? String=="renewTLS",configuration.clipboardPasteboard != nil {
                renewTLSListener();continue
            }
            if let action=command["action"] as? String,action.hasPrefix("media"),configuration.clipboardPasteboard != nil,let peer=validIdentifier(command["peerId"]),let stored=peers.first(where:{$0.id==peer}) {
                let gen=stored.clipboardTrustGeneration ?? "legacy"
                switch action {
                case "mediaScreenStart":media?.startScreen(peer:peer,generation:gen)
                case "mediaScreenStop":media?.stopScreen(peer:peer,generation:gen)
                case "mediaFilesRequest":media?.requestFiles(peer:peer,generation:gen)
                case "mediaFilesList":media?.listFiles(peer:peer,generation:gen,folderID:command["folderId"] as? String ?? "",offset:command["offset"] as? Int ?? 0,query:command["query"] as? String,sort:command["sort"] as? String)
                case "mediaFilesDownload":media?.downloadFiles(peer:peer,generation:gen,entryIDs:command["entryIDs"] as? [String] ?? [])
                case "mediaFilesRevoke":media?.revokeFiles(peer:peer,generation:gen)
                case "mediaFilesLeave":media?.leaveFiles(peer:peer,generation:gen)
                case "mediaAlbumRequest":media?.requestAlbum(peer:peer,generation:gen)
                case "mediaAlbumList":media?.listAlbum(peer:peer,generation:gen,offset:command["offset"] as? Int ?? 0,query:command["query"] as? String,sort:command["sort"] as? String)
                case "mediaAlbumDownload":media?.download(peer:peer,generation:gen,assets:command["assetIDs"] as? [String] ?? [])
                case "mediaAlbumRevoke":media?.revokeAlbum(peer:peer,generation:gen)
                case "mediaAlbumLeave":media?.leaveAlbum(peer:peer,generation:gen)
                default:break
                }
                continue
            }
            if let action = command["action"] as? String, action.hasPrefix("clip") {
                guard configuration.clipboardPasteboard != nil else { continue }
                let peer = validIdentifier(command["peerId"])
                switch action {
                case "clipPreferences":
                    if var value = clipboard?.preferences, let context = clipboard?.context {
                        if let enabled = clipboardBool(command["enabled"]) { value.enabled = enabled }
                        if let kinds = command["kinds"] as? [String] { value.kinds = kinds }
                        if let enabled = clipboardBool(command["autoApplyText"]) { value.autoApplyText = enabled }
                        if let enabled = clipboardBool(command["previewsEnabled"]) { value.previewsEnabled = enabled }
                        let error = clipboard?.savePreferences(value,expectedContext: command["context"] as? String ?? context)
                        debugManagement = ["commandId":command["commandId"] as? String ?? "","action":action,"error":error ?? ""]
                    }
                case "clipAllKeys":
                    let keys = clipboard?.allKeys(source: command["sourceDeviceId"] as? String ?? "", kind: command["kind"] as? String ?? "", query: command["query"] as? String ?? "") ?? []
                    debugManagement = ["commandId":command["commandId"] as? String ?? "","action":action,"keys":keys,"context":clipboard?.context ?? ""]
                case "clipQuery": clipboard?.query(source: command["sourceDeviceId"] as? String ?? "",kind: command["kind"] as? String ?? "",page: command["page"] as? Int ?? 0,query: command["query"] as? String ?? "")
                case "clipPreviews": clipboard?.requestPreviews(keys: command["keys"] as? [String] ?? [],context: command["context"] as? String ?? clipboard?.context ?? "")
                case "clipCancelPreviews": clipboard?.cancelPreviews(context: command["context"] as? String ?? clipboard?.context ?? "")
                case "clipClearPrivateImages":
                    let commandId=command["commandId"] as? String ?? ""
                    clipboard?.clearPrivateImages(context:command["context"] as? String ?? clipboard?.context ?? "") { [weak self] result in
                        self?.queue.async {
                            self?.debugManagement=["commandId":commandId,"action":action,"removed":result.removed,"keptActive":result.keptActive,"failed":result.failed];self?.publish()
                        }
                    }
                case "clipDeleteMany", "clipClearCache":
                    let context = command["context"] as? String ?? clipboard?.context ?? ""
                    let result = action == "clipDeleteMany" ? clipboard?.deleteMany(keys: command["keys"] as? [String] ?? [],context: context) : clipboard?.clearCache(previews: clipboardBool(command["previews"]) ?? false,sources: clipboardBool(command["sources"]) ?? false,context: context)
                    debugManagement = ["commandId":command["commandId"] as? String ?? "","action":action,"removed":result?.removed ?? 0,"keptActive":result?.keptActive ?? 0,"failed":result?.failed ?? 1]
                case "clipSettings":
                    if let peer, peers.contains(where: { $0.id == peer }), let auto = clipboardBool(command["autoSend"]), let receive = clipboardBool(command["receiveEnabled"]) {
                        if var value = clipboard?.preferences, let context = clipboard?.context { value.enabled = auto && receive; _ = clipboard?.savePreferences(value,expectedContext: context) }
                    }
                case "clipWrite": if let text = command["text"] as? String { clipboard?.debugWrite(text) }
                case "clipSend":
                    if let peer { clipboard?.manual(peer: peer, text: command["text"] as? String) }
                    debugManagement = ["commandId":command["id"] as? String ?? "","action":action]
                case "clipPublishPaths":
                    if let peer, let paths = command["paths"] as? [String] { clipboard?.debugPaths(peer: peer, paths: paths) }
                    debugManagement = ["commandId":command["id"] as? String ?? "","action":action]
                case "clipDownload": if let source = validIdentifier(command["sourceDeviceId"]), let id = command["recordId"] as? String { clipboard?.download(source: source, id: id) }
                case "clipCopyRecord": if let source = validIdentifier(command["sourceDeviceId"]), let id = command["recordId"] as? String { clipboard?.copyRecord(source: source, id: id) }
                case "clipCacheSweep": clipboard?.debugSweep()
                default: break
                }
                continue
            }
            switch command["action"] as? String {
            case "send":
                if let peer = validIdentifier(command["peerId"]), let path = command["path"] as? String,
                   path.hasPrefix("/"), !path.utf8.contains(0) { sendFile(source: URL(fileURLWithPath: path), peerID: peer) }
            case "sendMany":
                if let peer = validIdentifier(command["peerId"]), let paths = command["paths"] as? [String],
                   (1...GROUP_MAX_ROOTS).contains(paths.count), paths.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) {
                    sendMany(sources: paths.map { URL(fileURLWithPath: $0) }, peerID: peer)
                }
            case "fileHideHistory":
                if configuration.clipboardPasteboard != nil, let raw = command["tasks"] as? [[String: String]] {
                    let selections = raw.compactMap { value -> FileTaskSelection? in guard let id = fileID(value["id"]), let attempt = fileID(value["attemptId"]) else { return nil }; return FileTaskSelection(id: id,attemptId: attempt) }
                    fileEngine?.hideHistory(selections) { result in self.queue.async {
                        self.debugManagement = ["commandId":command["commandId"] as? String ?? "","action":"fileHideHistory","removed":result.removed,"keptActive":result.keptActive,"failed":result.failed]; self.publish()
                    } }
                }
            case "exportMany":
                if let ids = command["taskIds"] as? [String], !ids.isEmpty, ids.allSatisfy({ fileID($0) != nil }) {
                    let selections = ids.map { id in FileTaskSelection(id: id, attemptId: fileSnapshot.tasks.first(where: { $0.id == id })?.attemptId ?? "") }
                    fileEngine?.debugExportMany(selections, path: command["path"] as? String)
                }
            case "cancelExport": if let id = fileID(command["exportId"]) { fileEngine?.cancelExport(id) }
            case "accept":
                if let id = fileID(command["taskId"]), let view = fileSnapshot.tasks.first(where: { $0.id == id }) {
                    fileEngine?.accept(id, expectedAttempt: view.attemptId)
                }
            case "reject":
                if let id = fileID(command["taskId"]), let view = fileSnapshot.tasks.first(where: { $0.id == id }) {
                    fileEngine?.reject(id, expectedAttempt: view.attemptId)
                }
            case "cancel":
                if let id = fileID(command["taskId"]), let view = fileSnapshot.tasks.first(where: { $0.id == id }) {
                    fileEngine?.cancel(id, expectedAttempt: view.attemptId)
                }
            case "retry":
                if let id = fileID(command["taskId"]), let view = fileSnapshot.tasks.first(where: { $0.id == id }) {
                    fileEngine?.retry(id, expectedAttempt: view.attemptId)
                }
            default: break
            }
        }
    }
    #endif
    private func beginPairing(_ channel: TLSChannel, _ message: [String: Any]) {
        guard channel.authenticatedPeer == nil,
              let requestID = validIdentifier(message["requestId"]), let clientID = validIdentifier(message["clientId"]),
              let clientName = validIdentifier(message["clientName"]), let pairingID = validIdentifier(message["pairingId"]),
              let method = message["method"] as? String, ["qr", "code"].contains(method),
              let proof = message["proof"] as? String, proof.utf8.count <= 128 else { fail(channel, "INVALID_MESSAGE", "配对信息不完整"); return }
        guard clientID != identity?.deviceID else { fail(channel, "INVALID_MESSAGE", "手机标识不能与本机身份相同"); return }
        guard let session, Date() < session.expires, pairingID == session.id else { fail(channel, "PAIRING_EXPIRED", "配对码已过期或已刷新", pairingID: pairingID); return }
        guard session.mistakes < 5 else { fail(channel, "PAIRING_RATE_LIMITED", "错误次数过多，请在 Mac 刷新配对码", pairingID: pairingID); return }
        guard pending == nil else { fail(channel, "PAIRING_BUSY", "另一台设备正在等待配对确认", pairingID: pairingID); return }
        let expected = method == "qr" ? session.proof : session.code
        guard constantEqual(proof, expected) else {
            self.session?.mistakes += 1
            fail(channel, (self.session?.mistakes ?? 0) >= 5 ? "PAIRING_RATE_LIMITED" : "PAIRING_MISMATCH", "配对证明不匹配，请重新输入或扫码", pairingID: pairingID); return
        }
        guard let identity else { return }
        do {
            let nonce = hex(try secureBytes(32))
            let material = "\(session.id)|\(identity.deviceID)|\(clientID)|\(nonce)"
            let value = SHA256.hash(data: Data(material.utf8)).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let code = String(format: "%06u", value % 1_000_000)
            pending = PendingPairing(sessionID: session.id, channelID: channel.id, clientID: clientID, clientName: clientName, verificationCode: code)
            channel.send(wire("pair.challenge", ["requestId": requestID, "pairingId": session.id, "serverId": identity.deviceID, "nonce": nonce, "verificationCode": code, "expiresAt": milliseconds(session.expires)]))
            #if DEBUG
            if configuration.autoApprove { pending?.macConfirmed = true }
            #endif
        } catch { fail(channel, "AUTH_FAILED", "无法生成安全配对请求") }
    }
    private func finishPairingIfConfirmed() {
        guard let request = pending, let channel = channels[request.channelID], !channel.closing, let identity,
              let session, session.id == request.sessionID, session.expires > Date() else { return }
        guard request.macConfirmed && request.phoneConfirmed else {
            channel.send(wire("pair.waiting", ["pairingId": request.sessionID])); return
        }
        do {
            let token = hex(try secureBytes(32))
            let peer = StoredPeer(id: request.clientID, name: request.clientName, clipboardTrustGeneration: hex(try secureBytes(16)), tokenHash: digest(Data(token.utf8)), paused: false, lastSeen: Date())
            var revised = peers.filter { $0.id != peer.id }; revised.append(peer)
            // 先持久化再发完成消息；Keychain 写入失败时绝不显示已保存信任。
            try clipboard?.resetTrust(peer.id)
            try savePeers(revised)
            // 同ID重新配对也是新信任域；取消旧准备与未完成发送，不能把旧面板选中的内容交给新身份。
            fileEngine?.revoke(peer: peer.id)
            authenticate(channel, as: peer.id)
            pending = nil
            channel.send(wire("pair.complete", ["pairingId": request.sessionID, "serverId": identity.deviceID, "clientId": peer.id, "token": token, "clipboardProtocol": clipboardProtocol,"deviceProtocol":"xq-device/1"]))
            rotateSession()
        } catch { pending = nil; issue = error.localizedDescription; fail(channel, "AUTH_FAILED", "安全存储失败，本次信任未保存") }
    }
    private func resume(_ channel: TLSChannel, _ message: [String: Any]) {
        guard channel.authenticatedPeer == nil, pending?.channelID != channel.id,
              let clientID = validIdentifier(message["clientId"]), let token = message["token"] as? String, validHex(token),
              let index = peers.firstIndex(where: { $0.id == clientID }), constantEqual(peers[index].tokenHash, digest(Data(token.utf8))) else { fail(channel, "AUTH_FAILED", "设备凭据无效，请重新配对"); return }
        let manual = message["manual"] as? Bool == true
        guard !peers[index].paused || manual else { fail(channel, "USER_PAUSED", "连接已由用户暂停，请手动重新连接"); return }
        var revised = peers; revised[index].paused = false; revised[index].lastSeen = Date()
        do { try savePeers(revised) } catch { issue = error.localizedDescription; fail(channel, "AUTH_FAILED", "无法保存设备连接状态"); return }
        authenticate(channel, as: clientID)
        channel.send(wire("session.ready", ["serverId": identity!.deviceID, "clientId": clientID, "clipboardProtocol": clipboardProtocol,"deviceProtocol":"xq-device/1"]))
    }
    private func authenticate(_ channel: TLSChannel, as clientID: String) {
        for old in Array(channels.values) where old.id != channel.id && old.authenticatedPeer == clientID { old.close() }
        channel.authenticatedPeer = clientID; channel.lastPong = Date(); channel.lastPing = Date()
        bluetoothWake?.lanAuthenticated()
        clipboard?.authenticated(peer: clientID, channel: channel.id)
        if let peer=peers.first(where:{$0.id==clientID}){media?.authenticated(peer:clientID,control:channel.id,generation:peer.clipboardTrustGeneration ?? "legacy")}
    }
    private func fail(_ channel: TLSChannel, _ code: String, _ text: String, pairingID: String? = nil) {
        var fields: [String: Any] = ["code": code, "message": text]
        if let pairingID { fields["pairingId"] = pairingID }
        channel.send(wire("error", fields), closeAfter: true)
    }
    /// 轮换只重建监听，不撤销已认证设备或文件/媒体通道；失败后一分钟再试。
    private func renewTLSListener() {
        tlsRenewalPending=true
        nextTLSRenewalAttempt=Date().addingTimeInterval(60)
        do { try startListener() } catch { issue="TLS证书更新失败，将自动重试：\(error.localizedDescription)";publish() }
    }
    private func tick() {
        let now = Date()
        if let session, now >= session.expires { rotateSession() }
        if (identity?.needsTLSRenewal == true || tlsRenewalPending),now>=nextTLSRenewalAttempt {
            renewTLSListener()
        }
        fileEngine?.tick()
        clipboard?.tick()
        media?.tick()
        #if DEBUG
        pollFileCommands()
        #endif
        for channel in Array(channels.values) where !channel.closing {
            if channel.isMediaData {continue}
            if channel.isFileData {
                if channel.fileControlID == nil && now.timeIntervalSince(channel.createdAt) >= 15 { channel.close() }
                continue
            }
            if channel.authenticatedPeer != nil {
                // 控制通道统一由Mac发起低频心跳；业务事件仍立即发送，不等待心跳窗口。
                if now.timeIntervalSince(channel.lastPong) >= 60 { channel.close(); continue }
                if now.timeIntervalSince(channel.lastPing) >= 20, channel.pingRequest == nil {
                    let request = UUID().uuidString.lowercased(); channel.pingRequest = request; channel.lastPing = now
                    channel.send(wire("ping", ["requestId": request]))
                }
            } else if pending?.channelID != channel.id && now.timeIntervalSince(channel.createdAt) >= 15 { channel.close() }
        }
    }
    private func publish() {
        var snapshot = ServerSnapshot()
        snapshot.bluetoothWakeStatus = bluetoothWake?.status ?? (configuration.bluetoothWakeEnabled ? "蓝牙辅助待启动" : "蓝牙辅助未启用")
        snapshot.bluetoothWakeAuthorization = bluetoothWake?.authorization ?? BluetoothWakeCoordinator.currentAuthorization
        snapshot.bluetoothWakeHardware = bluetoothWake?.hardware ?? (snapshot.bluetoothWakeAuthorization == .allowed ? .unknown : .unavailable)
        snapshot.bluetoothWakeAuthenticatedPeers = bluetoothWake?.authenticatedPeers ?? 0
        snapshot.files = fileSnapshot
        snapshot.media = media?.views ?? []
        snapshot.clipboardPeers = clipboard?.views(peers.map(\.id)) ?? []
        snapshot.clipboardRecords = clipboard?.recordViews() ?? []
        snapshot.clipboardPage = clipboard?.pageViews() ?? []
        snapshot.clipboardQueryID = clipboard?.queryID ?? ""
        snapshot.clipboardQueryCount = clipboard?.queryCount ?? 0
        snapshot.clipboardCache = clipboard?.cacheView() ?? ClipboardCacheView()
        snapshot.clipboardNoticeRevision = clipboard?.noticeRevision ?? 0
        snapshot.clipboardNoticeIsReceipt = clipboard?.noticeIsReceipt ?? false
        snapshot.clipboardNotice = clipboard?.notice
        snapshot.clipboardPreferences = clipboard?.preferences ?? .disabled
        snapshot.clipboardPreferencesError = clipboard?.preferencesError
        snapshot.clipboardContext = clipboard?.context ?? ""
        snapshot.ready = ready; snapshot.error = issue; snapshot.host = lanAddress(addresses)
        snapshot.port = configuration.port; snapshot.discoveryPort = configuration.discoveryPort; snapshot.deviceName = name
        snapshot.deviceID = identity?.deviceID ?? ""; snapshot.fingerprint = identity?.fingerprint ?? ""
        snapshot.pairingCode = session?.code ?? ""; snapshot.expiresAt = session?.expires ?? Date()
        if let pending {
            snapshot.pending = PendingView(id: pending.sessionID, requestID: pending.channelID.uuidString, name: pending.clientName, verificationCode: pending.verificationCode, phoneConfirmed: pending.phoneConfirmed, macConfirmed: pending.macConfirmed)
        }
        snapshot.peers = peers.map { peer in
            let controls = channels.values.filter { $0.authenticatedPeer == peer.id && !$0.closing && !$0.isFileData && !$0.isMediaData }
            let hosts = Set(controls.compactMap { channel -> String? in
                guard case .hostPort(let host, _) = channel.connection.currentPath?.remoteEndpoint ?? channel.connection.endpoint else { return nil }
                return String(describing: host)
            })
            // 同一身份若存在不同活跃端点，保留未知，不能任取一个地址匹配控制目标。
            return PeerView(id: peer.id, name: peer.name, connected: !controls.isEmpty, paused: peer.paused, lastSeen: peer.lastSeen,
                     fileCapable: channels.values.contains { $0.authenticatedPeer == peer.id && !$0.closing && $0.fileCapable },
                     groupCapable: channels.values.contains { $0.authenticatedPeer == peer.id && !$0.closing && $0.fileCapable && $0.groupCapable }, trustGeneration: peer.clipboardTrustGeneration ?? "legacy", remoteHost: hosts.count == 1 ? hosts.first : nil)
        }.sorted { $0.lastSeen > $1.lastSeen }
        if var advertisement = advertisement(), let session {
            advertisement["token"] = session.proof
            if let data = try? JSONSerialization.data(withJSONObject: advertisement, options: [.sortedKeys, .withoutEscapingSlashes]), data.count + 4 <= 4096 {
                snapshot.qr = "XQ1:" + String(decoding: data, as: UTF8.self)
                #if DEBUG
                writeTestSession(snapshot, advertisement: advertisement)
                #endif
            }
        }
        if issue != nil { snapshot.status = "连接服务需要处理" }
        else if !ready { snapshot.status = "正在启动安全连接服务…" }
        else if snapshot.peers.contains(where: { $0.connected }) { snapshot.status = "设备已连接" }
        else { snapshot.status = "等待手机连接" }
        if let callback { DispatchQueue.main.async { callback(snapshot) } }
    }
    #if DEBUG
    private var lastFixtureDigest = ""
    private func filesFixture(_ view:DeviceMediaView)->[String:Any] {
        ["filesCapable":view.filesCapable,"filesGrantId":view.filesGrantId,"filesState":view.filesState,"filesMessage":view.filesMessage,"filesRootName":view.filesRootName,"filesFolderId":view.filesFolderId,"filesOffset":view.filesOffset,"filesTotal":view.filesTotal,"filesSkippedCount":view.filesSkippedCount,"filesDownloading":view.filesDownloading,"filesQueuedDownloads":view.filesQueuedDownloads,
         "filesEntries":view.filesEntries.map{["entryId":$0.id,"name":$0.name,"isDirectory":$0.isDirectory,"size":$0.size,"modifiedAt":$0.modifiedAt,"downloadable":$0.downloadable] as [String:Any]},"filesBreadcrumbs":view.filesBreadcrumbs.map{["folderId":$0.id,"name":$0.name]}]
    }
    private func writeTestSession(_ snapshot: ServerSnapshot, advertisement: [String: Any]) {
        guard let path = configuration.testSessionFile else { return }
        do {
            let taskData = try JSONEncoder().encode(snapshot.files.tasks)
            let taskViews = try JSONSerialization.jsonObject(with: taskData)
            let peerViews = snapshot.peers.map { ["id": $0.id, "name": $0.name, "connected": $0.connected, "paused": $0.paused, "fileCapable": $0.fileCapable, "groupCapable": $0.groupCapable] as [String: Any] }
            let exportStatus: [String: Any]
            if let status = snapshot.files.batchExport {
                exportStatus = ["id": status.id, "state": status.state, "total": status.total, "completed": status.completed,
                                "failed": status.failed, "cancelled": status.cancelled, "message": status.message]
            } else { exportStatus = ["id": "", "state": "idle", "total": 0, "completed": 0, "failed": 0, "cancelled": false, "message": ""] }
            let fixture: [String: Any] = ["qr": snapshot.qr, "pairingCode": snapshot.pairingCode, "advertisement": advertisement, "fingerprint": snapshot.fingerprint, "tlsPort": configuration.port, "discoveryPort": configuration.discoveryPort, "ready": snapshot.ready,
                "tasks": taskViews, "peers": peerViews, "fileError": snapshot.files.error ?? "", "exportStatus": exportStatus, "clipboardPeers": snapshot.clipboardPeers.map(\.metadata), "clipboardRecords": snapshot.clipboardRecords.map(\.metadata), "clipboardCache": snapshot.clipboardCache.metadata,"clipboardNotice":snapshot.clipboardNotice ?? "",
                "clipboardDeliveryScans":clipboard?.deliveryScanCount ?? 0,
                "clipboardPreferences": ["version":snapshot.clipboardPreferences.version,"enabled":snapshot.clipboardPreferences.enabled,"kinds":snapshot.clipboardPreferences.kinds,"autoApplyText":snapshot.clipboardPreferences.autoApplyText,"previewsEnabled":snapshot.clipboardPreferences.previewsEnabled],
                "media":snapshot.media.map { ["peerId":$0.peerId,"capable":$0.capable,"screenCapable":$0.screenCapable,"albumCapable":$0.albumCapable,"screenId":$0.screenId,"screenState":$0.screenState,"screenMessage":$0.screenMessage,"decodedFrames":$0.decodedFrames,"grantId":$0.grantId,"albumState":$0.albumState,"albumTotal":$0.albumTotal,"albumOffset":$0.albumOffset,"albumMessage":$0.albumMessage,"browserQueryCapable":$0.browserQueryCapable,"albumQuery":$0.albumQuery,"albumSort":$0.albumSort,"filesQuery":$0.filesQuery,"filesSort":$0.filesSort,"downloading":$0.downloading,"queuedDownloads":$0.queuedDownloads,"assets":$0.assets.map { ["assetId":$0.id,"name":$0.name,"size":$0.size,"width":$0.width,"height":$0.height,"previewBytes":$0.preview?.count ?? 0] as [String:Any] }] .merging(self.filesFixture($0)){_,new in new} as [String:Any] },"clipboardContext":snapshot.clipboardContext,"clipboardPreferencesError":snapshot.clipboardPreferencesError ?? "","clipboardQueryID":snapshot.clipboardQueryID,"clipboardQueryCount":snapshot.clipboardQueryCount,"clipboardPageKeys":snapshot.clipboardPage.map(\.key),"debugManagement":debugManagement]
            let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
            let contentDigest = digest(data); guard contentDigest != lastFixtureDigest else { return }
            // 同目录0600临时文件+原子替换，避免任务高频更新时读取到截断JSON；不跟随符号链接。
            let temporary = path + ".tmp-" + UUID().uuidString
            let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CoreFailure("无法写入调试会话文件") }
            defer { close(fd); _ = unlink(temporary) }; guard fchmod(fd, 0o600) == 0 else { throw CoreFailure("无法保护调试会话文件") }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < data.count {
                    let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                    guard n > 0 else { throw CoreFailure("无法完成调试会话文件写入") }; offset += n
                }
            }
            guard rename(temporary, path) == 0 else { throw CoreFailure("无法替换调试会话文件") }
            lastFixtureDigest = contentDigest
        } catch { issue = error.localizedDescription }
    }
    #endif
}
