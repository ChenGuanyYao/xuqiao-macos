import SwiftUI
import XuQiaoCore
import AppKit
import ImageIO

private struct FileClearPrompt: Identifiable {
    let id = UUID()
    let items: [FileTaskSelection]
    let epoch: UUID
    let all: Bool
}

struct FileTransfersPage: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("files.direction") private var direction = "all"
    @AppStorage("files.status") private var status = "all"
    @State private var search = ""
    @State private var selected: [String: String] = [:]
    @State private var details: FileTaskView?
    @State private var sending = false
    @State private var prompt: FileClearPrompt?
    @State private var managementEpoch = UUID()
    private var noticeIdentity: UUID { model.transferOperationNoticeID }
    private var notice: String? {
        get { model.transferOperationNotice }
        nonmutating set { model.transferOperationNotice = newValue }
    }
    @State private var cleaning = false
    private var exporting: Bool { model.snapshot.files.batchExport?.state == "exporting" }
    private var sendablePeers: [PeerView] {
        model.snapshot.peers.filter { peer in peer.connected && peer.fileCapable && model.canChooseFile(peerID: peer.id) }
    }
    private var sendUnavailable: String {
        guard model.snapshot.peers.contains(where: { $0.connected && $0.fileCapable }) else { return "连接手机后可发送" }
        return "正在选择或准备文件，或设备普通任务已达50项"
    }
    private var history: [FileTaskView] { model.snapshot.files.tasks.filter(\.isFileTransferRecord) }
    private var visible: [FileTaskView] {
        let query = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        return history.filter { task in
            (model.filePeer.isEmpty || task.peerId == model.filePeer) &&
            (direction == "all" || task.direction.rawValue == direction) &&
            (status == "all" || status == "active" && !task.state.terminal || status == "completed" && task.state == .completed || status == "failed" && [.failed, .interrupted, .rejected, .cancelled].contains(task.state)) &&
            (query.isEmpty || ([task.name + " " + peerName(task)] + task.roots).contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    private var peers: [(id: String, name: String)] {
        var result = Dictionary(model.snapshot.peers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for task in history where result[task.peerId] == nil { result[task.peerId] = "原来源设备" }
        if !model.filePeer.isEmpty && result[model.filePeer] == nil { result[model.filePeer] = "原来源设备" }
        return result.map { (id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            if let error = model.snapshot.error {
                HStack { NativeNotice(text: error, warning: true); if !model.snapshot.ready { Button("重试连接") { model.server.retry() } } }
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) { Text("文件传输").font(.system(size: 24, weight: .semibold)); Text("文件与目录，保留原来的名字和层级。").font(.system(size: 12)).foregroundStyle(NativeTheme.muted) }
                Spacer()
                if sendablePeers.isEmpty { Text(sendUnavailable).font(.system(size: 11)).foregroundStyle(NativeTheme.muted) }
                Button { sending = true } label: { Label("发送文件", systemImage: "plus") }.buttonStyle(.borderedProminent)
                    .disabled(sendablePeers.isEmpty).help(sendablePeers.isEmpty ? sendUnavailable : "选择文件发送，通道占满时自动排队")
            }.padding(.bottom, 4)
            HStack(spacing: 11) {
                NativeSearchField(placeholder: "搜索文件名、组内文件或设备", text: $search, identifier: "files-search")
                Picker("设备", selection: $model.filePeer) { Text("全部设备").tag(""); ForEach(peers, id: \.id) { Text(deviceLabel($0.name, id: $0.id)).tag($0.id) } }.labelsHidden().controlSize(.small).frame(width: 150).help(peers.first { $0.id == model.filePeer }.map { deviceLabel($0.name, id: $0.id) } ?? "全部设备")
                if !history.isEmpty { Menu { Button("全部清理…", role: .destructive) { prepareClear(all: true) }; Button("缓存与存储") { model.selection = .storage } } label: { Image(systemName: "ellipsis").frame(width: 20, height: 26) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).help("传输记录管理").accessibilityLabel("传输记录管理") }
            }
            HStack {
                Picker("传输方向", selection: $direction) { Text("全部").tag("all"); Text("发送").tag("outgoing"); Text("接收").tag("incoming") }.pickerStyle(.segmented).frame(width: 205)
                Spacer()
                Picker("状态", selection: $status) { Text("全部状态").tag("all"); Text("进行中").tag("active"); Text("已完成").tag("completed"); Text("失败或中断").tag("failed") }.labelsHidden().controlSize(.small).frame(width: 132)
            }
            ForEach(model.snapshot.files.preparations) { preparation in
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在准备文件 · " + (model.snapshot.peers.first { $0.id == preparation.peerId }?.name ?? "设备")).font(.system(size: 12)); Spacer(); Button("取消") { model.server.cancelPreparation(peerID: preparation.peerId, expectedPreparation: preparation.id) } }.padding(13).background(NativeTheme.blueLight, in: RoundedRectangle(cornerRadius: 9))
            }
            OperationNotice(text: Binding(get: { notice }, set: { notice = $0 })).id(noticeIdentity)
            if let batch = model.snapshot.files.batchExport, model.hiddenBatchExportID != batch.id { BatchExportStatus(status: batch).environmentObject(model) }
            // 传输历史可持续增长；只实例化视口附近卡片及其预览任务，切页不再布局全部历史。
            LazyVStack(spacing: 9) {
                if !visible.isEmpty { HStack(spacing: 10) {
                    Button("全选当前筛选") { selected = Dictionary(visible.map { ($0.id, $0.attemptId) }, uniquingKeysWith: { first, _ in first }) }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue)
                    if !selected.isEmpty { Button("取消选择") { selected.removeAll() }.buttonStyle(.plain).foregroundStyle(NativeTheme.muted) }
                    Spacer(); Text("\(visible.count) 条").foregroundStyle(NativeTheme.muted); Button("全部清理…") { prepareClear(all: true) }.buttonStyle(.plain).foregroundStyle(NativeTheme.muted).disabled(cleaning)
                }.font(.system(size: 11)).padding(.horizontal, 15).frame(height: 39)
                    .background(NativeTheme.sidebar.opacity(0.55), in: RoundedRectangle(cornerRadius: 10)) }
                if visible.isEmpty {
                    ContentUnavailableView {
                        Label(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无传输记录" : "未找到相关记录", systemImage: "arrow.left.arrow.right")
                    } description: {
                        Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (model.filePeer.isEmpty && direction == "all" && status == "all" ? "选择文件发送，或从手机发送到这台 Mac。" : "没有符合当前筛选的记录。") : "试试其他关键词，或清除搜索查看当前筛选的记录。")
                    } actions: {
                        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Button("清除搜索") { search = "" }.accessibilityIdentifier("files-search-empty-clear") }
                    }.frame(maxWidth: .infinity, minHeight: 250)
                        .background(NativeTheme.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativeTheme.line, lineWidth: 0.8).allowsHitTesting(false))
                }
                ForEach(visible) { task in taskRow(task) }
            }
        }.padding(26)
        }
        // 固定在主窗内容底部，滚动历史不会带走已选操作。
        .safeAreaInset(edge: .bottom, spacing: 0) {
                if !selected.isEmpty {
                    HStack(spacing: 14) { Text("已选择 \(selected.count) 条").foregroundStyle(NativeTheme.muted); Spacer(); Button("保存已接收项…") { saveSelected() }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue).disabled(exporting); Button("清理所选…") { prepareClear(all: false) }.buttonStyle(.plain).foregroundStyle(.red).disabled(cleaning) }.font(.system(size: 11)).padding(14).background(NativeTheme.blueLight.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
        }
        .onChange(of: model.snapshot.clipboardContext) { _, _ in invalidate() }
        .onChange(of: direction) { _, _ in invalidate() }
        .onChange(of: status) { _, _ in invalidate() }
        .onChange(of: search) { _, _ in invalidate() }
        .onChange(of: model.filePeer) { _, _ in UserDefaults.standard.set(model.filePeer, forKey: "files.peer"); invalidate() }
        .onChange(of: history.map { $0.id + $0.attemptId }) { _, _ in selected = selected.filter { id, attempt in history.contains { $0.id == id && $0.attemptId == attempt } } }
        .onDisappear { managementEpoch = UUID() }
        .sheet(isPresented: $sending) { FileSendPickerSheet().environmentObject(model) }
        .sheet(item: $details) { task in GroupDetailsSheet(id: task.id, attempt: task.attemptId).environmentObject(model) }
        .alert(prompt?.all == true ? "清理全部传输历史？" : "清理所选传输历史？", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { frozen in
            Button("取消", role: .cancel) { prompt = nil }
            Button("清理 \(frozen.items.count) 条", role: .destructive) {
                guard frozen.epoch == managementEpoch else { notice = "筛选已变化，请重新确认"; prompt = nil; return }
                cleaning = true
                notice = nil; model.server.hideFileHistory(frozen.items) { result in cleaning = false; for item in frozen.items { selected.removeValue(forKey: item.id) }; notice = managementMessage(result) }
                prompt = nil
            }
        } message: { frozen in Text("\(frozen.all ? "清理本机全部设备和状态的传输历史，不受当前筛选影响。" : "仅清理已选的传输历史。")共 \(frozen.items.count) 条。同时回收无其它记录引用的应用临时内容；用户原文件和已保存文件保留。进行中、可恢复或正在保存的任务会跳过。") }
    }
    private func taskRow(_ task: FileTaskView) -> some View {
        let isGroup = task.kind == "group" && !(task.roots.count == 1 && task.entries.contains(where: { $0.isDirectory && $0.path == task.roots[0] + "/" }))
        let title = isGroup ? groupContentsPreview(task.roots) : task.name
        return HStack(alignment: .center, spacing: 13) {
            RecordSelectionBox(selected: Binding(get: { selected[task.id] == task.attemptId }, set: { if $0 { selected[task.id] = task.attemptId } else { selected.removeValue(forKey: task.id) } }), label: "选择 " + task.name)
            Button {
                if task.kind == "file" && isImageFile(task.name) { model.showTransferImage(task) }
                else { details = task }
            } label: {
                HStack(spacing: 13) {
                    if task.kind == "file" && isImageFile(task.name) { TransferImagePreview(task: task) }
                    else { ContentTypeIcon(kind: task.kind == "group" ? task.roots.count == 1 && task.entries.contains(where: { $0.isDirectory && $0.path == task.roots[0] + "/" }) ? "folder" : "group" : "file", name: task.name) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(isGroup ? 2 : 1).frame(maxWidth: .infinity, alignment: .leading)
                        Text((isGroup ? groupContentsCount(task.roots) + " · " : "") + (task.direction == .outgoing ? "发送给 " : "来自 ") + peerName(task) + " · " + readableBytes(task.totalBytes ?? task.size) + (isGroup ? "" : task.entryCount.map { " · \($0) 项" } ?? "")).font(.system(size: 11)).foregroundStyle(NativeTheme.muted).lineLimit(1)
                        if [.transferring, .awaitingData, .verifying, .committing].contains(task.state) { ProgressView(value: Double(task.progress), total: Double(max(1, task.size))).frame(maxWidth: 270) }
                        if let error = task.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled) }
                        if let error = task.receivedSaveError { Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(peerName(task) + " · 查看详情").accessibilityLabel("查看传输详情 " + title + (isGroup ? "，" + groupContentsCount(task.roots) : ""))
            Text(task.state == .completed && task.receivedSaveState == "failed" ? "保存失败" : task.state == .completed && ["pending", "saving"].contains(task.receivedSaveState ?? "") ? "保存中" : task.state.title)
                .font(.system(size: 11)).foregroundStyle(task.receivedSaveState == "failed" ? Color.orange : task.state == .completed ? Color.green : task.state == .failed ? .orange : NativeTheme.muted)
            taskPrimary(task)
            Menu {
                if task.kind == "group" { Button("详情") { details = task } }
                if task.state == .awaitingUser { Button("拒绝", role: .destructive) { model.server.rejectFile(taskID: task.id, expectedAttempt: task.attemptId) } }
                if !task.state.terminal && task.state != .committing { Button("取消传输", role: .destructive) { model.server.cancelFile(taskID: task.id, expectedAttempt: task.attemptId) } }
                if task.state == .committing {
                    Button("重试可靠保存") { model.server.retryFile(taskID: task.id, expectedAttempt: task.attemptId) }
                }
                if task.direction == .outgoing && [.failed, .rejected, .interrupted, .waitingConnection].contains(task.state) { Button("重试") { model.server.retryFile(taskID: task.id, expectedAttempt: task.attemptId) }.disabled(!canRetry(task)) }
                if task.state == .completed && task.direction == .incoming { Button("打开") { model.openFile(task) }; Button("在 Finder 中显示") { model.reveal(task) }; Button(task.kind == "group" ? "另存全部…" : "另存为…") { if task.kind == "group" { model.saveMany([FileTaskSelection(id: task.id, attemptId: task.attemptId)]) } else { model.export(task) } } }
                Divider(); Button("清理记录…", role: .destructive) { prompt = FileClearPrompt(items: [FileTaskSelection(id: task.id, attemptId: task.attemptId)], epoch: managementEpoch, all: false) }
            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).help("传输更多操作").accessibilityLabel("传输更多操作")
        }.padding(.horizontal, 15).padding(.vertical, 15).frame(minHeight: 81)
            .background(selected[task.id] == task.attemptId ? NativeTheme.blueLight.opacity(0.65) : NativeTheme.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected[task.id] == task.attemptId ? NativeTheme.blue.opacity(0.28) : NativeTheme.line, lineWidth: 0.8).allowsHitTesting(false))
    }
    @ViewBuilder private func taskPrimary(_ task: FileTaskView) -> some View {
        let opensFolder = task.kind == "group" && (task.roots.count != 1 || task.entries.contains { $0.isDirectory && $0.path == task.roots[0] + "/" })
        if task.state == .awaitingUser { Button(task.kind == "group" ? "接收全部" : "接收") { model.server.acceptFile(taskID: task.id, expectedAttempt: task.attemptId) }.buttonStyle(.borderedProminent).controlSize(.small) }
        else if task.state == .completed && task.isOrdinaryReceivedFile {
            if task.receivedSaveState == "failed" {
                Button("重试保存") { model.server.retryReceivedSave(taskID: task.id, expectedAttempt: task.attemptId) }.disabled(task.managementBusy)
            } else {
                Button { model.openFile(task) } label: {
                    Image(systemName: opensFolder ? "folder" : "arrow.up.forward.app").frame(width: 32, height: 32)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NativeTheme.blue).background(NativeTheme.blueLight, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(task.managementBusy)
                    .accessibilityLabel(opensFolder ? "打开文件夹" : "打开文件")
                    .help(opensFolder ? "打开已收到文件所在的文件夹" : "打开已收到的文件").accessibilityIdentifier("received-file-open")
            }
        }
        else if task.state == .completed && task.direction == .incoming { Button { model.saveMany([FileTaskSelection(id: task.id, attemptId: task.attemptId)]) } label: { Image(systemName: "square.and.arrow.down").frame(width: 30, height: 31).background(NativeTheme.blueLight, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue).help("保存到所选目录") }
        else if !task.state.terminal && task.state != .committing { Button { model.server.cancelFile(taskID: task.id, expectedAttempt: task.attemptId) } label: { Image(systemName: "xmark").frame(width: 30, height: 31) }.buttonStyle(.plain).foregroundStyle(NativeTheme.muted).help("取消传输") }
    }
    private func invalidate() { managementEpoch = UUID(); selected.removeAll(); prompt = nil }
    private func canRetry(_ task: FileTaskView) -> Bool {
        model.snapshot.peers.contains { $0.id == task.peerId && $0.connected && $0.fileCapable } &&
            model.snapshot.files.canPrepareSend(peerID: task.peerId, excludingTaskID: task.id)
    }
    private func prepareClear(all: Bool) {
        let items = (all ? history.map { FileTaskSelection(id: $0.id, attemptId: $0.attemptId) } : selected.sorted { $0.key < $1.key }.map { FileTaskSelection(id: $0.key, attemptId: $0.value) })
        prompt = FileClearPrompt(items: items, epoch: managementEpoch, all: all)
    }
    private func peerName(_ task: FileTaskView) -> String { deviceLabel(model.snapshot.peers.first { $0.id == task.peerId }?.name ?? "原来源设备", id: task.peerId) }
    private func saveSelected() {
        let received = history.filter { selected[$0.id] == $0.attemptId && $0.direction == .incoming && $0.state == .completed }.map { FileTaskSelection(id: $0.id, attemptId: $0.attemptId) }
        if received.isEmpty { notice = "所选记录中还没有已完成接收的文件" } else { notice = nil; model.saveMany(received) }
    }
}

/// 小缩图与已校验原件分别展示；无可用图片时退回紧凑图标，不预占大图框。
private struct TransferImagePreview: View {
    @EnvironmentObject var model: AppModel
    let task: FileTaskView
    var large = false
    @State private var image: NSImage?
    @State private var phase = "idle"
    @State private var epoch = UUID()
    private var identity: String { [task.id, task.attemptId, task.state.rawValue, task.imagePreview?.sha256 ?? "", model.snapshot.clipboardContext].joined(separator: "|") }
    private var caption: String {
        switch phase {
        case "loading": return large ? "正在读取本地图片…" : "读取中"
        case "unavailable": return large ? "图片已清理或本地校验未通过" : "图片不可用"
        case "unsupported": return large ? "此图片暂不支持预览" : "预览不可用"
        case "ready": return "本地图片"
        case "preview": return large && task.state != .completed ? (task.direction == .incoming ? "小图预览 · 尚未接收原件" : "小图预览 · 原件传输状态见下方") : "小图预览"
        case "previewUnavailable": return large ? "小图预览 · 本地原件已清理或校验未通过" : "小图预览"
        case "previewUnsupported": return large ? "小图预览 · 原件暂不支持预览" : "小图预览"
        default: return task.state == .completed ? "准备预览" : task.direction == .incoming ? "尚未接收完成" : "传输未完成"
        }
    }
    var body: some View {
        Group {
            if let image {
                if large {
                    VStack(alignment: .leading, spacing: 7) {
                        ClipboardZoomCanvas(image: image).id(identity)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(caption).font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
                    }
                } else {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 64, height: 49)
                        .clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                }
            } else {
                HStack(spacing: 12) {
                    ContentTypeIcon(kind: "file", name: task.name, size: large ? 48 : 32)
                    if large {
                        Text(caption).font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
                        if phase == "loading" { ProgressView().controlSize(.small) }
                    }
                }
            }
        }
            .task(id: identity) { await load() }
            .onDisappear { epoch = UUID(); image = nil }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("图片预览：" + task.name + "，" + caption)
            .accessibilityIdentifier("transfer-image-preview")
    }
    @MainActor private func load() async {
        epoch = UUID(); let captured = epoch, capturedIdentity = identity
        image = nil; phase = "idle"
        guard task.kind == "file", isImageFile(task.name) else { return }
        if let preview = task.imagePreview, let thumbnail = NSImage(data: preview.data) {
            image = thumbnail; phase = "preview"
        }
        guard task.state == .completed else { return }
        if image == nil { phase = "loading" }
        let url: URL? = await withCheckedContinuation { continuation in
            model.server.locateFile(taskID: task.id, expectedAttempt: task.attemptId) { continuation.resume(returning: $0) }
        }
        guard current(captured, capturedIdentity), !Task.isCancelled else { return }
        guard let url else { phase = image == nil ? "unavailable" : "previewUnavailable"; return }
        let value = await decodeTransferImage(url, maximum: large ? 4096 : 320)
        guard current(captured, capturedIdentity), !Task.isCancelled else { return }
        if let value { image = value; phase = "ready" }
        else { phase = image == nil ? "unsupported" : "previewUnsupported" }
    }
    private func current(_ captured: UUID, _ capturedIdentity: String) -> Bool {
        epoch == captured && identity == capturedIdentity && model.snapshot.files.tasks.contains {
            $0.id == task.id && $0.attemptId == task.attemptId && $0.state == task.state && $0.imagePreview?.sha256 == task.imagePreview?.sha256 && $0.isFileTransferRecord
        }
    }
}

// 大图与列表缩图串行解码，避免快速切换多张图片时同时分配多个大位图。
private let transferImageDecodeQueue = DispatchQueue(label: "com.chenguangyao.xuqiao.transfer-preview", qos: .utility, autoreleaseFrequency: .workItem)
private func decodeTransferImage(_ url: URL, maximum: Int) async -> NSImage? {
    await withCheckedContinuation { continuation in
        transferImageDecodeQueue.async {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continuation.resume(returning: nil); return }
            continuation.resume(returning: NSImage(cgImage: thumbnail, size: .zero))
        }
    }
}

private struct FileSendPickerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var peerID = ""
    @State private var expectedGeneration = ""
    private var peer: PeerView? { model.snapshot.peers.first { $0.id == peerID && $0.trustGeneration == expectedGeneration } }
    private var busy: Bool { !model.canChooseFile(peerID: peerID) }
    private var busyMessage: String { "正在选择或准备文件，或该设备普通任务已达50项。" }
    private func available(_ item: PeerView) -> Bool {
        item.connected && item.fileCapable && model.canChooseFile(peerID: item.id)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("发送文件").font(.system(size: 20, weight: .semibold)); Spacer(); Button("取消") { dismiss() } }
            if model.snapshot.peers.isEmpty { Text("请先连接手机。").font(.system(size: 13)).foregroundStyle(NativeTheme.muted); Button("连接新手机") { dismiss(); model.showPairing() }.buttonStyle(.borderedProminent) }
            else {
                Picker("目标设备", selection: $peerID) { Text("选择设备").tag(""); ForEach(model.snapshot.peers) { item in Text(deviceLabel(item.name, id: item.id) + (available(item) ? " · 可发送" : item.connected ? " · 暂不可发送" : " · 未连接")).tag(item.id).disabled(!available(item)) } }
                Text(busy ? busyMessage : peer?.connected == true ? peer?.groupCapable == true ? "可选择多个文件和文件夹，最多 100 个顶层项目。" : "对端支持单文件传输，通道占满时自动排队。" : "设备未连接，请恢复连接后再发送。").font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
                HStack { Spacer(); Button("选择文件…") { guard let peer else { return }; dismiss(); model.chooseFile(peerID: peer.id, allowGroups: peer.groupCapable, expectedGeneration: peer.trustGeneration) }.buttonStyle(.borderedProminent).disabled(peer?.connected != true || peer?.fileCapable != true || busy) }
            }
        }.padding(26).frame(width: 450)
            .onAppear { if let item = model.snapshot.peers.first(where: { $0.id == model.filePeer && available($0) }) ?? model.snapshot.peers.first(where: available) { peerID = item.id; expectedGeneration = item.trustGeneration } }
            .onChange(of: peerID) { _, id in expectedGeneration = model.snapshot.peers.first { $0.id == id }?.trustGeneration ?? "" }
    }
}
// 部分成功、取消和未知终态都必须保留，不能仅凭终态或零失败数自动隐藏。
func batchExportSucceeded(_ status: BatchExportView) -> Bool {
    status.state == "completed" && !status.cancelled && status.failed == 0 && status.total > 0 &&
        status.completed == status.total && status.items.count == status.total && status.items.allSatisfy { $0.state == "completed" }
}

