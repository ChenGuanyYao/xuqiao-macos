import AppKit
import CryptoKit
import Foundation
import ImageIO
import Darwin
import Network
import XuQiaoCore

private struct DebugControlFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 每个会话只有一个进程在途；停止先作废代际，再终止进程，迟到结果不能更新画面或继续输入。
private final class HDCProcessRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.xuqiao.debug-control.process")
    private let lock = NSLock()
    private var current: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; let process = current; lock.unlock()
        terminate(process)
    }
    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    func run(executable: String, arguments: [String], receiving: URL? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let process = Process(), pipe = Pipe(), output = BoundedOutput()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments; process.standardOutput = pipe; process.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let bytes = handle.availableData
                    if bytes.isEmpty {
                        // EOF 后管道仍持续可读，必须解绑回调，避免反复触发导致 CPU 自旋。
                        handle.readabilityHandler = nil
                        return
                    }
                    output.append(bytes)
                }
                self.lock.lock()
                if self.cancelled {
                    self.lock.unlock(); pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: CancellationError()); return
                }
                self.current = process
                do { try process.run(); self.lock.unlock() }
                catch {
                    self.current = nil; self.lock.unlock(); pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: DebugControlFailure(message: "无法启动 HDC，请重新选择可执行文件。")); return
                }
                let deadline = Date().addingTimeInterval(8)
                var failure: String?
                while process.isRunning {
                    self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
                    if cancelled { self.terminate(process); failure = "控制已停止"; break }
                    if Date() >= deadline { self.terminate(process); failure = "调试命令超时，已停止控制。请检查设备连接后重试。"; break }
                    if output.exceeded { self.terminate(process); failure = "HDC 返回内容过大，已停止控制。"; break }
                    if let receiving {
                        // URL.resourceValues 会缓存刚创建时的 0 字节元数据；接收中必须向文件系统实时查询。
                        var metadata = stat()
                        if lstat(receiving.path, &metadata) == 0,
                           (metadata.st_mode & S_IFMT != S_IFREG || metadata.st_size < 0 || metadata.st_size > 16_777_216) {
                            self.terminate(process); failure = "调试预览文件类型无效或超过大小限制，已停止控制。"; break
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                // 子进程已退出，读完管道尾部；输出只在内存里保留固定上限。
                output.append(pipe.fileHandleForReading.readDataToEndOfFile())
                self.lock.lock(); self.current = nil; let cancelled = self.cancelled; self.lock.unlock()
                if cancelled { continuation.resume(throwing: CancellationError()); return }
                if let failure { continuation.resume(throwing: DebugControlFailure(message: failure)); return }
                let result = output.string
                guard process.terminationStatus == 0, !output.exceeded,
                      !result.localizedCaseInsensitiveContains("[fail]"),
                      !result.localizedCaseInsensitiveContains("error:") else {
                    // 不把命令输出直接带到错误或日志，避免文字输入被 HDC 回显。
                    continuation.resume(throwing: DebugControlFailure(message: "调试命令失败，已停止控制。请确认所选目标在线且已信任 HDC。")); return
                }
                continuation.resume(returning: result)
            }
        }
    }
    private final class BoundedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var overflow = false
        func append(_ value: Data) {
            lock.lock(); defer { lock.unlock() }
            let remaining = max(0, 65_536 - bytes.count)
            if value.count > remaining { overflow = true }
            bytes.append(value.prefix(remaining))
        }
        var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    }
}

