import SwiftUI
import XuQiaoCore

struct DevicesPage: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("devices.collapsed") private var collapsedData = Data()
    @AppStorage("devices.expanded") private var expandedData = Data()
    @State private var removing: PeerView?
    @State private var notice: String?
    @State private var showingUsage = false
    // 稳定分组：连接状态变化立即更新位置，同状态内保留原顺序与设备身份。
    private var orderedPeers: [PeerView] {
        model.snapshot.peers.filter(\.connected) + model.snapshot.peers.filter { !$0.connected }
    }
    private var collapsed: Set<String> { Set((try? JSONDecoder().decode([String].self, from: collapsedData)) ?? []) }
    private var explicitlyExpanded: Set<String> { Set((try? JSONDecoder().decode([String].self, from: expandedData)) ?? []) }
    // 离线默认折叠；显式展开/折叠持久化，不由重连覆盖用户选择。
    private func isCollapsed(_ peer: PeerView) -> Bool {
        collapsed.contains(peer.id) || (!peer.connected && !explicitlyExpanded.contains(peer.id))
    }
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("我的设备").font(.system(size: 24, weight: .semibold))
                Text("\(model.snapshot.peers.count) 台已配对 · \(model.snapshot.peers.filter(\.connected).count) 台已连接").font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
            }
            Spacer()
            Button { showingUsage.toggle() } label: { Label("使用说明", systemImage: "questionmark.circle") }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
                .accessibilityIdentifier("devices-usage-help")
                .popover(isPresented: $showingUsage, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("使用说明").font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeTheme.ink)
                    Text("手机投屏：在手机确认屏幕共享后查看画面，无需无线调试。")
                    Text("控制手机：需开启 USB 或无线调试，并使用已信任的调试连接。")
                    Text("手机相册与文件浏览：通过局域网访问已授权内容，无需开发者模式。")
                }.font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(20).frame(width: 360)
                }
            Button { model.showPairing() } label: { Label("添加设备", systemImage: "plus") }.buttonStyle(.borderedProminent)
        }
        if let notice { NativeNotice(text: notice) }
        if model.snapshot.peers.isEmpty {
            ContentUnavailableView { Label("还没有已配对设备", systemImage: "laptopcomputer.and.iphone") } description: { Text("连接一次，之后可在同一网络自动重连。") } actions: { Button("连接新手机") { model.showPairing() }.buttonStyle(.borderedProminent) }.padding(.vertical, 40)
        }
        ForEach(orderedPeers) { peer in
            deviceSection(peer)
        }
        .alert("移除设备信任？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("取消", role: .cancel) { removing = nil }
            Button("移除", role: .destructive) {
                if let peer = removing, model.current(peer) { model.server.remove(peerID: peer.id, expectedGeneration: peer.trustGeneration) }
                else { notice = "设备已更新，请重新确认" }
                removing = nil
            }
        } message: { Text("移除“\(removing.map { deviceLabel($0.name, id: $0.id) } ?? "设备")”后将断开连接，下次需要重新配对。本地记录与已保存文件保留。") }
    }
    private func deviceSection(_ peer: PeerView) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "iphone").font(.system(size: 22, weight: .light)).foregroundStyle(peer.connected ? NativeTheme.blue : NativeTheme.muted).frame(width: 36, height: 39).background(peer.connected ? NativeTheme.blueLight : NativeTheme.sidebar, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 7) {
                    Text(deviceLabel(peer.name, id: peer.id)).font(.system(size: 17, weight: .semibold)).lineLimit(1).help(deviceLabel(peer.name, id: peer.id))
                    HStack(spacing: 9) {
                        NativeStatus(title: peer.connected ? "已连接" : peer.paused ? "已暂停" : "等待重连", color: peer.connected ? .green : peer.paused ? .orange : NativeTheme.muted)
                        Text(syncTitle(peer)).font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
                    }
                }
                Spacer(minLength: 7)
                if peer.connected {
                    Button("断开") { if model.current(peer) { model.server.disconnect(peerID: peer.id, expectedGeneration: peer.trustGeneration) } }.controlSize(.small)
                } else if peer.paused {
                    Button("允许重连") {
                        guard model.current(peer) else { return }
                        model.server.allowReconnect(peerID: peer.id, expectedGeneration: peer.trustGeneration)
                        notice = "已允许 \(peer.name) 重连。请在手机打开续桥并点“重新连接”。"
                    }.controlSize(.small)
                }
                Menu { Button("移除信任…", role: .destructive) { removing = peer } } label: { Image(systemName: "ellipsis").frame(width: 20, height: 26) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).help("设备管理").accessibilityLabel("设备管理")
                Button { toggle(peer) } label: { Image(systemName: isCollapsed(peer) ? "chevron.down" : "chevron.up").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 28) }.buttonStyle(.plain).foregroundStyle(NativeTheme.muted).help(isCollapsed(peer) ? "展开设备功能" : "折叠设备功能").accessibilityLabel((isCollapsed(peer) ? "展开 " : "折叠 ") + peer.name)
            }.padding(13)
            if !isCollapsed(peer) {
                Rectangle().fill(NativeTheme.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 15) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 11) {
                        mediaAction("手机投屏",symbol:"display",peer:peer,screen:true){model.showScreen(peer)}
                        controlAction(peer)
                        mediaAction("手机相册",symbol:"photo.on.rectangle",peer:peer,screen:false){model.showAlbum(peer)}
                        filesAction(peer)
                    }
                    HStack(spacing: 0) {
                        deviceAction("剪贴板记录", symbol: "clipboard", disabled: false) { model.showClipboard(peer) }
                        Rectangle().fill(NativeTheme.line).frame(width: 1, height: 26)
                        deviceAction("传输记录", symbol: "arrow.left.arrow.right", disabled: false) { model.showTransfers(peer) }
                        Rectangle().fill(NativeTheme.line).frame(width: 1, height: 26)
                        deviceAction("发送文件", symbol: "square.and.arrow.up", disabled: !peer.connected || !peer.fileCapable || busy(peer)) { if model.current(peer) { model.sendFilesPeer = peer } }
                    }
                    if !peer.connected { Text(peer.paused ? "连接已暂停；允许重连后，请在手机上点“重新连接”。" : "网络恢复后会自动重连。离线时仍可查看本地记录。").font(.system(size: 11)).foregroundStyle(NativeTheme.muted) }
                }.padding(18)
            }
        }.background(.white, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(NativeTheme.line, lineWidth: 1))
    }
    private func controlAction(_ peer: PeerView) -> some View {
        Button { model.showDebugControl(peer) } label: {
            HStack(spacing: 9) {
                Image(systemName: "cursorarrow.click").font(.system(size: 18, weight: .light)).foregroundStyle(peer.connected ? NativeTheme.blue : NativeTheme.muted)
                VStack(alignment: .leading, spacing: 5) {
                    Text("控制手机").font(.system(size: 12, weight: .medium)).foregroundStyle(peer.connected ? NativeTheme.ink : NativeTheme.muted)
                    Text(peer.connected ? "打开手机控制" : "连接后可用").font(.system(size: 10)).foregroundStyle(NativeTheme.muted)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 47, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 5)
                .background(NativeTheme.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!peer.connected).help(peer.connected ? "打开控制窗口，使用已信任的调试连接" : "连接手机后可用")
            .accessibilityIdentifier("device-control-open-card")
    }
    private func mediaAction(_ title:String,symbol:String,peer:PeerView,screen:Bool,action:@escaping()->Void)->some View {
        let capability=model.snapshot.media.first{$0.peerId==peer.id}
        let enabled=peer.connected && (!screen || capability?.screenCapable==true)
        return Button(action:action){HStack(spacing:9){Image(systemName:symbol).font(.system(size:18,weight:.light)).foregroundStyle(enabled ? NativeTheme.blue:NativeTheme.muted);VStack(alignment:.leading,spacing:5){Text(title).font(.system(size:12,weight:.medium));Text(!peer.connected ? "连接后可用":enabled ? screen ? "在手机确认后开始":"授权后通过局域网浏览":"需手机新版支持").font(.system(size:10)).foregroundStyle(NativeTheme.muted)};Spacer(minLength:0)}.frame(maxWidth:.infinity,minHeight:47,alignment:.leading).padding(.horizontal,12).padding(.vertical,5).background(enabled ? NativeTheme.blueLight.opacity(0.5):NativeTheme.sidebar.opacity(0.65),in:RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain).disabled(!enabled).accessibilityIdentifier(screen ? "media-screen-open-"+peer.id:"media-album-open-"+peer.id)
    }
    private func filesAction(_ peer: PeerView) -> some View {
        let enabled = peer.connected
        return Button { model.showFiles(peer) } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder").font(.system(size: 18, weight: .light)).foregroundStyle(enabled ? NativeTheme.blue : NativeTheme.muted)
                VStack(alignment: .leading, spacing: 5) {
                    Text("文件浏览").font(.system(size: 12, weight: .medium))
                    Text(!peer.connected ? "连接后可用" : "自动浏览已授权范围").font(.system(size: 10)).foregroundStyle(NativeTheme.muted)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 47, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 5)
                .background(enabled ? NativeTheme.blueLight.opacity(0.5) : NativeTheme.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!enabled).accessibilityIdentifier("files-browser-open-" + peer.id)
    }
    private func planned(_ title: String, symbol: String) -> some View {
        Button {} label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(NativeTheme.muted)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12, weight: .medium)); Text("待开发").font(.system(size: 10)).foregroundStyle(NativeTheme.muted) }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 47, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 5).background(NativeTheme.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(true).help("此功能将在后续版本接入")
    }
    private func deviceAction(_ title: String, symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.system(size: 12)).frame(maxWidth: .infinity).frame(height: 33) }.buttonStyle(.plain).foregroundStyle(disabled ? NativeTheme.muted.opacity(0.6) : NativeTheme.blue).disabled(disabled)
    }
    private func toggle(_ peer: PeerView) {
        var closed = collapsed, opened = explicitlyExpanded
        if isCollapsed(peer) { closed.remove(peer.id); opened.insert(peer.id) }
        else { closed.insert(peer.id); opened.remove(peer.id) }
        collapsedData = (try? JSONEncoder().encode(Array(closed).sorted())) ?? Data()
        expandedData = (try? JSONEncoder().encode(Array(opened).sorted())) ?? Data()
    }
    private func busy(_ peer: PeerView) -> Bool { model.snapshot.files.preparingPeerIds.contains(peer.id) || model.snapshot.files.tasks.contains { $0.peerId == peer.id && !$0.state.terminal } }
    private func syncTitle(_ peer: PeerView) -> String {
        guard model.snapshot.clipboardPreferences.enabled else { return "本机自动同步已关闭" }
        if let value = model.snapshot.clipboardPeers.first(where: { $0.id == peer.id }), value.capable && !value.remoteAccept { return "手机当前暂停接收" }
        return "已信任设备"
    }
}

