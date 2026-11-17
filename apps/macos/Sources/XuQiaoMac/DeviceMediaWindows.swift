import AppKit
import SwiftUI
import XuQiaoCore

@MainActor
final class DeviceMediaWindowController: NSWindowController, NSWindowDelegate {
    private let onClose:()->Void
    init(title:String,size:NSSize,minimumContentSize:NSSize=NSSize(width:430,height:500),view:AnyView,onClose:@escaping()->Void){
        self.onClose=onClose
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title=title;window.titlebarSeparatorStyle = .none;window.backgroundColor = .windowBackgroundColor;window.titlebarAppearsTransparent = false;window.contentMinSize=minimumContentSize;window.contentView=NSHostingView(rootView:view);window.isReleasedWhenClosed=false
        super.init(window:window);window.delegate=self;window.center()
    }
    required init?(coder:NSCoder){fatalError("not supported")}
    func windowWillClose(_ notification:Notification){onClose()}
}
@MainActor
private final class ScreenCanvasModel:ObservableObject {
    @Published var image:CGImage?
    private let hub:ScreenImageHub
    private var subscription:UUID?
    init(peer:PeerView,hub:ScreenImageHub){self.hub=hub;subscription=hub.observe(peerId:peer.id,trustGeneration:peer.trustGeneration){[weak self] image in self?.image=image}}
    deinit{if let subscription{hub.remove(subscription)}}
}
struct PhoneScreenPage: View {
    @EnvironmentObject var model: AppModel
    let peer: PeerView
    @StateObject private var canvas: ScreenCanvasModel
    init(peer: PeerView, hub: ScreenImageHub) { self.peer = peer; _canvas = StateObject(wrappedValue: ScreenCanvasModel(peer: peer, hub: hub)) }
    private var state: DeviceMediaView? { guard model.current(peer) else { return nil }; return model.snapshot.media.first { $0.peerId == peer.id } }
    private var active: Bool { ["awaiting", "starting", "active", "streaming"].contains(state?.screenState ?? "") }
    private var connected: Bool { model.current(peer) && model.snapshot.peers.first { $0.id == peer.id }?.connected == true }
    private var statusTitle: String {
        guard connected else { return "手机未连接" }
        switch state?.screenState {
        case "awaiting", "starting": return "等待手机授权"
        case "active": return "正在准备画面"
        case "streaming": return "正在投屏"
        case "paused": return "投屏已中断"
        case "denied": return "尚未获得授权"
        case "unsupported": return "设备暂不支持投屏"
        case "error": return "投屏未能启动"
        default: return "投屏已停止"
        }
    }
    private var statusSymbol: String {
        guard connected else { return "wifi.slash" }
        switch state?.screenState {
        case "paused": return "arrow.clockwise"
        case "denied": return "hand.raised"
        case "unsupported": return "display.trianglebadge.exclamationmark"
        case "error": return "exclamationmark.arrow.triangle.2.circlepath"
        case "awaiting", "starting": return "iphone.badge.checkmark"
        default: return "iphone"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 23, weight: .light)).foregroundStyle(NativeTheme.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(deviceLabel(peer.name, id: peer.id)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Label("屏幕共享", systemImage: "display").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if active {
                    Button { model.server.stopScreen(peerID: peer.id, expectedGeneration: peer.trustGeneration) } label: { Label("停止投屏", systemImage: "stop.fill") }.accessibilityIdentifier("media-screen-stop")
                } else {
                    Button { model.server.requestScreen(peerID: peer.id, expectedGeneration: peer.trustGeneration) } label: { Label("重新投屏", systemImage: "arrow.clockwise") }.disabled(!connected).accessibilityIdentifier("media-screen-retry")
                }
            }.controlSize(.regular).padding(.horizontal, 19).padding(.vertical, 14).background(.bar)
            Divider()
            HStack(spacing: 7) {
                Circle().fill(state?.screenState == "streaming" ? Color.green : active ? .orange : .gray).frame(width: 6, height: 6)
                Text(statusTitle).font(.system(size: 11, weight: .medium))
                Spacer()
                Text("仅显示画面").font(.system(size: 10)).foregroundStyle(.secondary).help("操作手机请单独打开控制窗口并选择 HDC 调试目标。")
            }.padding(.horizontal, 21).padding(.vertical, 11)
            GeometryReader { proxy in
                let ratio = canvas.image.map { CGFloat($0.width) / CGFloat($0.height) } ?? (9.0 / 19.5)
                let width = max(1, min(proxy.size.width - 48, (proxy.size.height - 40) * ratio))
                ZStack {
                    RoundedRectangle(cornerRadius: 17).fill(Color(nsColor: NSColor(calibratedWhite: 0.07, alpha: 1)))
                    if let image = canvas.image {
                        Image(decorative: image, scale: 1).resizable().scaledToFit().accessibilityLabel("手机实时投屏画面").accessibilityIdentifier("media-screen-canvas")
                    } else {
                        VStack(spacing: 17) {
                            if active { ProgressView().controlSize(.large).tint(.white) }
                            else { Image(systemName: statusSymbol).font(.system(size: 37, weight: .ultraLight)) }
                            Text(statusTitle).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center)
                            Text(state?.screenMessage ?? "连接手机后可重新请求屏幕共享。")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }.foregroundStyle(.white.opacity(0.9)).padding(25)
                    }
                }.frame(width: width, height: width / ratio).clipShape(RoundedRectangle(cornerRadius: 17))
                    .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: .black.opacity(0.16), radius: 17, y: 9)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }.background(LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), NativeTheme.blueLight.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield").foregroundStyle(NativeTheme.muted)
                Text("需手机授权 · 可随时在手机停止").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if state?.screenState == "streaming" { Text("H.264 实时画面").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 18).padding(.vertical, 12).background(.bar)
        }.frame(minWidth: 430, minHeight: 500)
    }
}
struct PhoneAlbumPage: View {
    @EnvironmentObject var model: AppModel
    let peer: PeerView
    @State private var selected = Set<String>()
    @State private var preview: MediaAssetView?
    @State private var kind = "image"
    @State private var query = ""
    @State private var sort = "newest"
    @Environment(\.openWindow) private var openWindow
    private var downloadBusy: Bool { !value.downloading.isEmpty || value.queuedDownloads > 0 }
    private var navigationBlocked: Bool { pending || downloadBusy }
    private var value: DeviceMediaView {
        guard model.current(peer) else { return DeviceMediaView(peerId: peer.id) }
        return model.snapshot.media.first { $0.peerId == peer.id } ?? DeviceMediaView(peerId: peer.id)
    }
    private var connected: Bool { model.snapshot.peers.contains { $0.id == peer.id && $0.trustGeneration == peer.trustGeneration && $0.connected } }
    private var pending: Bool { ["awaiting", "selecting"].contains(value.albumState) }
    private var selection: [String] { value.assets.filter { $0.size <= 134217728 && selected.contains($0.id) }.map(\.id) }
    private var warning: Bool { !connected || ["denied", "error", "paused", "unsupported", "expired"].contains(value.albumState) }
    private var statusMessage: String {
        if !connected { return "手机未连接，连接后将恢复图库浏览。" }
        if downloadBusy {
            return value.downloading.isEmpty && value.queuedDownloads > 0
                ? value.albumMessage + " · 队列已保留，请点击“继续下载队列”。完成后可继续浏览。"
                : "正在下载或排队，请等待全部完成后再翻页、刷新、切换类型或查找。"
        }
        if kind == "video" { return value.albumMessage + " · 视频仅下载；完成后在传输记录打开或定位文件。" }
        if !value.albumCapable && value.albumState == "idle" { return "请升级手机端后使用图库浏览。" }
        if value.albumMessage == "已允许图库访问" { return "点击图片查看原图；下载将保存到“下载/续桥”。" }
        return value.albumMessage
    }

