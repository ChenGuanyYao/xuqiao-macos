import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import XuQiaoCore

struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    private let pages: [AppModel.Page] = [.connection, .files, .clipboard, .devices, .settings]
    private var connectedCount: Int { model.snapshot.peers.filter(\.connected).count }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) { AppIconView(size: 37); Text("续桥").font(.system(size: 17, weight: .semibold)) }.padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 29)
                Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(NativeTheme.muted.opacity(0.8)).padding(.horizontal, 22).padding(.bottom, 10)
                ForEach(pages) { page in
                    Button { model.selection = page } label: {
                        HStack(spacing: 11) {
                            Image(systemName: page.symbol).frame(width: 18); Text(page.rawValue); Spacer()
                            if page == .files, !model.snapshot.files.pendingReceives.isEmpty {
                                Text("\(model.snapshot.files.pendingReceives.count)").font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2).background(NativeTheme.blueLight, in: Capsule())
                            }
                        }
                            .font(.system(size: 13, weight: active(page) ? .medium : .regular))
                            .foregroundStyle(active(page) ? NativeTheme.blue : NativeTheme.muted)
                            .padding(.horizontal, 13).frame(height: 39)
                            .background(active(page) ? Color(red: 0.86, green: 0.91, blue: 1) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            // 导航整行统一为矩形命中区，包括文字和图标周围的留白。
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        // 仅导航允许激活窗口的首次点击；不扩展到下载、清理等内容操作。
                        .allowsWindowActivationEvents(true)
                        .padding(.horizontal, 11).padding(.bottom, 4).accessibilityIdentifier("nav-" + page.id)
                }
                Spacer()
                Divider().overlay(NativeTheme.line).padding(.horizontal, 18)
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").font(.system(size: 20, weight: .light)).foregroundStyle(NativeTheme.blue.opacity(0.7))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.snapshot.deviceName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(connectedCount > 0 ? "\(connectedCount) 台设备已连接" : model.snapshot.ready ? "等待设备连接" : "连接服务未就绪").font(.system(size: 10)).foregroundStyle(NativeTheme.muted)
                    }
                }.padding(20)
            }.frame(width: 204).background(NativeTheme.sidebar)
            Rectangle().fill(NativeTheme.line).frame(width: 1)
            VStack(spacing: 0) {
                if let pending = model.snapshot.pending {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(pending.macConfirmed ? "已允许，等待手机确认" : "需要在 Mac 允许首次连接", systemImage: "lock.shield")
                                .font(.headline)
                            Text(pending.name + " · 请核对手机数字").font(.caption).lineLimit(1)
                            Text(pending.verificationCode).font(.system(size: 26, weight: .semibold, design: .monospaced)).tracking(5)
                        }
                        Spacer()
                        Button("拒绝", role: .destructive) { model.server.reject(sessionID: pending.id, requestID: pending.requestID) }
                        Button("允许连接") { model.server.approve(sessionID: pending.id, requestID: pending.requestID) }
                            .buttonStyle(.borderedProminent).disabled(pending.macConfirmed)
                    }.padding(18).background(NativeTheme.blueLight)
                }
                if model.selection == .files { FileTransfersPage() }
                else if model.selection == .clipboard { ClipboardPage() }
                else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error = model.snapshot.error {
                            HStack { NativeNotice(text: error, warning: true); if !model.snapshot.ready { Button("重试") { model.server.retry() } } }
                        }
                        if model.selection != .connection, model.snapshot.pending != nil {
                            HStack { Label("有新的设备配对请求", systemImage: "iphone.and.arrow.forward"); Spacer(); Button("查看并确认") { model.showPairing() }.buttonStyle(.borderedProminent) }.font(.system(size: 12)).padding(14).background(NativeTheme.blueLight, in: RoundedRectangle(cornerRadius: 10))
                        }
                        switch model.selection {
                        case .connection: OverviewPage()
                        case .files: EmptyView()
                        case .clipboard: EmptyView()
                        case .devices: DevicesPage()
                        case .settings: SettingsPage()
                        case .storage: StoragePage()
                        }
                    }.padding(26).frame(maxWidth: 1160, alignment: .leading).frame(maxWidth: .infinity)
                }.background(.white)
                }
            }.frame(maxWidth: .infinity)
        }.foregroundStyle(NativeTheme.ink).tint(NativeTheme.blue)
            .sheet(item: $model.sendFilesPeer) { peer in SendFilesSheet(peer: peer).environmentObject(model) }
            .sheet(item: $model.fileReceivePrompt, onDismiss: { model.fileReceiveSheetDidDismiss() }) { prompt in
                IncomingFileSheet(prompt: prompt).environmentObject(model).onAppear { model.fileReceiveSheetDidAppear() }
            }
            // 配对面板由稳定的主窗口持有，不依附概览的滚动内容或自适应布局分支。
            .sheet(isPresented: $model.pairingExpanded, onDismiss: { model.pairingSheetDidDismiss() }) {
                PairingSheet().environmentObject(model).onAppear { model.pairingSheetDidAppear() }
            }
            .alert("允许新手机连接？", isPresented: Binding(get: { model.pairingPrompt != nil }, set: { if !$0 { model.pairingPrompt = nil } }), presenting: model.pairingPrompt) { pending in
                Button("允许连接") { model.server.approve(sessionID: pending.id, requestID: pending.requestID) }
                Button("拒绝", role: .cancel) { model.server.reject(sessionID: pending.id, requestID: pending.requestID) }
            } message: { pending in
                Text("\(pending.name) 请求首次配对。\n核对手机上的数字是否也是 \(pending.verificationCode)。只有两端一致且是你正在连接的手机，才允许连接。")
            }
    }
    private func active(_ page: AppModel.Page) -> Bool { model.selection == page || page == .settings && model.selection == .storage }
}