/// 文件读取和 ImageIO 解码独立于 MainActor；立即解码，避免首次绘制时再阻塞主线程。
private final class DebugControlFrameIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.xuqiao.debug-control.frame-io", qos: .userInitiated, autoreleaseFrequency: .workItem)

    func prepare(_ directory: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func readAndRemove(_ local: URL, previousFingerprint: SHA256.Digest?) async throws -> (image: CGImage?, fingerprint: SHA256.Digest) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    // 失败路径也释放本帧；目录仍由会话结束清理，且不读取其他路径。
                    defer { try? FileManager.default.removeItem(at: local) }
                    let frame = try Self.readFrame(local, previousFingerprint: previousFingerprint)
                    continuation.resume(returning: frame)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func removeDirectory(_ directory: URL) async {
        await withCheckedContinuation { continuation in
            queue.async {
                try? FileManager.default.removeItem(at: directory)
                continuation.resume()
            }
        }
    }
    private static func readFrame(_ url: URL, previousFingerprint: SHA256.Digest?) throws -> (image: CGImage?, fingerprint: SHA256.Digest) {
        // 通过同一只读 fd 核对类型、权限和长度，不沿用 URL 缓存，也不跟随最终路径的符号链接。
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DebugControlFailure(message: "无法安全打开调试预览文件。") }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              (1...16_777_216).contains(metadata.st_size) else { throw DebugControlFailure(message: "调试预览文件无效或超过大小限制。") }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw DebugControlFailure(message: "无法设置调试预览的私有文件权限。") }
        let length = Int(metadata.st_size)
        var bytes = Data(count: length)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { throw DebugControlFailure(message: "无法读取调试预览文件。") }
            var offset = 0
            while offset < length {
                let count = Darwin.read(descriptor, base.advanced(by: offset), length - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DebugControlFailure(message: "调试预览文件未接收完整。") }
                offset += count
            }
        }
        // 有限读取只接受 fstat 核对过的长度；若文件在读取中增长，拒绝而不是继续分配内存。
        var extra: UInt8 = 0
        var tailCount: Int
        repeat { tailCount = Darwin.read(descriptor, &extra, 1) } while tailCount < 0 && errno == EINTR
        guard tailCount == 0 else { throw DebugControlFailure(message: "调试预览文件大小在读取中发生变化。") }
        // 安全读完真实字节后才比较指纹；静止帧不进入 ImageIO 解码，也不触发后续画面发布。
        let fingerprint = SHA256.hash(data: bytes)
        if fingerprint == previousFingerprint { return (nil, fingerprint) }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 24_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw DebugControlFailure(message: "调试预览图片损坏或尺寸超限。") }
        return (image, fingerprint)
    }
}

@MainActor
final class DebugControlService: ObservableObject {
    static let defaultHDCPath = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
    @Published private(set) var hdcPath = UserDefaults.standard.string(forKey: "debug-control.hdc-path") ?? defaultHDCPath
    @Published private(set) var targets: [String] = []
    @Published private(set) var selectedTarget = ""
    @Published private(set) var actualModel = ""
    @Published private(set) var status = "请选择已信任的 HDC 调试目标，再明确开始控制。"
    @Published private(set) var active = false
    @Published private(set) var preparing = false
    @Published private(set) var refreshing = false
    @Published private(set) var image: CGImage?
    @Published private(set) var focusPoint: CGPoint?
    @Published private(set) var inputPending = false
    @Published private(set) var peer: PeerView?
    @Published private(set) var onlinePeers: [PeerView] = []
    private struct TargetBinding: Codable {
        let peerID: String
        let trustGeneration: String
        let target: String
    }
    private static let bindingsKey = "debug-control.peer-bindings"
    private var bindings = (UserDefaults.standard.data(forKey: bindingsKey).flatMap { try? JSONDecoder().decode([TargetBinding].self, from: $0) }) ?? []
    private var generation = UUID()
    private var runner: HDCProcessRunner?
    private var refreshRunner: HDCProcessRunner?
    private var work: Task<Void, Never>?
    private var frameWait: (id: UUID, task: Task<Void, Never>)?
    private var pending: Input?
    private var lastInput = Date.distantPast
    private var sessionSize: CGSize?
    private let frameIO = DebugControlFrameIO()

    var executableAvailable: Bool { FileManager.default.isExecutableFile(atPath: hdcPath) }
    var peerConnected: Bool { peer.map { value in onlinePeers.contains { $0.id == value.id && $0.trustGeneration == value.trustGeneration } } ?? false }
    var deviceName: String { peer.map { deviceLabel($0.name, id: $0.id) } ?? "选择手机" }
    var canStart: Bool { peerConnected && targets.contains(selectedTarget) && targetMatchesCurrentPeer(selectedTarget) && !active && !preparing && executableAvailable }
    var canSendText: Bool { active && image != nil && focusPoint != nil && !inputPending }

