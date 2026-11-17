import AppKit
import SwiftUI

struct DebugControlPage: View {
    @ObservedObject var service: DebugControlService
    @State private var text = ""
    @State private var expanded = false
    @State private var showingText = false
    @State private var showingConnection = false
    @FocusState private var textFocused: Bool

    private var ready: Bool { service.active && service.image != nil }
    private var connecting: Bool { service.preparing || service.active && !ready }
    private var needsStatusPanel: Bool {
        !ready || service.status != "控制已启用 · 调试预览刷新率受设备响应限制"
    }
    private var badge: String { service.deviceName + " · " + (ready ? "已连接" : connecting ? "正在连接" : service.peerConnected ? "待控制" : "未连接") }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                DebugControlCanvas(image: service.image, enabled: ready && !service.inputPending,
                                   click: { service.click($0) }, swipe: { service.swipe(from: $0, to: $1) })
                if service.image == nil {
                    VStack(spacing: 14) {
                        if connecting { ProgressView().controlSize(.large).tint(.white) }
                        else { Image(systemName: "iphone").font(.system(size: 38, weight: .ultraLight)) }
                        Text(connecting ? (service.preparing ? "正在连接手机" : "正在准备画面") : service.deviceName).font(.system(size: 15, weight: .medium))
                        if !connecting {
                            Text(service.targets.isEmpty ? "连接手机并开启 USB 或无线调试" : "手机画面将在这里显示")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                            Button("开始控制") { startControl() }.buttonStyle(.borderedProminent)
                                .disabled(service.refreshing).accessibilityIdentifier("debug-control-start")
                        }
                    }.foregroundStyle(.white.opacity(0.9)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 6) {
                    Circle().fill(ready ? .green : connecting ? .orange : .gray).frame(width: 5, height: 5)
                    Text(badge).font(.system(size: 10, weight: .medium)).lineLimit(1)
                }.padding(.horizontal, 9).padding(.vertical, 6).background(.regularMaterial, in: Capsule())
                    .padding(10).help(service.status).allowsHitTesting(false)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                // 状态仅在连接/恢复时占用独立安全区，绝不覆盖画布底部导航或键盘。
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if needsStatusPanel { statusPanel.padding(10) }
                }
            Divider()
            VStack(spacing: 5) {
                tool(expanded ? "收起" : "展开", symbol: expanded ? "sidebar.right" : "sidebar.left", id: "debug-control-toolbar-toggle") {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                }
                Divider().padding(.horizontal, 9).padding(.vertical, 3)
                tool("返回", symbol: "chevron.backward", id: "debug-control-back", disabled: !ready || service.inputPending) { service.back() }
                tool("主页", symbol: "house", id: "debug-control-home", disabled: !ready || service.inputPending) { service.home() }
                tool("输入文字", symbol: "keyboard", id: "debug-control-text-open", disabled: !ready) { showingText.toggle() }
                    .popover(isPresented: $showingText, arrowEdge: .trailing) { textPanel }
                Spacer(minLength: 12)
                tool("连接", symbol: "cable.connector", id: "debug-control-connection") { showingConnection.toggle() }
                    .popover(isPresented: $showingConnection, arrowEdge: .trailing) { connectionPanel }
                tool("停止控制", symbol: "stop.circle", id: "debug-control-stop", disabled: !service.active && !service.preparing) { service.stop() }
            }.padding(.vertical, 9).frame(width: expanded ? 132 : 44).background(.regularMaterial)
        }.frame(minWidth: 340, minHeight: 500)
            .onAppear { service.refreshTargets() }
            .onChange(of: service.selectedTarget) { _, _ in text = "" }
            .onChange(of: service.peer?.id) { _, _ in text = ""; showingText = false }
            // 停止时清空输入，保留已打开的浮层以显示服务失败原因。
            .onChange(of: service.active) { _, active in if !active { text = "" } }
    }

    private func tool(_ title: String, symbol: String, id: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15, weight: .regular)).frame(width: 22)
                if expanded { Text(title).font(.system(size: 11)); Spacer(minLength: 0) }
            }.padding(.horizontal, expanded ? 10 : 0).frame(maxWidth: .infinity).frame(height: 34).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(disabled ? Color.secondary.opacity(0.35) : Color.primary.opacity(0.75))
            .disabled(disabled).help(title).accessibilityLabel(title).accessibilityIdentifier(id)
    }

    // 故障原因就地保留，恢复入口不占用精简侧栏与画布布局。
    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(service.status).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("debug-control-status")
            HStack(spacing: 10) {
                Button("连接设置") { showingConnection = true }
                    .accessibilityIdentifier("debug-control-status-connection")
                Button("重试恢复") { startControl() }
                    .disabled(service.active || service.preparing || service.refreshing)
                    .accessibilityIdentifier("debug-control-retry")
            }.controlSize(.small)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // 与服务的字节及控制字符限制一致；按钮与回车提交共用预检。
    private var textValidationMessage: String? {
        if text.isEmpty { return "请输入要发送的文字。" }
        if text.utf8.count > 4096 { return "文字最多 4096 字节，请缩短后发送。" }
        if text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            return "仅支持单行文字，请移除换行、制表符等控制字符。"
        }
        if !ready { return "请先连接手机并等待画面。" }
        if service.inputPending { return "正在处理上一次操作，请稍候。" }
        if !service.canSendText { return "请先点按手机上的文字框。" }
        return nil
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("输入文字").font(.system(size: 13, weight: .semibold))
            TextField("输入要发送的文字", text: $text).textFieldStyle(.roundedBorder).focused($textFocused)
                .accessibilityIdentifier("debug-control-text").onSubmit { sendText() }
            Text(service.status).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("debug-control-text-status")
            HStack(alignment: .center, spacing: 12) {
                Text(textValidationMessage ?? "发送到手机当前光标处")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("发送") { sendText() }.buttonStyle(.borderedProminent)
                    .disabled(textValidationMessage != nil).accessibilityIdentifier("debug-control-send")
            }
        }.padding(16).frame(width: 280).onAppear { textFocused = true }
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("手机连接").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("调试预览").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Picker("手机", selection: Binding(get: { service.peerConnected ? service.peer?.id ?? "" : "" }, set: { service.choosePeer($0) })) {
                Text("选择手机").tag("")
                ForEach(service.onlinePeers) { Text(deviceLabel($0.name, id: $0.id)).tag($0.id) }
            }.accessibilityIdentifier("debug-control-peer")
            if !service.targets.isEmpty {
                Picker("调试通道", selection: Binding(get: { service.selectedTarget }, set: { service.select($0) })) {
                    Text("选择并确认通道").tag("")
                    ForEach(service.targets, id: \.self) { Text(service.targetLabel($0)).tag($0) }
                }.disabled(!service.peerConnected || service.active || service.preparing).accessibilityIdentifier("debug-control-target")
            }
            Text(service.status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("重新查找") { service.refreshTargets() }.disabled(service.refreshing || service.active || service.preparing)
                    .accessibilityIdentifier("debug-control-refresh")
                Spacer()
                if !service.active && !service.preparing {
                    Button("连接") { startControl() }.buttonStyle(.borderedProminent).disabled(service.refreshing)
                        .accessibilityIdentifier("debug-control-connect")
                }
            }
            DisclosureGroup("高级设置") {
                VStack(alignment: .leading, spacing: 9) {
                    if let host = service.peer?.remoteHost { Text("手机连接地址：" + host).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                    ForEach(service.targets, id: \.self) { target in
                        Text(service.targetLabel(target) + "：" + target).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                    Text(service.hdcPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("选择 HDC…") { service.chooseExecutable() }.accessibilityIdentifier("debug-control-hdc-path")
                    Text("仅控制你已信任的调试设备").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.top, 9)
            }.font(.system(size: 11))
        }.padding(16).frame(width: 280)
    }

    private func startControl() {
        guard service.canStart else { showingConnection = true; return }
        showingConnection = false
        service.start()
    }
    private func sendText() {
        guard textValidationMessage == nil, service.canSendText else { return }
        if service.sendText(text) { text = "" }
    }
}

