import Foundation
import AppKit
import SwiftUI
import XuQiaoCore

@main
struct XuQiaoMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let debugFlags = ["--headless", "--auto-approve", "--test-session-file", "--port", "--discovery-port", "--keychain-suffix", "--file-store-directory", "--auto-accept-files", "--test-file-command", "--clipboard-pasteboard", "--clipboard-cache-ttl-seconds", "--clipboard-cache-max-bytes"]
        #if DEBUG
        if args.contains("--headless") {
            do {
                var config = ServerConfiguration()
                config.autoApprove = args.contains("--auto-approve")
                config.autoAcceptFiles = args.contains("--auto-accept-files")
                var i = 0
                while i < args.count {
                    let flag = args[i]
                    if flag == "--headless" || flag == "--auto-approve" || flag == "--auto-accept-files" { i += 1; continue }
                    guard debugFlags.contains(flag), i + 1 < args.count else { throw CoreFailure("调试参数无效") }
                    let value = args[i + 1]; i += 2
                    switch flag {
                    case "--test-session-file": config.testSessionFile = value
                    case "--file-store-directory": config.fileStoreDirectory = value
                    case "--test-file-command": config.testFileCommand = value
                    case "--clipboard-cache-ttl-seconds":
                        guard let number = Int64(value), (1...2_592_000).contains(number) else { throw CoreFailure("缓存TTL参数无效") }; config.clipboardCacheTTL = number
                    case "--clipboard-cache-max-bytes":
                        guard let number = Int64(value), (1...1_073_741_824).contains(number) else { throw CoreFailure("缓存容量参数无效") }; config.clipboardCacheMaximum = number
                    case "--clipboard-pasteboard":
                        guard ClipboardTestConfiguration.isValidName(value) else { throw CoreFailure("只允许隔离命名剪贴板，禁止系统板") }
                        config.clipboardPasteboard = value
                    case "--keychain-suffix":
                        guard value.count <= 64, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { throw CoreFailure("隔离钥匙串名称无效") }
                        config.keychainSuffix = value
                    case "--port": guard let port = UInt16(value), port > 1024 else { throw CoreFailure("TLS 端口无效") }; config.port = port
                    case "--discovery-port": guard let port = UInt16(value), port > 1024 else { throw CoreFailure("发现端口无效") }; config.discoveryPort = port
                    default: throw CoreFailure("调试参数无效")
                    }
                }
                if config.fileStoreDirectory != nil || config.testSessionFile != nil || config.autoAcceptFiles || config.testFileCommand != nil || config.clipboardPasteboard != nil {
                    guard config.fileStoreDirectory != nil, !config.keychainSuffix.isEmpty, config.clipboardPasteboard != nil else { throw CoreFailure("文件自测必须指定独立目录、钥匙串后缀和隔离命名剪贴板") }
                }
                if config.clipboardCacheTTL != nil || config.clipboardCacheMaximum != nil {
                    guard config.clipboardPasteboard != nil, config.fileStoreDirectory != nil, !config.keychainSuffix.isEmpty else { throw CoreFailure("缓存自测必须指定隔离命名板、目录和钥匙串") }
                }
                let server = PairingServer(configuration: config)
                var announced = false
                server.start { snapshot in
                    if let error = snapshot.error { FileHandle.standardError.write(Data((error + "\n").utf8)); if !announced { exit(1) } }
                    if snapshot.ready && !announced { print("续桥 DEBUG 安全连接服务已就绪"); fflush(stdout); announced = true }
                }
                withExtendedLifetime(server) { RunLoop.main.run() }
                return
            } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(2) }
        }
        if args.contains(where: { debugFlags.contains($0) }) { FileHandle.standardError.write(Data("调试参数仅可在 --headless 模式使用\n".utf8)); exit(2) }
        #else
        if args.contains(where: { debugFlags.contains($0) }) { FileHandle.standardError.write(Data("发布构建不支持调试连接入口\n".utf8)); exit(2) }
        #endif
        XuQiaoApplication.main()
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot = ServerSnapshot()
    @Published var selection: Page = .connection
    @Published private(set) var fileNoticeRevision: UInt64 = 0
    @Published var fileNotice: String? {
        didSet {
            fileNoticeRevision &+= 1
            clipboardOperationNotice = fileNotice
            transferOperationNotice = fileNotice
        }
    }
    // 反馈属于整个主窗生命周期；切页不会丢失错误，关闭后同一revision不会复活。
    @Published var clipboardOperationNotice: String? { didSet { clipboardOperationNoticeID = UUID() } }
    @Published private(set) var clipboardOperationNoticeID = UUID()
    private var lastCoreClipboardNoticeID: UUID?
    @Published var transferOperationNotice: String? { didSet { transferOperationNoticeID = UUID() } }
    @Published private(set) var transferOperationNoticeID = UUID()
    @Published private(set) var hiddenBatchExportID: String?
    private var batchExportFeedbackKey: String?
    private var batchExportFeedbackTask: Task<Void, Never>?
    private func updateBatchExportFeedback(_ status: BatchExportView?) {
        let key = status.map { $0.id + "|" + $0.state }
        guard key != batchExportFeedbackKey else { return }
        batchExportFeedbackKey = key
        batchExportFeedbackTask?.cancel()
        guard let status, batchExportSucceeded(status) else { return }
        let id = status.id
        // 只隐藏界面反馈，保留Core回执；切页和重复快照不重启倒计时。
        batchExportFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self,
                  let current = self.snapshot.files.batchExport,
                  current.id == id, batchExportSucceeded(current) else { return }
            self.hiddenBatchExportID = id
        }
    }
    func dismissBatchExport(_ id: String) {
        guard let current = snapshot.files.batchExport, current.id == id, current.state != "exporting" else { return }
        batchExportFeedbackTask?.cancel()
        hiddenBatchExportID = id
    }
    private var receivedOperationSnapshot = false
    @Published var confirmIncomingFiles = UserDefaults.standard.bool(forKey: DesktopPreferences.confirmIncomingFilesKey) {
        didSet {
            UserDefaults.standard.set(confirmIncomingFiles, forKey: DesktopPreferences.confirmIncomingFilesKey)
            if confirmIncomingFiles != oldValue { handledFileOffers.removeAll(); refreshFileReception() }
        }
    }
    @Published var fileReceivePrompt: IncomingFilePrompt?
    private var fileReceiveSheetPresented = false
    private var handledFileOffers = Set<String>()
    func fileReceiveSheetDidAppear() { fileReceiveSheetPresented = true }
    func fileReceiveSheetDidDismiss() { fileReceiveSheetPresented = false; refreshFileReception() }
    func refreshFileReception() {
        let requests = snapshot.files.pendingReceives.compactMap { task -> IncomingFilePrompt? in
            guard task.isFileTransferRecord, task.direction == .incoming, task.state == .awaitingUser, task.mediaRequestId == nil,
                  let peer = snapshot.peers.first(where: { $0.id == task.peerId && $0.connected && $0.fileCapable && (task.kind != "group" || $0.groupCapable) && !$0.paused && !$0.trustGeneration.isEmpty }) else { return nil }
            return IncomingFilePrompt(task: task, peer: peer)
        }
        let currentKeys = Set(requests.map(\.id))
        handledFileOffers.formIntersection(currentKeys)
        if let prompt = fileReceivePrompt, !confirmIncomingFiles || !currentKeys.contains(prompt.id) { fileReceivePrompt = nil }
        if !confirmIncomingFiles {
            for request in requests where !handledFileOffers.contains(request.id) {
                handledFileOffers.insert(request.id)
                respondToFileOffer(request, accept: true)
            }
            return
        }
        // 结果由服务事件推进；不轮询历史，也不抢占配对、文件选择或其它已打开的sheet。
        guard fileReceivePrompt == nil, !fileReceiveSheetPresented, pairingPrompt == nil, !pairingExpanded,
              !pairingSheetPresented, sendFilesPeer == nil, !NSApp.windows.contains(where: { $0.isSheet && $0.isVisible }),
              let request = requests.first(where: { !handledFileOffers.contains($0.id) }) else { return }
        handledFileOffers.insert(request.id)
        fileReceivePrompt = request
    }
    func respondToFileOffer(_ prompt: IncomingFilePrompt, accept: Bool) {
        guard snapshot.files.pendingReceives.contains(where: { $0.id == prompt.task.id && $0.attemptId == prompt.task.attemptId && $0.peerId == prompt.peer.id }),
              snapshot.peers.contains(where: { $0.id == prompt.peer.id && $0.trustGeneration == prompt.peer.trustGeneration && $0.connected && !$0.paused }) else { fileReceivePrompt = nil; return }
        server.respondToFileOffer(taskID: prompt.task.id, expectedAttempt: prompt.task.attemptId, peerID: prompt.peer.id, expectedGeneration: prompt.peer.trustGeneration, accept: accept)
        if fileReceivePrompt?.id == prompt.id { fileReceivePrompt = nil }
    }
    @Published var clipboardSource = UserDefaults.standard.string(forKey: "clipboard.source") ?? ""
    @Published var clipboardSourceName = ""
    @Published var filePeer = UserDefaults.standard.string(forKey: "files.peer") ?? ""
    @Published var pairingExpanded = false
    @Published var pairingPrompt: PendingView?
    // isPresented 在退出动画开始时就变 false；实际占用窗口直到 onDismiss 才解除。
    private var pairingSheetPresented = false
    private var promptedPairingRequestID: String?
    @Published var sendFilesPeer: PeerView?
    private var mediaWindows: [String:DeviceMediaWindowController] = [:]
    private var mediaWindowGenerations: [String:String] = [:]
    private var transferImageWindow: DeviceMediaWindowController?

    func showTransferImage(_ task: FileTaskView) {
        guard snapshot.files.tasks.contains(where: { $0.id == task.id && $0.attemptId == task.attemptId && $0.isFileTransferRecord }) else { return }
        // 一次只保留一张大图；换任务时释放旧窗口、解码图及缩放状态。
        transferImageWindow?.close()
        let page = GroupDetailsSheet(id: task.id, attempt: task.attemptId, onClose: { [weak self] in self?.transferImageWindow?.close() }).environmentObject(self)
        let controller = DeviceMediaWindowController(title: "图片预览 · " + task.name, size: NSSize(width: 980, height: 720), minimumContentSize: NSSize(width: 640, height: 480), view: AnyView(page)) { [weak self] in
            self?.transferImageWindow = nil
        }
        transferImageWindow = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }

    private var debugControlWindow: DeviceMediaWindowController?
    private var debugControlService: DebugControlService?
    func showDebugControl(_ peer: PeerView) {
        // 点击时复核最新连接与信任代际，不能让旧卡片或其他在线设备替离线卡片放行。
        guard let current = snapshot.peers.first(where: { $0.id == peer.id && $0.trustGeneration == peer.trustGeneration && $0.connected }) else { return }
        if let controller = debugControlWindow {
            debugControlService?.updatePeers(snapshot.peers)
            debugControlService?.bind(current)
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return
        }
        let service = DebugControlService()
        service.updatePeers(snapshot.peers)
        service.bind(current)
        let controller = DeviceMediaWindowController(title: "控制手机", size: NSSize(width: 430, height: 860), minimumContentSize: NSSize(width: 340, height: 500), view: AnyView(DebugControlPage(service: service))) { [weak self] in
            service.close(); self?.debugControlWindow = nil; self?.debugControlService = nil
        }
        debugControlService = service; debugControlWindow = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }

    func showScreen(_ peer:PeerView) {
        guard current(peer),peer.connected else{return};let key="screen:"+peer.id
        if let controller=mediaWindows[key]{controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil);return}
        let page=PhoneScreenPage(peer:peer,hub:server.screenImages).environmentObject(self)
        let controller=DeviceMediaWindowController(title:"手机投屏 · "+deviceLabel(peer.name, id: peer.id),size:NSSize(width:470,height:820),view:AnyView(page)){[weak self] in self?.server.stopScreen(peerID:peer.id,expectedGeneration:peer.trustGeneration);self?.mediaWindows.removeValue(forKey:key);self?.mediaWindowGenerations.removeValue(forKey:key)}
        mediaWindowGenerations[key]=peer.trustGeneration;mediaWindows[key]=controller;controller.showWindow(nil);server.requestScreen(peerID:peer.id,expectedGeneration:peer.trustGeneration)
    }
    func showAlbum(_ peer:PeerView) { showLANBrowser(peer,album:true) }
    func showFiles(_ peer:PeerView) { showLANBrowser(peer,album:false) }
    private func showLANBrowser(_ peer:PeerView,album:Bool) {
        guard let current=snapshot.peers.first(where:{$0.id==peer.id && $0.trustGeneration==peer.trustGeneration && $0.connected}) else{return}
        let key=(album ? "album:":"files:")+current.id
        if let controller=mediaWindows[key],mediaWindowGenerations[key]==current.trustGeneration {controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil);return}
        let page:AnyView = album ? AnyView(PhoneAlbumPage(peer:current).environmentObject(self)):AnyView(PhoneFilesPage(peer:current).environmentObject(self))
        let controller=DeviceMediaWindowController(title:(album ? "手机相册 · ":"手机文件 · ")+deviceLabel(current.name, id: current.id),size:NSSize(width:1000,height:740),minimumContentSize:NSSize(width:740,height:520),view:page){[weak self] in
            if album {self?.server.leaveAlbum(peerID:current.id,expectedGeneration:current.trustGeneration)} else {self?.server.leaveFiles(peerID:current.id,expectedGeneration:current.trustGeneration)}
            self?.mediaWindows.removeValue(forKey:key);self?.mediaWindowGenerations.removeValue(forKey:key)
        }
        mediaWindowGenerations[key]=current.trustGeneration;mediaWindows[key]=controller;controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
    }
    func showClipboard(_ peer: PeerView) {
        clipboardSource = peer.id; clipboardSourceName = peer.name; selection = .clipboard
    }
    func showTransfers(_ peer: PeerView) { filePeer = peer.id; selection = .files }
    func showPairing() {
        selection = .connection
        guard snapshot.pending == nil, !pairingSheetPresented, !pairingExpanded else { return }
        pairingExpanded = true
    }
    func pairingSheetDidAppear() { pairingSheetPresented = true }
    func pairingSheetDidDismiss() {
        pairingSheetPresented = false
        presentPairingPromptIfNeeded()
    }
    func presentPairingPromptIfNeeded() {
        guard !pairingExpanded, !pairingSheetPresented,
              let pending = snapshot.pending, !pending.macConfirmed, snapshot.expiresAt > Date(),
              promptedPairingRequestID != pending.requestID else { return }
        promptedPairingRequestID = pending.requestID
        pairingPrompt = pending
    }
    func current(_ peer: PeerView) -> Bool {
        snapshot.peers.contains { $0.id == peer.id && $0.trustGeneration == peer.trustGeneration }
    }
    let server: PairingServer = {
        var configuration = ServerConfiguration()
        configuration.bluetoothWakeEnabled = true
        return PairingServer(configuration: configuration)
    }()
    init() {
        server.start { [weak self] snapshot in
            guard let self else{return}
            // 同ID重新配对是新信任域，旧授权窗口必须先关闭，不能显示新设备的媒体。
            for (key,generation) in Array(self.mediaWindowGenerations) {
                let peer=String(key.split(separator:":",maxSplits:1)[1])
                if !snapshot.peers.contains(where:{$0.id==peer && $0.trustGeneration==generation}) {self.mediaWindows[key]?.close();self.mediaWindows.removeValue(forKey:key);self.mediaWindowGenerations.removeValue(forKey:key)}
            }
            let newPending = snapshot.pending != nil && snapshot.pending?.requestID != self.snapshot.pending?.requestID
            if newPending {
                self.selection = .connection
                self.pairingExpanded = false
                self.pairingPrompt = nil
            } else if snapshot.pending == nil || snapshot.pending?.macConfirmed == true {
                self.pairingPrompt = nil
            }
            // 在页面不在场时也消费服务事件；按revision而非文字判断，同值新错误仍替换。
            if !self.receivedOperationSnapshot || snapshot.clipboardNoticeRevision != self.snapshot.clipboardNoticeRevision {
                // 本机文件操作或用户关闭提示后，迟到回执不能夺回显示权；新操作仍正常显示。
                if clipboardNoticeCanUpdate(isReceipt: snapshot.clipboardNoticeIsReceipt, lastCoreNoticeID: self.lastCoreClipboardNoticeID, displayedNoticeID: self.clipboardOperationNoticeID) {
                    self.clipboardOperationNotice = snapshot.clipboardNotice
                    self.lastCoreClipboardNoticeID = self.clipboardOperationNoticeID
                }
            }
            if !self.receivedOperationSnapshot || snapshot.files.noticeRevision != self.snapshot.files.noticeRevision {
                if self.receivedOperationSnapshot || snapshot.files.error != nil {
                    self.clipboardOperationNotice = snapshot.files.error
                }
                self.transferOperationNotice = snapshot.files.error
            }
            self.receivedOperationSnapshot = true
            self.updateBatchExportFeedback(snapshot.files.batchExport)
            self.snapshot=snapshot
            self.debugControlService?.updatePeers(snapshot.peers)
            // 面板仍在退出动画中时暂不登记已提示；onDismiss 按届时当前请求重新核对。
            // A 取消后 B 在动画期间到来，也只会展示 B，取消/过期请求不会复活。
            self.presentPairingPromptIfNeeded()
            self.refreshFileReception()
        }
    }
    @Published private(set) var choosingFile = false
    @Published private var pendingFilePreparations = Set<String>()
    func canChooseFile(peerID: String) -> Bool {
        !choosingFile && !pendingFilePreparations.contains(peerID) && snapshot.files.canPrepareSend(peerID: peerID)
    }
    func chooseFile(peerID: String, allowGroups: Bool = false, expectedGeneration: String) {
        guard snapshot.peers.contains(where: { $0.id == peerID && $0.trustGeneration == expectedGeneration }) else { fileNotice = "设备信任已更新，请重新选择"; return }
        guard canChooseFile(peerID: peerID) else { fileNotice = "正在选择或准备文件，或普通任务已达50项"; return }
        choosingFile = true
        let panel = NSOpenPanel(); panel.title = allowGroups ? "选择文件或文件夹（最多100项）" : "选择要发送的文件"
        panel.canChooseFiles = true; panel.canChooseDirectories = allowGroups; panel.allowsMultipleSelection = allowGroups; panel.resolvesAliases = false
        panel.begin { [weak self] response in
            guard let self else { return }
            self.choosingFile = false
            guard response == .OK, !panel.urls.isEmpty else { return }
            // 文件面板打开期间设备可能被移除并重新配对，旧窗口不能沿用新的授权。
            guard self.snapshot.peers.contains(where: { $0.id == peerID && $0.trustGeneration == expectedGeneration }) else { self.fileNotice = "设备信任已更新，请重新选择"; return }
            guard self.canChooseFile(peerID: peerID) else { self.fileNotice = "正在准备文件，或普通任务已达50项"; return }
            let urls = panel.urls
            guard urls.count <= 100 else { self.fileNotice = "最多选择100个顶层项目"; return }
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            self.fileNotice = nil; self.pendingFilePreparations.insert(peerID)
            let finish: (String?) -> Void = { [weak self] error in
                for url in scoped { url.stopAccessingSecurityScopedResource() }
                self?.pendingFilePreparations.remove(peerID); self?.fileNotice = error
            }
            if allowGroups { self.server.sendMany(sources: urls, peerID: peerID, expectedGeneration: expectedGeneration, completion: finish) }
            else if let url = urls.first { self.server.sendFile(source: url, peerID: peerID, expectedGeneration: expectedGeneration, completion: finish) }
        }
    }
    @Published private(set) var choosingReceiveFolder = false
    func chooseReceiveFolder() {
        guard !choosingReceiveFolder else { return }
        choosingReceiveFolder = true
        let panel = NSOpenPanel(); panel.title = "选择接收文件夹"; panel.prompt = "使用这个文件夹"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.resolvesAliases = false
        if let path = snapshot.files.receiveFolderPath { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { self.choosingReceiveFolder = false; return }
            let scoped = url.startAccessingSecurityScopedResource()
            self.server.setReceiveFolder(url) { [weak self] error in
                if scoped { url.stopAccessingSecurityScopedResource() }
                self?.choosingReceiveFolder = false
                if let error { self?.transferOperationNotice = error }
            }
        }
    }
    func saveMany(_ selections: [FileTaskSelection]) {
        let panel = NSOpenPanel(); panel.title = "选择保存位置"; panel.prompt = "保存到此目录"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let scoped = url.startAccessingSecurityScopedResource(); self.fileNotice = nil
            self.server.exportMany(selections, parent: url) { if scoped { url.stopAccessingSecurityScopedResource() } }
        }
    }
    func export(_ task: FileTaskView) {
        let panel = NSSavePanel(); panel.title = "另存为"; panel.nameFieldStringValue = task.name
        panel.canCreateDirectories = true; panel.isExtensionHidden = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            // 保存面板已向用户确认同名替换；不存在时由引擎执行原子不覆盖创建。
            let replace = FileManager.default.fileExists(atPath: url.path)
            self.server.exportFile(taskID: task.id, expectedAttempt: task.attemptId, destination: url, replace: replace) { [weak self] error in
                if scoped { url.stopAccessingSecurityScopedResource() }
                self?.fileNotice = error ?? "文件已导出到所选位置"
            }
        }
    }
    func openFile(_ task: FileTaskView) {
        if task.isOrdinaryReceivedFile {
            server.locateReceivedFiles(taskID: task.id, expectedAttempt: task.attemptId) { [weak self] urls, error in
                guard let urls, let first = urls.first else { self?.transferOperationNotice = error ?? "本地文件已不存在"; return }
                // 多root共用本次接收目录；Finder操作则会一次选中全部root。
                let target = urls.count == 1 ? first : first.deletingLastPathComponent()
                if !NSWorkspace.shared.open(target) { self?.transferOperationNotice = "无法打开此文件，请在 Finder 中选择合适的应用" }
            }
            return
        }
        server.locateFile(taskID: task.id, expectedAttempt: task.attemptId) { [weak self] url in
            guard let url else { self?.fileNotice = "本地文件已不存在或校验未通过，请重新下载"; return }
            if !NSWorkspace.shared.open(url) { self?.fileNotice = "无法打开此文件，请在 Finder 中选择合适的应用" }
        }
    }
    func reveal(_ task: FileTaskView) {
        if task.isOrdinaryReceivedFile {
            server.locateReceivedFiles(taskID: task.id, expectedAttempt: task.attemptId) { [weak self] urls, error in
                if let urls, !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                else { self?.transferOperationNotice = error ?? "本地文件已不存在" }
            }
            return
        }
        server.locateFile(taskID: task.id, expectedAttempt: task.attemptId) { [weak self] url in
            if let url {
                if task.kind == "group" { NSWorkspace.shared.open(url) }
                else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            else { self?.fileNotice = "本地文件已不存在或校验未通过" }
        }
    }
    enum Page: String, CaseIterable, Identifiable {
        case connection = "概览", files = "文件传输", clipboard = "剪贴板", devices = "我的设备", settings = "设置", storage = "存储空间"
        var id: String { rawValue }
        var symbol: String { switch self { case .connection: "square.grid.2x2"; case .files: "arrow.left.arrow.right"; case .clipboard: "clipboard"; case .devices: "iphone"; case .settings, .storage: "gearshape" } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let lifecycle = DesktopLifecycle()
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 开发包路径不变时 Dock 可能保留旧缓存，运行图标明确取当前包中的资源。
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { lifecycle.show(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 显式退出、注销和关机都走系统终止流程，不被“保留在状态栏”设置阻止。
        lifecycle.prepareToTerminate(); return .terminateNow
    }
}

struct XuQiaoApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("续桥", id: "main") {
            MainWindow().environmentObject(model)
                .frame(minWidth: 830, minHeight: 630)
                .background(WindowLifecycleAttachment(lifecycle: delegate.lifecycle, model: model))
        }
        .defaultSize(width: 1060, height: 780)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { delegate.lifecycle.show(.settings) }.keyboardShortcut(",")
            }
            CommandMenu("导航") {
                Button("连接") { model.selection = .connection }.keyboardShortcut("1", modifiers: .command)
                Button("我的设备") { model.selection = .devices }.keyboardShortcut("2", modifiers: .command)
                Button("设置") { model.selection = .settings }.keyboardShortcut("3", modifiers: .command)
                Button("文件传输") { model.selection = .files }.keyboardShortcut("4", modifiers: .command)
                Button("剪贴板") { model.selection = .clipboard }.keyboardShortcut("5", modifiers: .command)
            }
        }
    }
}