struct SendFilesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let peer: PeerView
    private var current: PeerView? { model.snapshot.peers.first { $0.id == peer.id && $0.trustGeneration == peer.trustGeneration } }
    private var busy: Bool { model.snapshot.files.preparingPeerIds.contains(peer.id) || model.snapshot.files.tasks.contains { $0.peerId == peer.id && !$0.state.terminal } }
    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack { Text("发送文件").font(.system(size: 20, weight: .semibold)); Spacer(); Button("取消") { dismiss() } }
            HStack(spacing: 12) { Image(systemName: "iphone").font(.system(size: 27, weight: .light)).foregroundStyle(NativeTheme.blue); VStack(alignment: .leading, spacing: 5) { Text(deviceLabel(peer.name, id: peer.id)).font(.system(size: 14, weight: .medium)); Text(current?.connected == true ? "仅发送到这台设备" : "设备未连接").font(.system(size: 12)).foregroundStyle(NativeTheme.muted) } }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(NativeTheme.blueLight, in: RoundedRectangle(cornerRadius: 11))
            Text(busy ? "这台设备正在传输，完成后可继续发送。" : current?.groupCapable == true ? "选择文件或文件夹，最多 100 个顶层项目。对方确认后开始传输。" : "选择一份文件。对方确认后开始传输。").font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
            HStack { Spacer(); Button("选择文件…") { guard let current, current.connected else { return }; dismiss(); model.chooseFile(peerID: peer.id, allowGroups: current.groupCapable, expectedGeneration: peer.trustGeneration) }.buttonStyle(.borderedProminent).disabled(current?.connected != true || current?.fileCapable != true || busy) }
        }.padding(26).frame(width: 440)
            .onChange(of: model.snapshot.peers.map { $0.id + $0.trustGeneration }) { _, _ in if current == nil { dismiss() } }
    }
}