private struct OverviewPage: View {
    @EnvironmentObject var model: AppModel
    private var connected: [PeerView] { model.snapshot.peers.filter(\.connected) }
    // 与“我的设备”保持相同顺序，每台设备按自身状态展示，不选首项代表全部设备。
    private var orderedPeers: [PeerView] { connected + model.snapshot.peers.filter { !$0.connected } }
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) { Text("设备之间，接着来").font(.system(size: 24, weight: .semibold)); Text("文件和剪贴板，随手接续。").font(.system(size: 12)).foregroundStyle(NativeTheme.muted) }
            Spacer(); Button { model.showPairing() } label: { Label("连接新手机", systemImage: "plus") }.buttonStyle(.bordered)
        }.padding(.bottom, 3)
        if !model.snapshot.peers.isEmpty {
            Text("\(model.snapshot.peers.count) 台已配对 · \(connected.count) 台已连接")
                .font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
            ForEach(orderedPeers) { peer in
                NativeCard {
                    HStack(spacing: 15) {
                        Image(systemName: "iphone").font(.system(size: 31, weight: .light)).foregroundStyle(peer.connected ? NativeTheme.blue : NativeTheme.muted).frame(width: 52, height: 57).background(peer.connected ? NativeTheme.blueLight : NativeTheme.sidebar, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 7) {
                            Text(deviceLabel(peer.name, id: peer.id)).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                            NativeStatus(title: peer.connected ? "局域网已连接" : "等待重新连接", color: peer.connected ? .green : NativeTheme.muted)
                        }
                        Spacer(); Button("管理设备") { model.selection = .devices }
                    }
                }
            }
            HStack(alignment: .top, spacing: 0) {
                overviewLink("剪贴板", subtitle: "文字、图片和文件的同步记录", symbol: "clipboard") { model.clipboardSource = ""; model.selection = .clipboard }
                Rectangle().fill(NativeTheme.line).frame(width: 1)
                overviewLink("文件传输", subtitle: "保留文件名与目录层级", symbol: "arrow.left.arrow.right") { model.filePeer = ""; model.selection = .files }
            }.frame(height: 120).padding(.vertical, 4)
        }
        if model.snapshot.peers.isEmpty {
            NativeCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("连接新手机", systemImage: "qrcode.viewfinder").font(.headline)
                    Text("打开配对面板，用手机续桥扫描二维码，或核对指纹后输入配对码。").font(.callout).foregroundStyle(.secondary)
                    Button("打开配对二维码") { model.showPairing() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
    private func overviewLink(_ title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) { Image(systemName: symbol).font(.system(size: 19, weight: .light)).foregroundStyle(NativeTheme.blue); Text(title).font(.system(size: 15, weight: .medium)); Text(subtitle).font(.system(size: 11)).foregroundStyle(NativeTheme.muted) }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
        }.buttonStyle(.plain)
    }
}

