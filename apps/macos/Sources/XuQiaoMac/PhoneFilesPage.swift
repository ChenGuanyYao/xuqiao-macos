import SwiftUI
import XuQiaoCore

/// 只投影当前设备本次授权中的元数据；目录ID始终由对端给出，不从文件名或路径推导。
struct PhoneFilesPage: View {
    @EnvironmentObject var model: AppModel
    let peer: PeerView
    @State private var query = ""
    @State private var sort = "name"
    @State private var selected = Set<String>()
    @State private var confirmForget = false
    @State private var detail: DirectoryEntryView?
    private var value: DeviceMediaView {
        guard model.current(peer) else { return DeviceMediaView(peerId: peer.id) }
        return model.snapshot.media.first { $0.peerId == peer.id } ?? DeviceMediaView(peerId: peer.id)
    }
    private var connected: Bool { model.snapshot.peers.contains { $0.id == peer.id && $0.trustGeneration == peer.trustGeneration && $0.connected } }
    private var loading: Bool { ["awaiting", "selecting", "loading"].contains(value.filesState) }
    private var downloadable: [DirectoryEntryView] { value.filesEntries.filter { !$0.isDirectory && $0.downloadable } }
    private var selection: [String] { downloadable.filter { selected.contains($0.id) }.map(\.id) }