    var body: some View {
        VStack(spacing: 0) {
            BrowserHeader(title: "手机相册", symbol: "photo.on.rectangle", device: deviceLabel(peer.name, id: peer.id), connected: connected) {
                BrowserIconButton(title: "刷新图库", symbol: "arrow.clockwise", action: refresh)
                    .disabled(!connected || !value.albumCapable || navigationBlocked).accessibilityIdentifier("media-album-request")
            }
            Divider()
            selectionBar
            BrowserQueryBar(placeholder: "在整个图库中按名称查找", query: $query, sort: $sort,
                            options: [("newest", "最新优先"), ("oldest", "最早优先"), ("name", "名称")],
                            capable: value.browserQueryCapable, disabled: !connected || navigationBlocked, submit: search)
            BrowserStatus(message: statusMessage, busy: pending && connected, warning: warning)
            if value.assets.isEmpty {
                ContentUnavailableView {
                    Label(!connected ? "手机未连接" : pending ? "等待手机授权" : value.albumState == "shared" ? (kind == "image" ? "暂无图片" : "暂无视频") : "暂时无法浏览图库",
                          systemImage: !connected ? "wifi.slash" : "photo.on.rectangle.angled")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 154), spacing: 12)], spacing: 12) {
                        ForEach(value.assets) { asset in assetCard(asset) }
                    }.padding(20)
                }
            }
            Divider()
            footer
        }.background(NativeTheme.background).frame(minWidth: 740, minHeight: 520)
        .onAppear { refresh() }
        .onDisappear { preview = nil; model.server.leaveAlbum(peerID: peer.id, expectedGeneration: peer.trustGeneration) }
        .onChange(of: kind) { _, _ in refresh() }
        .onChange(of: value.grantId) { _, _ in selected.removeAll(); preview = nil }
        .onChange(of: value.albumQuery) { _, text in query = text }
        .onChange(of: value.albumSort) { _, text in sort = text }
        .onChange(of: value.albumOffset) { _, _ in selected.removeAll() }
        .onChange(of: connected) { _, live in if !live { preview = nil; selected.removeAll() } else { refresh() } }
        .onChange(of: value.albumCapable) { _, capable in if capable && value.albumState == "idle" { refresh() } }
        .sheet(item: $preview) { asset in
            AlbumOriginalPreview(peer: peer, asset: asset, grant: value.grantId, onClose: { preview = nil }).environmentObject(model)
        }
    }
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Picker("媒体类型", selection: $kind) {
                Label("图片", systemImage: "photo").tag("image")
                Label("视频", systemImage: "video").tag("video")
            }.pickerStyle(.segmented).frame(width: 172).disabled(!connected || navigationBlocked)
                .accessibilityIdentifier("media-album-kind")
            Spacer(minLength: 12)
            Button("全选本页") { selected = Set(value.assets.filter { $0.size <= 134217728 }.map(\.id)) }
                .disabled(value.assets.isEmpty || !connected).accessibilityIdentifier("media-album-select-all")
            Button("取消选择") { selected.removeAll() }.disabled(selected.isEmpty).accessibilityIdentifier("media-album-deselect")
            Button { download(selection); selected.removeAll() } label: { Label("下载所选", systemImage: "arrow.down.to.line") }
                .buttonStyle(.borderedProminent).disabled(selection.isEmpty || !connected).accessibilityIdentifier("media-album-download-selected")
        }.font(.system(size: 12)).controlSize(.regular).padding(.horizontal, 20).padding(.vertical, 12)
    }
    private func assetCard(_ asset: MediaAssetView) -> some View {
        let chosen = selected.contains(asset.id)
        return VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Button { preview = asset } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7).fill(NativeTheme.sidebar)
                        if let data = asset.preview, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().padding(3)
                        } else {
                            Image(systemName: asset.mimeType.hasPrefix("video/") ? "video" : "photo")
                                .font(.system(size: 28, weight: .light)).foregroundStyle(NativeTheme.muted)
                        }
                        if asset.mimeType.hasPrefix("video/") {
                            Image(systemName: "video.fill").font(.system(size: 20)).foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.3), radius: 3)
                        }
                    }.frame(height: 142).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!asset.mimeType.hasPrefix("image/"))
                    .accessibilityLabel("预览图片 " + asset.name).accessibilityIdentifier("media-album-preview-" + asset.id)
                Button {
                    if chosen { selected.remove(asset.id) } else { selected.insert(asset.id) }
                } label: {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20)).foregroundStyle(chosen ? NativeTheme.blue : NativeTheme.muted)
                        .background(.white, in: Circle()).padding(7)
                }.buttonStyle(.plain).disabled(asset.size > 134217728)
                    .accessibilityLabel((chosen ? "取消选择 " : "选择 ") + asset.name)
                    .accessibilityIdentifier("media-album-select-" + asset.id)
            }
            if asset.mimeType.hasPrefix("video/") { Text("视频 · 仅下载").font(.system(size: 10)).foregroundStyle(NativeTheme.muted) }
            Text(asset.name).font(.system(size: 12, weight: .medium)).lineLimit(1).help(asset.name)
            HStack(spacing: 4) {
                Text(readableBytes(asset.size)).font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
                Spacer(minLength: 0)
                Button { download([asset.id]) } label: {
                    Image(systemName: value.downloading == asset.id ? "ellipsis" : "arrow.down.to.line").frame(width: 26, height: 24)
                }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue)
                    .disabled(!connected || asset.size > 134217728 || value.downloading == asset.id)
                    .help(asset.size > 134217728 ? "超过下载大小上限" : "下载到“下载/续桥”")
                    .accessibilityLabel("下载 " + asset.name).accessibilityIdentifier("media-album-download-" + asset.id)
            }
        }.padding(10).background(chosen ? NativeTheme.blueLight : .white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chosen ? NativeTheme.blue.opacity(0.7) : NativeTheme.line, lineWidth: 1))
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Text("共 \(value.albumTotal) 项").foregroundStyle(NativeTheme.muted)
            if !selection.isEmpty { Text("已选 \(selection.count) 项").foregroundStyle(NativeTheme.blue) }
            if value.queuedDownloads > 0 { Text("等待下载 \(value.queuedDownloads) 项").foregroundStyle(NativeTheme.muted) }
            if value.downloading.isEmpty && value.queuedDownloads > 0 {
                Button("继续下载队列") { download([]) }.disabled(!connected)
            }
            Spacer(minLength: 8)
            if kind == "video" { Button("查看下载结果") { model.showTransfers(peer); openWindow(id: "main") } }
            Button { page(max(0, value.albumOffset - 30)) } label: { Image(systemName: "chevron.left").frame(width: 20, height: 20) }
                .disabled(!connected || value.albumOffset == 0 || navigationBlocked).accessibilityLabel("上一页").accessibilityIdentifier("media-album-previous")
            Text("第 \(value.albumOffset / 30 + 1) / \(max(1, (value.albumTotal + 29) / 30)) 页").monospacedDigit().foregroundStyle(NativeTheme.muted)
            Button { page(value.albumOffset + 30) } label: { Image(systemName: "chevron.right").frame(width: 20, height: 20) }
                .disabled(!connected || value.albumOffset + 30 >= value.albumTotal || navigationBlocked).accessibilityLabel("下一页").accessibilityIdentifier("media-album-next")
        }.font(.system(size: 11)).controlSize(.regular).padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
    }
    private func refresh() { guard connected, !navigationBlocked else { return }; selected.removeAll(); preview = nil; model.server.requestAlbum(peerID: peer.id, expectedGeneration: peer.trustGeneration, kind: kind) }
    private func page(_ offset: Int) { guard connected, !navigationBlocked else { return }; selected.removeAll(); preview = nil; model.server.listAlbum(peerID: peer.id, expectedGeneration: peer.trustGeneration, offset: offset) }
    private func search() {
        guard connected, !navigationBlocked, value.browserQueryCapable,
              query.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count <= 128 else { return }
        selected.removeAll(); preview = nil
        model.server.listAlbum(peerID: peer.id, expectedGeneration: peer.trustGeneration, offset: 0,
                               query: query.trimmingCharacters(in: .whitespacesAndNewlines), sort: sort)
    }
    private func download(_ ids: [String]) { model.server.downloadAlbum(peerID: peer.id, expectedGeneration: peer.trustGeneration, assetIDs: ids) }
}