    func updatePeers(_ peers: [PeerView]) {
        onlinePeers = peers.filter(\.connected)
        guard reloadBindings() else { stop(); selectedTarget = ""; status = "调试绑定数据无法读取，原数据未覆盖。"; return }
        // 撤销/重新配对不能继承旧信任代际的控制绑定。
        let retained = bindings.filter { binding in peers.contains { $0.id == binding.peerID && $0.trustGeneration == binding.trustGeneration } }
        if retained.count != bindings.count { bindings = retained; saveBindings() }
        guard let previous = peer else { return }
        guard let current = onlinePeers.first(where: { $0.id == previous.id && $0.trustGeneration == previous.trustGeneration }) else {
            if active || preparing || !selectedTarget.isEmpty { stop(); selectedTarget = "" }
            var unavailable = previous; unavailable.remoteHost = nil; peer = unavailable
            status = "手机已离线或信任已更新，请重新连接并选择手机。"; return
        }
        let addressChanged = previous.remoteHost != current.remoteHost
        peer = current
        if addressChanged {
            bindings.removeAll { binding in
                binding.peerID == current.id && binding.trustGeneration == current.trustGeneration &&
                    Self.targetHost(binding.target).flatMap(Self.nonLoopbackHost) != nil && !targetMatchesCurrentPeer(binding.target)
            }
            saveBindings()
            stop(); selectedTarget = ""; resolveTarget()
        } else if selectedTarget.isEmpty, !active, !preparing { resolveTarget() }
    }
    func bind(_ value: PeerView) {
        guard let current = onlinePeers.first(where: { $0.id == value.id && $0.trustGeneration == value.trustGeneration }) else { return }
        let changed = peer?.id != current.id || peer?.trustGeneration != current.trustGeneration
        if changed { stop(); selectedTarget = ""; actualModel = "" }
        peer = current
        if !active && !preparing { resolveTarget() }
    }
    func choosePeer(_ id: String) {
        if let value = onlinePeers.first(where: { $0.id == id }) { bind(value) }
        else { stop(); peer = nil; selectedTarget = ""; status = "请选择要控制的手机。" }
    }
    private func saveBindings() {
        if let data = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(data, forKey: Self.bindingsKey) }
    }
    private func persistedBindings() -> [TargetBinding]? {
        guard let data = UserDefaults.standard.data(forKey: Self.bindingsKey) else { return [] }
        return try? JSONDecoder().decode([TargetBinding].self, from: data)
    }
    private func reloadBindings() -> Bool {
        guard let latest = persistedBindings() else { status = "调试绑定数据无法读取，原数据未覆盖。"; return false }
        bindings = latest; return true
    }
    @discardableResult private func rememberTarget() -> Bool {
        guard let peer, peerConnected, !selectedTarget.isEmpty else { return false }
        if let host = Self.targetHost(selectedTarget).flatMap(Self.nonLoopbackHost),
           host != peer.remoteHost.flatMap(Self.nonLoopbackHost) { return false }
        // 与直接浏览共享绑定；MainActor 同步重读再合并，避免覆盖另一入口刚确认的设备。
        guard reloadBindings() else { return false }
        bindings.removeAll { $0.peerID == peer.id }
        bindings.append(TargetBinding(peerID: peer.id, trustGeneration: peer.trustGeneration, target: selectedTarget))
        saveBindings(); return true
    }
    private func targetMatchesCurrentPeer(_ target: String) -> Bool {
        guard let peer, let current = onlinePeers.first(where: { $0.id == peer.id && $0.trustGeneration == peer.trustGeneration }) else { return false }
        if let host = Self.targetHost(target).flatMap(Self.nonLoopbackHost) {
            // 无线地址会被其他设备复用；同信任代际也必须核对当前已认证地址。
            return host == current.remoteHost.flatMap(Self.nonLoopbackHost)
        }
        // USB/本机转发只能沿用用户明确确认过的绑定，不能由单候选规则创建。
        return persistedBindings()?.contains { $0.peerID == current.id && $0.trustGeneration == current.trustGeneration && $0.target == target } == true
    }
    private func resolveTarget() {
        guard !active, !preparing, selectedTarget.isEmpty else { return }
        guard reloadBindings() else { return }
        if let peer {
            guard peerConnected else { return }
            if let saved = bindings.first(where: { $0.peerID == peer.id && $0.trustGeneration == peer.trustGeneration }), targets.contains(saved.target), targetMatchesCurrentPeer(saved.target) {
                selectedTarget = saved.target
                status = "已恢复为这台手机确认过的调试通道，点击开始控制。"; return
            }
            if let host = peer.remoteHost.flatMap(Self.nonLoopbackHost) {
                let matches = targets.filter { Self.targetHost($0).flatMap(Self.nonLoopbackHost) == host }
                if matches.count == 1 {
                    selectedTarget = matches[0]; status = "已匹配当前手机的无线调试通道，点击开始控制。"; return
                }
            }
            status = targets.isEmpty ? "没有可用调试通道，请连接手机并确认系统 HDC 信任。" : "尚未确认这台手机的调试通道，请选择并核对；续桥会记住本次绑定。"
        } else {
            status = "请选择要控制的手机，再确认它的调试通道。"
        }
    }
    func targetLabel(_ target: String) -> String {
        let index = (targets.firstIndex(of: target) ?? 0) + 1
        guard let host = Self.targetHost(target) else { return "调试设备 · 通道 \(index)" }
        if Self.nonLoopbackHost(host) == nil { return "本机转发设备 · 通道 \(index)" }
        if let expected = peer?.remoteHost.flatMap(Self.nonLoopbackHost), Self.nonLoopbackHost(host) == expected { return deviceName + " · 无线通道 \(index)" }
        return "无线调试设备 · 通道 \(index)"
    }
    private static func targetHost(_ target: String) -> String? {
        guard let separator = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: separator)...]), port > 0 else { return nil }
        var host = String(target[..<separator])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard IPv4Address(host) != nil || IPv6Address(host) != nil else { return nil }
        return host
    }
    private static func nonLoopbackHost(_ host: String) -> Data? {
        if let address = IPv4Address(host) {
            let bytes = address.rawValue
            guard bytes.first != 127, bytes != Data([0, 0, 0, 0]) else { return nil }
            return bytes
        }
        guard let address = IPv6Address(host) else { return nil }
        let bytes = Array(address.rawValue)
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            guard bytes[12] != 127, bytes.suffix(4).contains(where: { $0 != 0 }) else { return nil }
            return Data(bytes.suffix(4))
        }
        guard bytes.dropLast().contains(where: { $0 != 0 }) || bytes.last! > 1 else { return nil }
        return address.rawValue
    }

    func chooseExecutable() {
        let panel = NSOpenPanel(); panel.title = "选择官方 HDC 可执行文件"; panel.prompt = "使用此 HDC"
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                guard FileManager.default.isExecutableFile(atPath: url.path) else { self.status = "所选文件不可执行，请选择 DevEco SDK 中的 hdc。"; return }
                self.stop(); self.refreshRunner?.cancel(); self.refreshing = false
                self.hdcPath = url.path; UserDefaults.standard.set(url.path, forKey: "debug-control.hdc-path")
                self.targets = []; self.selectedTarget = ""; self.refreshTargets()
            }
        }
    }
    func refreshTargets() {
        guard !refreshing, !preparing, !active else { return }
        guard executableAvailable else { status = "未找到 HDC，请选择本机 DevEco SDK 的 hdc 可执行文件。"; return }
        let process = HDCProcessRunner(); refreshRunner = process; refreshing = true
        let path = hdcPath
        Task {
            do {
                let output = try await process.run(executable: path, arguments: ["list", "targets"])
                guard refreshRunner === process else { return }
                let values = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                // 输出已有总字节上限；保留全部候选，避免截断后把同地址多通道误判成唯一。
                targets = Array(Set(values.filter(Self.validTarget))).sorted()
                if !selectedTarget.isEmpty && !targets.contains(selectedTarget) { selectedTarget = "" }
                resolveTarget()
            } catch { if refreshRunner === process { status = error.localizedDescription } }
            if refreshRunner === process { refreshing = false; refreshRunner = nil }
        }
    }
    func select(_ target: String) {
        guard target.isEmpty || targets.contains(target) else { return }
        guard peerConnected else { status = "请先选择在线手机。"; return }
        stop(); selectedTarget = target; actualModel = ""
        if target.isEmpty, let peer {
            guard reloadBindings() else { return }
            bindings.removeAll { $0.peerID == peer.id && $0.trustGeneration == peer.trustGeneration }; saveBindings()
        } else { rememberTarget() }
        status = target.isEmpty ? "请选择调试通道。" : "已为 \(deviceName) 选择调试通道，点击开始控制。"
    }
    func start() {
        guard targetMatchesCurrentPeer(selectedTarget) else {
            stop(); selectedTarget = ""; resolveTarget(); return
        }
        guard canStart, Self.validTarget(selectedTarget) else { return }
        guard rememberTarget() else { return }
        refreshRunner?.cancel(); refreshRunner = nil; refreshing = false
        let token = UUID(); generation = token; preparing = true; image = nil; focusPoint = nil; sessionSize = nil
        let process = HDCProcessRunner(); runner = process
        let target = selectedTarget, path = hdcPath
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xuqiao-control-" + token.uuidString, isDirectory: true)
        let local = directory.appendingPathComponent("frame.jpeg")
        let remote = "/data/local/tmp/xuqiao-control-" + token.uuidString + ".jpeg"
        status = "正在核对所选调试目标的真实型号…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await frameIO.prepare(directory)
                guard generation == token, !Task.isCancelled else { throw CancellationError() }
                let model = try await process.run(executable: path, arguments: Self.arguments(target, .model))
                guard generation == token, !Task.isCancelled else { throw CancellationError() }
                let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanModel.isEmpty, cleanModel.count <= 256, !cleanModel.contains("\n") else { throw DebugControlFailure(message: "无法核对所选调试设备的实际型号。") }
                actualModel = cleanModel; preparing = false; active = true
                status = "控制已启用 · 调试预览刷新率受设备响应限制"
                // 指纹只在本次会话内保留成功解码的结果，停止后重开必定解码并发布首帧。
                var lastFingerprint: SHA256.Digest? = nil
                var idleBackoff = false
                while generation == token, !Task.isCancelled {
                    // 输入仅有一个待处理槽位；停止/切换清空，不重放迟到输入。
                    if let input = pending {
                        pending = nil
                        _ = try await process.run(executable: path, arguments: Self.arguments(target, .input(input)))
                        guard generation == token else { throw CancellationError() }
                        inputPending = false
                    }
                    _ = try await process.run(executable: path, arguments: Self.arguments(target, .snapshot(remote)))
                    guard generation == token else { throw CancellationError() }
                    _ = try await process.run(executable: path, arguments: Self.arguments(target, .receive(remote, local.path)), receiving: local)
                    guard generation == token else { throw CancellationError() }
                    let frame = try await frameIO.readAndRemove(local, previousFingerprint: lastFingerprint)
                    // 后台解码期间可能停止或换目标，回到主线程必须再次验证代际。
                    guard generation == token, !Task.isCancelled else { throw CancellationError() }
                    if let decoded = frame.image {
                        let size = CGSize(width: decoded.width, height: decoded.height)
                        if sessionSize != size { focusPoint = nil; pending = nil; inputPending = false }
                        sessionSize = size; image = decoded; lastFingerprint = frame.fingerprint
                    }
                    let delay: UInt64
                    if frame.image != nil || Date().timeIntervalSince(lastInput) < 1.5 {
                        idleBackoff = false; delay = 120_000_000
                    } else {
                        // 连续静止先等一次 250ms，再退避到 1 秒；画面变化或用户操作恢复短间隔。
                        delay = idleBackoff ? 1_000_000_000 : 250_000_000
                        idleBackoff = true
                    }
                    try await waitForNextFrame(nanoseconds: delay, generation: token)
                }
            } catch {
                if generation == token {
                    invalidate(); status = error is CancellationError ? "控制已停止。" : error.localizedDescription
                }
            }
            // 清理只使用本会话生成的精确路径，绝不遍历或读取其他设备目录。
            let cleanup = HDCProcessRunner()
            _ = try? await cleanup.run(executable: path, arguments: Self.arguments(target, .remove(remote)))
            await frameIO.removeDirectory(directory)
        }
    }
    func stop() { invalidate(); status = "控制已停止，画面与待发送输入已清除。" }
    func close() { stop(); refreshRunner?.cancel(); refreshRunner = nil; refreshing = false; targets = []; selectedTarget = "" }
    private func invalidate() {
        generation = UUID(); active = false; preparing = false; pending = nil; inputPending = false
        frameWait?.task.cancel(); frameWait = nil
        image = nil; focusPoint = nil; sessionSize = nil; runner?.cancel(); runner = nil; work?.cancel(); work = nil
    }
    private func waitForNextFrame(nanoseconds: UInt64, generation token: UUID) async throws {
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        // 输入可能在抓帧或解码期间到达；已有输入时直接推进原串行循环，不额外等待。
        guard pending == nil else { return }
        let id = UUID()
        let task = Task<Void, Never> {
            // 取消仅用于唤醒；是否停止由下方的会话代际和 work 取消状态决定。
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        frameWait = (id, task)
        await task.value
        // 旧 work 结束等待时，不能清掉停止后新会话安装的等待句柄。
        if frameWait?.id == id { frameWait = nil }
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
    }
    func click(_ point: CGPoint) {
        guard validPoint(point) else { return }
        if enqueue(.click(Int(point.x), Int(point.y))) { focusPoint = point }
    }
    func swipe(from: CGPoint, to: CGPoint) {
        guard validPoint(from), validPoint(to) else { return }
        if enqueue(.swipe(Int(from.x), Int(from.y), Int(to.x), Int(to.y))) { focusPoint = nil }
    }
    func home() { if enqueue(.key("Home")) { focusPoint = nil } }
    func back() { if enqueue(.key("Back")) { focusPoint = nil } }
    @discardableResult func sendText(_ text: String) -> Bool {
        guard canSendText, focusPoint != nil, !text.isEmpty, text.utf8.count <= 4096,
              !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            status = "请先点击手机文字框，再发送最多 4096 字节的单行文字。"; return false
        }
        // IME 弹起会移动文字框；明确点击只用于启用门禁，发送到现有焦点，不能再点旧坐标。
        return enqueue(.text(text))
    }
    private func enqueue(_ input: Input) -> Bool {
        guard peerConnected, active, image != nil, pending == nil, !inputPending, Date().timeIntervalSince(lastInput) >= 0.12 else { return false }
        pending = input; inputPending = true; lastInput = Date()
        // 点击、输入、Home/Back 共用一个输入槽；只唤醒等待，不并行执行 HDC 命令。
        frameWait?.task.cancel()
        return true
    }
    private func validPoint(_ point: CGPoint) -> Bool {
        guard active, let image else { return false }
        return point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0 && point.x < CGFloat(image.width) && point.y < CGFloat(image.height)
    }
    private static func validTarget(_ target: String) -> Bool {
        !target.isEmpty && target.count <= 256 && target != "[Empty]" && target.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 91, 93, 95].contains($0)
        }
    }
    private enum Input { case click(Int, Int), swipe(Int, Int, Int, Int), key(String), text(String) }
    private enum Command { case model, snapshot(String), receive(String, String), remove(String), input(Input) }
    private static func arguments(_ target: String, _ command: Command) -> [String] {
        let prefix = ["-t", target]
        let words: [String]
        switch command {
        case .model: words = ["param", "get", "const.product.model"]
        case .snapshot(let path): words = ["snapshot_display", "-f", path]
        case .receive(let remote, let local): return prefix + ["file", "recv", remote, local]
        case .remove(let path): words = ["rm", "-f", path]
        case .input(let input):
            switch input {
            case .click(let x, let y): words = ["uitest", "uiInput", "click", "\(x)", "\(y)"]
            case .swipe(let x, let y, let endX, let endY): words = ["uitest", "uiInput", "swipe", "\(x)", "\(y)", "\(endX)", "\(endY)", "450"]
            case .key(let value): words = ["uitest", "uiInput", "keyEvent", value]
            case .text(let text): words = ["uitest", "uiInput", "text", text]
            }
        }
        // HDC shell 会再次解析：每个参数单独加单引号，内部单引号拆为 '"'"'，禁止命令替换。
        return prefix + ["shell", words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }.joined(separator: " ")]
    }

}