/// AppKit 接收真实鼠标输入；仅映射 aspectFit 图像矩形，黑边与跨越黑边的手势不会发往设备。
private struct DebugControlCanvas: NSViewRepresentable {
    let image: CGImage?
    let enabled: Bool
    let click: (CGPoint) -> Void
    let swipe: (CGPoint, CGPoint) -> Void
    func makeNSView(context: Context) -> ControlCanvasView { ControlCanvasView() }
    func updateNSView(_ view: ControlCanvasView, context: Context) {
        view.image = image; view.enabled = enabled; view.click = click; view.swipe = swipe; view.needsDisplay = true
    }
}
private final class ControlCanvasView: NSView {
    var image: CGImage?
    var enabled = false
    var click: ((CGPoint) -> Void)?
    var swipe: ((CGPoint, CGPoint) -> Void)?
    private var start: CGPoint?
    private var startSize: CGSize?
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("手机调试预览，可点击和拖动")
        setAccessibilityIdentifier("debug-control-canvas")
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    private var imageRect: CGRect {
        guard let image, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill(); bounds.fill()
        if let image {
            NSImage(cgImage: image, size: .zero).draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }
    private func mapped(_ location: CGPoint) -> CGPoint? {
        guard enabled, let image, imageRect.width > 0, imageRect.height > 0, imageRect.contains(location) else { return nil }
        return CGPoint(x: (location.x - imageRect.minX) * CGFloat(image.width) / imageRect.width,
                       y: (location.y - imageRect.minY) * CGFloat(image.height) / imageRect.height)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        start = mapped(point) == nil ? nil : point
        startSize = image.map { CGSize(width: $0.width, height: $0.height) }
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; startSize = nil }
        guard let start, let image, startSize == CGSize(width: image.width, height: image.height),
              let first = mapped(start), let last = mapped(convert(event.locationInWindow, from: nil)) else { return }
        let end = convert(event.locationInWindow, from: nil)
        if hypot(end.x - start.x, end.y - start.y) <= 7 { click?(first) }
        else { swipe?(first, last) }
    }
}