private struct BatchExportStatus: View {
    @EnvironmentObject var model: AppModel
    let status: BatchExportView
    var body: some View {
        if batchExportSucceeded(status) {
            HStack(spacing: 10) {
                Label(status.total == 1 ? "文件已保存" : "已保存 \(status.total) 个项目", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.green)
                Spacer()
                dismissButton
            }.padding(13).background(NativeTheme.blueLight, in: RoundedRectangle(cornerRadius: 9))
        } else { NativeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(status.state == "exporting" ? "正在保存文件" : status.cancelled ? "保存已取消" : "保存未完成", systemImage: "folder.badge.plus").font(.headline)
                    Spacer()
                    if status.state == "exporting" {
                        Button("取消剩余保存", role: .destructive) { model.server.cancelExport(exportID: status.id) }.disabled(status.cancelled)
                    } else { dismissButton }
                }
                if status.state == "exporting" { ProgressView(value: Double(status.completed), total: Double(max(1, status.total))) }
                Text(status.message).font(.callout).foregroundStyle(status.failed > 0 ? Color.orange : Color.secondary)
                if status.state != "exporting" {
                    ForEach(status.items.filter { $0.state != "completed" }) { item in
                        Text(item.name + "：" + item.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        } }
    }
    private var dismissButton: some View {
        Button { model.dismissBatchExport(status.id) } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
            .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭保存提示")
    }
}
struct GroupDetailsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let id: String
    let attempt: String
    var onClose: (() -> Void)? = nil
    @State private var localURL: URL?
    @State private var pathLoading = false
    @State private var pathError: String?
    @State private var pathEpoch = UUID()
    private var task: FileTaskView? { model.snapshot.files.tasks.first { $0.id == id && $0.attemptId == attempt && $0.isFileTransferRecord } }
    private var localIdentity: String { id + "|" + attempt + "|" + (task?.state.rawValue ?? "missing") + "|" + model.snapshot.clipboardContext }
    var body: some View {
        Group {
        if let task, task.kind == "file" && isImageFile(task.name) {
            imageDetails(task)
        } else {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(task?.name ?? "任务已更新").font(.title2.bold()); Spacer(); Button("完成") { close() }.keyboardShortcut(.defaultAction) }
            if let task, task.kind == "group" {
                Text("\(task.entryCount ?? 0)项 · 原始大小 \(ByteCountFormatter.string(fromByteCount: task.totalBytes ?? 0, countStyle: .file))")
                    .font(.callout).foregroundStyle(.secondary)
                if task.entries.isEmpty {
                    Text("完整条目将在接收并校验后显示。顶层项目：").font(.callout).foregroundStyle(.secondary)
                    List(task.roots, id: \.self) { Text($0) }
                } else {
                    let empty = emptyDirectories(task.entries)
                    List(task.entries) { entry in
                        HStack(spacing: 9) {
                            ContentTypeIcon(kind: entry.isDirectory ? "folder" : "file", name: entry.path, size: 24)
                            Text(entry.path).lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Text(entry.isDirectory ? (empty.contains(entry.path) ? "空目录" : "目录") : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
            } else if let task {
                    HStack(spacing: 18) {
                        ContentTypeIcon(kind: "file", name: task.name, size: 64)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("单个文件").font(.system(size: 14, weight: .medium))
                            Text(readableBytes(task.size)).font(.system(size: 13)).foregroundStyle(NativeTheme.muted)
                        }
                    }.padding(.vertical, 10)
                Divider()
                LabeledContent("传输状态", value: task.state.title)
                LabeledContent(task.direction == .outgoing ? "发送给" : "来自", value: deviceLabel(model.snapshot.peers.first { $0.id == task.peerId }?.name ?? "原来源设备", id: task.peerId))
                if [.transferring, .awaitingData, .verifying, .committing].contains(task.state) {
                    ProgressView(value: Double(task.progress), total: Double(max(1, task.size)))
                }
                if task.state == .committing {
                    Text("等待可靠保存；临时错误将自动重试，也可手动重试。请保留此任务以免丢失接收内容。").font(.caption).foregroundStyle(.secondary)
                    Button("重试可靠保存") { model.server.retryFile(taskID: task.id, expectedAttempt: task.attemptId) }
                }
                if let error = task.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                Spacer()
            } else { Text("此任务的尝试已改变，请关闭后重新打开详情。").foregroundStyle(.secondary); Spacer() }
            if let task {
                LocalResourcePathView(title: task.direction == .outgoing ? "本地发送副本" : task.kind == "group" ? "本地目录" : "本地文件",
                                      path: localURL?.path, loading: pathLoading, unavailable: pathError ?? pathUnavailable(task), reveal: revealLocal)
            }
        }.padding(24).frame(minWidth: 620, minHeight: 470)
        }
        }
            .task(id: localIdentity) { await loadLocalPath() }
            .onDisappear { pathEpoch = UUID(); localURL = nil }
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    private func imageDetails(_ task: FileTaskView) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.name).font(.system(size: 15, weight: .semibold)).lineLimit(1).help(task.name)
                    Text(readableBytes(task.size) + " · " + task.state.title + " · " + deviceLabel(model.snapshot.peers.first { $0.id == task.peerId }?.name ?? "原来源设备", id: task.peerId))
                        .font(.system(size: 11)).foregroundStyle(NativeTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 10)
                Button("完成") { close() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.vertical, 14).background(.bar)
            Divider()
            TransferImagePreview(task: task, large: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
                .background(NativeTheme.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if [.transferring, .awaitingData, .verifying, .committing].contains(task.state) {
                    ProgressView(value: Double(task.progress), total: Double(max(1, task.size)))
                }
                if let error = task.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled) }
                if task.state == .committing {
                    Button("重试可靠保存") { model.server.retryFile(taskID: task.id, expectedAttempt: task.attemptId) }
                }
                LocalResourcePathView(title: task.direction == .outgoing ? "本地发送副本" : "本地文件", path: localURL?.path, loading: pathLoading, unavailable: pathError ?? pathUnavailable(task), reveal: revealLocal)
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
        }.frame(minWidth: 640, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transfer-image-window")
    }
    private func pathUnavailable(_ task: FileTaskView) -> String {
        task.state == .completed ? "本地内容不存在或校验未通过" : task.direction == .incoming ? "接收完成后可查看本地位置" : "传输完成后可查看本地发送副本"
    }
    @MainActor private func loadLocalPath() async {
        pathEpoch = UUID(); let captured = pathEpoch, identity = localIdentity
        localURL = nil; pathError = nil; pathLoading = false
        guard let task, task.state == .completed else { return }
        pathLoading = true
        let url: URL? = await withCheckedContinuation { continuation in
            model.server.locateFile(taskID: id, expectedAttempt: attempt) { continuation.resume(returning: $0) }
        }
        guard pathEpoch == captured, localIdentity == identity, !Task.isCancelled else { return }
        pathLoading = false; localURL = url
        if url == nil { pathError = pathUnavailable(task) }
    }
    private func revealLocal() {
        guard let task, task.state == .completed else { return }
        let captured = pathEpoch, identity = localIdentity
        // 只定位当前已完成 attempt 的校验成品，不把展示过的路径当作后续授权。
        model.server.locateFile(taskID: id, expectedAttempt: attempt) { url in
            guard pathEpoch == captured, localIdentity == identity else { return }
            guard let url else { localURL = nil; pathError = pathUnavailable(task); return }
            localURL = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    private func emptyDirectories(_ entries: [GroupEntry]) -> Set<String> {
        var nonempty = Set<String>()
        for entry in entries {
            let parts = entry.path.split(separator: "/").map(String.init)
            if parts.count > 1 { for n in 1..<parts.count { nonempty.insert(parts.prefix(n).joined(separator: "/") + "/") } }
        }
        return Set(entries.filter { $0.isDirectory && !nonempty.contains($0.path) }.map(\.path))
    }
}