private struct PairingSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var enlarged = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("连接新手机", systemImage: "qrcode.viewfinder").font(.title2.weight(.semibold))
                Spacer()
                Button(enlarged ? "普通大小" : "放大扫码") { enlarged.toggle() }
                    .accessibilityIdentifier("pairing-qr-enlarge")
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .center, spacing: 24) {
                Group {
                    if model.snapshot.ready {
                        QRImage(text: model.snapshot.qr, side: enlarged ? 520 : 320)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "wifi.exclamationmark").font(.system(size: 34))
                            Text(model.snapshot.error == nil ? "正在准备连接…" : "连接服务不可用")
                            if model.snapshot.error != nil { Button("重试连接服务") { model.server.retry() } }
                        }.foregroundStyle(.secondary).frame(width: enlarged ? 520 : 320, height: enlarged ? 520 : 320)
                    }
                }.accessibilityIdentifier("pairing-qr")
                VStack(alignment: .leading, spacing: 16) {
                    Text("使用手机续桥扫描").font(.headline)
                    Text("保持两端处于同一局域网。扫码后需在手机和 Mac 分别确认；已信任设备不必重复扫码。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text("也可以输入配对码").font(.headline)
                    Text(!model.snapshot.ready || model.snapshot.pairingCode.isEmpty ? "— — — — — —" : model.snapshot.pairingCode)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced)).tracking(4).textSelection(.enabled)
                    Text("在手机上选择附近的这台 Mac，完整核对下方 SHA-256 指纹后，再输入配对码。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("安全指纹 · SHA-256").font(.subheadline.weight(.medium))
                    Text(groupedFingerprint(model.snapshot.fingerprint))
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).lineSpacing(5).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }.frame(width: 270, alignment: .leading)
            }.frame(maxWidth: .infinity)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.snapshot.deviceName + " · " + model.snapshot.host).font(.caption)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(model.snapshot.ready ? "\(max(0, Int(model.snapshot.expiresAt.timeIntervalSince(context.date)))) 秒后过期" : "服务就绪后显示配对码")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                Button("刷新二维码") { model.server.refreshPairing() }.disabled(!model.snapshot.ready)
            }
        }.padding(24).frame(width: enlarged ? 900 : 700)
    }
}

struct AppIconView: View {
    let size: CGFloat
    // 包内图标在当前进程不会变化；避免导航及快照更新时重复读取、解析整份 ICNS。
    private static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) { return image }
        return NSApplication.shared.applicationIconImage
    }()
    var body: some View {
        Image(nsImage: Self.image).resizable().frame(width: size, height: size)
    }
}
private struct QRImage: View {
    let text: String
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Group {
            if let image = PairingQRCode.image(text, side: side, scale: displayScale) { Image(nsImage: image).interpolation(.none) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(width: side, height: side).background(.white)
            .accessibilityLabel("续桥配对二维码，请使用手机续桥扫描")
    }
}

/// 直接按屏幕物理像素生成，禁止再缩放；四模块静区与每个模块均落在整数像素上。
enum PairingQRCode {
    static func image(_ value: String, side: CGFloat, scale: CGFloat) -> NSImage? {
        guard !value.isEmpty, side > 0, scale > 0 else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "L"
        guard let output = filter.outputImage,
              let source = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let gray = CGColorSpaceCreateDeviceGray()
        guard let scan = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: source.width, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let bytes = scan.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        scan.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        // Core Image 自带边距不作为契约；按黑色模块边界裁出矩阵，再明确补足静区。
        var minX = source.width, minY = source.height, maxX = -1, maxY = -1
        for y in 0..<source.height {
            for x in 0..<source.width where bytes[y * source.width + x] < 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let modules = maxX - minX + 1
        guard modules > 0, modules == maxY - minY + 1,
              let matrix = source.cropping(to: CGRect(x: minX, y: minY, width: modules, height: modules)) else { return nil }
        let pixels = Int((side * scale).rounded(.down))
        let quietModules = 4
        let modulePixels = pixels / (modules + quietModules * 2)
        guard modulePixels >= 1,
              let canvas = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        canvas.setFillColor(gray: 1, alpha: 1); canvas.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        canvas.interpolationQuality = .none; canvas.setShouldAntialias(false)
        let matrixPixels = modules * modulePixels
        let origin = (pixels - matrixPixels) / 2
        canvas.draw(matrix, in: CGRect(x: origin, y: origin, width: matrixPixels, height: matrixPixels))
        guard let rendered = canvas.makeImage() else { return nil }
        return NSImage(cgImage: rendered, size: NSSize(width: CGFloat(pixels) / scale, height: CGFloat(pixels) / scale))
    }
}
private func groupedFingerprint(_ value: String) -> String {
    guard value.count == 64 else { return "正在读取本机安全身份…" }
    let chars = Array(value.uppercased())
    let groups = stride(from: 0, to: 64, by: 4).map { String(chars[$0..<($0 + 4)]) }
    return groups.prefix(8).joined(separator: " ") + "\n" + groups.suffix(8).joined(separator: " ")
}