    private var warning: Bool { !connected || ["error", "denied", "paused", "expired", "unsupported"].contains(value.filesState) || value.filesSkippedCount > 0 }
    private var statusMessage: String {
        if !connected { return "手机未连接，连接后将恢复已有授权范围。" }
        if !value.filesCapable && value.filesState == "idle" { return "请升级手机端后使用文件浏览。" }
        let message = value.filesMessage
        return value.filesSkippedCount > 0 ? message + " · \(value.filesSkippedCount) 项暂不支持显示" : message
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            breadcrumbs
            BrowserQueryBar(placeholder: "在当前文件夹中查找", query: $query, sort: $sort,
                            options: [("name", "名称"), ("modified", "最近修改"), ("size", "大小")],
                            capable: value.browserQueryCapable, disabled: !connected || loading, submit: search)
            selectionBar
            BrowserStatus(message: statusMessage, busy: loading && connected, warning: warning)
            if loading {
                ContentUnavailableView { Label(value.filesState == "loading" ? "正在读取文件" : "等待手机授权", systemImage: "folder") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if value.filesEntries.isEmpty {
                ContentUnavailableView { Label(emptyTitle, systemImage: connected ? "folder" : "wifi.slash") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                columnHeader
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(value.filesEntries) { entry in entryRow(entry) }
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            Divider()
            footer
        }.background(NativeTheme.background).frame(minWidth: 740, minHeight: 520)
            .onChange(of: value.filesGrantId) { _, _ in selected.removeAll(); detail = nil }
            .onChange(of: value.filesFolderId) { _, _ in selected.removeAll(); detail = nil }
            .onChange(of: value.filesQuery) { _, text in query = text }
            .onChange(of: value.filesSort) { _, text in sort = text }
            .onChange(of: value.filesOffset) { _, _ in selected.removeAll() }
            .onChange(of: connected) { _, live in if !live { selected.removeAll(); detail = nil } else { refresh() } }
            .onChange(of: value.filesCapable) { _, capable in if capable && value.filesState == "idle" { refresh() } }
            .onAppear { refresh() }
            .onDisappear { model.server.leaveFiles(peerID: peer.id, expectedGeneration: peer.trustGeneration) }
            .confirmationDialog("清除已保存文件授权？", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("清除授权", role: .destructive) { model.server.forgetFiles(peerID: peer.id, expectedGeneration: peer.trustGeneration) }
            } message: { Text("只移除这台设备已保存的访问范围，不删除文件。下次需要重新添加范围。") }
            .sheet(item: $detail) { entry in detailPanel(entry) }
    }
    private var header: some View {
        BrowserHeader(title: "手机文件", symbol: "folder", device: deviceLabel(peer.name, id: peer.id), connected: connected) {
            Button { choose() } label: { Label("添加访问范围…", systemImage: "folder.badge.plus") }
                .controlSize(.regular).disabled(!connected || !value.filesCapable || loading).accessibilityIdentifier("files-browser-request")
            BrowserIconButton(title: "刷新已保存范围", symbol: "arrow.clockwise", action: refresh)
                .disabled(!connected || loading).accessibilityIdentifier("files-browser-refresh")
            Menu {
                if !value.filesGrantId.isEmpty {
                    Button("结束共享") { model.server.revokeFiles(peerID: peer.id, expectedGeneration: peer.trustGeneration) }
                        .accessibilityIdentifier("files-browser-revoke")
                    Divider()
                }
                Button("清除已保存文件授权…", role: .destructive) { confirmForget = true }
            } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(!connected || loading).help("文件授权管理").accessibilityLabel("文件授权管理")
                .accessibilityIdentifier("files-browser-forget")
        }
    }
    private var breadcrumbs: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(NativeTheme.blue)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 只允许对端返回的真实目录ID参与导航，虚拟根也不推导本机路径。
                    ForEach(value.filesBreadcrumbs) { crumb in
                        Button(crumb.name) { list(crumb.id, offset: 0) }.buttonStyle(.plain)
                            .foregroundStyle(crumb.id == value.filesFolderId ? NativeTheme.ink : NativeTheme.blue)
                            .disabled(!connected || loading || crumb.id == value.filesFolderId)
                            .accessibilityIdentifier("files-browser-crumb-" + crumb.id)
                        if crumb.id != value.filesBreadcrumbs.last?.id {
                            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(NativeTheme.muted)
                        }
                    }
                }
            }
        }.font(.system(size: 12)).frame(height: 36).padding(.horizontal, 20).background(.white)
    }
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button("全选本页") { selected = Set(downloadable.map(\.id)) }
                .disabled(downloadable.isEmpty || !connected).accessibilityIdentifier("files-browser-select-all")
            Button("取消选择") { selected.removeAll() }.disabled(selected.isEmpty).accessibilityIdentifier("files-browser-deselect")
            Spacer(minLength: 12)
            Button { download(selection); selected.removeAll() } label: { Label("下载所选", systemImage: "arrow.down.to.line") }
                .buttonStyle(.borderedProminent).disabled(selection.isEmpty || !connected).accessibilityIdentifier("files-browser-download-selected")
        }.font(.system(size: 12)).controlSize(.regular).padding(.horizontal, 20).padding(.vertical, 12)
    }
    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
            Text("大小").frame(width: 82, alignment: .trailing)
            Text("修改日期").frame(width: 104, alignment: .leading)
            Text("操作").frame(width: 72)
        }.font(.system(size: 11, weight: .medium)).foregroundStyle(NativeTheme.muted)
            .padding(.horizontal, 20).padding(.vertical, 9).background(NativeTheme.sidebar.opacity(0.4))
    }
    private func entryRow(_ entry: DirectoryEntryView) -> some View {
        let chosen = selected.contains(entry.id)
        return HStack(spacing: 12) {
            if !entry.isDirectory && entry.downloadable {
                Button { if chosen { selected.remove(entry.id) } else { selected.insert(entry.id) } } label: {
                    Image(systemName: chosen ? "checkmark.square.fill" : "square")
                        .foregroundStyle(chosen ? NativeTheme.blue : NativeTheme.muted.opacity(0.6)).frame(width: 18, height: 30)
                }.buttonStyle(.plain).accessibilityLabel((chosen ? "取消选择 " : "选择 ") + entry.name)
                    .accessibilityIdentifier("files-browser-select-" + entry.id)
            } else { Color.clear.frame(width: 18, height: 30) }
            Button {
                if entry.isDirectory { list(entry.id, offset: 0) } else { detail = entry }
            } label: {
                HStack(spacing: 10) {
                    ContentTypeIcon(kind: entry.isDirectory ? "folder" : "file", name: entry.name, size: 30)
                    Text(entry.name).font(.system(size: 13, weight: .medium)).foregroundStyle(NativeTheme.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!connected).help(entry.name).accessibilityIdentifier("files-browser-entry-" + entry.id)
            Text(entry.isDirectory ? "—" : readableBytes(entry.size)).frame(width: 82, alignment: .trailing)
            Group {
                if entry.modifiedAt > 0 { Text(Date(timeIntervalSince1970: Double(entry.modifiedAt) / 1000), style: .date) }
                else { Text("—") }
            }.frame(width: 104, alignment: .leading)
            HStack(spacing: 8) {
                Button { detail = entry } label: { Image(systemName: "info.circle").frame(width: 30, height: 30) }
                    .buttonStyle(.plain).help("显示信息").accessibilityLabel("显示信息 " + entry.name)
                    .accessibilityIdentifier("files-browser-info-" + entry.id)
                if entry.isDirectory {
                    Button { list(entry.id, offset: 0) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 30) }
                        .buttonStyle(.plain).disabled(!connected || loading).help("打开文件夹").accessibilityLabel("打开文件夹 " + entry.name)
                } else {
                    Button { download([entry.id]) } label: {
                        Image(systemName: value.filesDownloading == entry.id ? "ellipsis" : "arrow.down.to.line").frame(width: 30, height: 30)
                    }.buttonStyle(.plain).disabled(!connected || !entry.downloadable || value.filesDownloading == entry.id)
                        .help(entry.downloadable ? "下载到“下载/续桥”" : "超过下载大小上限")
                        .accessibilityLabel("下载 " + entry.name).accessibilityIdentifier("files-browser-download-" + entry.id)
                }
            }.foregroundStyle(NativeTheme.blue).frame(width: 72)
        }.font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(chosen ? NativeTheme.blueLight : .white, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(chosen ? NativeTheme.blue.opacity(0.45) : .clear))
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Text("共 \(value.filesTotal) 项").foregroundStyle(NativeTheme.muted)
            if !selection.isEmpty { Text("已选 \(selection.count) 个文件").foregroundStyle(NativeTheme.blue) }
            if !value.filesDownloading.isEmpty { Text("正在下载").foregroundStyle(NativeTheme.muted) }
            else if value.filesQueuedDownloads > 0 { Text("等待下载 \(value.filesQueuedDownloads) 项").foregroundStyle(NativeTheme.muted) }
            if value.filesDownloading.isEmpty && value.filesQueuedDownloads > 0 {
                Button("继续下载队列") { model.server.downloadFiles(peerID: peer.id, expectedGeneration: peer.trustGeneration, entryIDs: []) }.disabled(!connected)
            }
            Spacer(minLength: 8)
            Button { list(value.filesFolderId, offset: max(0, value.filesOffset - 30)) } label: { Image(systemName: "chevron.left").frame(width: 20, height: 20) }
                .disabled(!connected || loading || value.filesOffset == 0).accessibilityLabel("上一页").accessibilityIdentifier("files-browser-previous")
            Text("第 \(value.filesOffset / 30 + 1) / \(max(1, (value.filesTotal + 29) / 30)) 页").monospacedDigit().foregroundStyle(NativeTheme.muted)
            Button { list(value.filesFolderId, offset: value.filesOffset + 30) } label: { Image(systemName: "chevron.right").frame(width: 20, height: 20) }
                .disabled(!connected || loading || value.filesOffset + 30 >= value.filesTotal).accessibilityLabel("下一页").accessibilityIdentifier("files-browser-next")
        }.font(.system(size: 11)).controlSize(.regular).padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
    }
    private var emptyTitle: String {
        if !connected { return "手机未连接" }
        if value.filesState == "error" { return "暂时无法读取文件" }
        return value.filesGrantId.isEmpty ? "尚未共享文件" : "这里还没有文件"
    }
    private func detailPanel(_ entry: DirectoryEntryView) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(entry.isDirectory ? "文件夹信息" : "文件信息").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("完成") { detail = nil }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    ContentTypeIcon(kind: entry.isDirectory ? "folder" : "file", name: entry.name, size: 48)
                    Text(entry.name).font(.system(size: 15, weight: .medium)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                    GridRow { Text("类型").foregroundStyle(NativeTheme.muted); Text(entry.isDirectory ? "文件夹" : "文件") }
                    if !entry.isDirectory { GridRow { Text("大小").foregroundStyle(NativeTheme.muted); Text(readableBytes(entry.size)).monospacedDigit() } }
                    if entry.modifiedAt > 0 {
                        GridRow { Text("修改时间").foregroundStyle(NativeTheme.muted); Text(Date(timeIntervalSince1970: Double(entry.modifiedAt) / 1000).formatted(date: .abbreviated, time: .shortened)) }
                    }
                    GridRow { Text("设备").foregroundStyle(NativeTheme.muted); Text(deviceLabel(peer.name, id: peer.id)).textSelection(.enabled) }
                }.font(.system(size: 12)).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(NativeTheme.sidebar, in: RoundedRectangle(cornerRadius: 8))
            }.padding(20)
            Divider()
            HStack {
                Text(entry.isDirectory ? "仅浏览已授权内容" : "保存到“下载/续桥”").font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
                Spacer()
                if !entry.isDirectory {
                    Button { download([entry.id]); detail = nil } label: { Label("下载文件", systemImage: "arrow.down.to.line") }
                        .buttonStyle(.borderedProminent).disabled(!connected || !entry.downloadable)
                }
            }.padding(20)
        }.background(NativeTheme.background).frame(width: 480)
    }
    private func refresh(){guard connected else{return};selected.removeAll();detail=nil;model.server.requestFiles(peerID:peer.id,expectedGeneration:peer.trustGeneration)}
    private func choose() { selected.removeAll(); detail = nil; model.server.authorizeFiles(peerID: peer.id, expectedGeneration: peer.trustGeneration) }
    private func list(_ folder: String, offset: Int) { guard !folder.isEmpty, connected else { return }; selected.removeAll(); model.server.listFiles(peerID: peer.id, expectedGeneration: peer.trustGeneration, folderID: folder, offset: offset) }
    private func search() {
        guard connected, !loading, value.browserQueryCapable, !value.filesFolderId.isEmpty,
              query.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count <= 128 else { return }
        selected.removeAll(); detail = nil
        model.server.listFiles(peerID: peer.id, expectedGeneration: peer.trustGeneration,
                               folderID: value.filesFolderId, offset: 0,
                               query: query.trimmingCharacters(in: .whitespacesAndNewlines), sort: sort)
    }
    private func download(_ ids: [String]) { guard connected, !ids.isEmpty else { return }; model.server.downloadFiles(peerID: peer.id, expectedGeneration: peer.trustGeneration, entryIDs: ids) }
}
