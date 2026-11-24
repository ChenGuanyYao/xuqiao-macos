import SwiftUI
import XuQiaoCore
import ImageIO
import AppKit

private struct ClipboardClearPrompt: Identifiable {
    let id = UUID()
    let keys: [String]
    let context: String
    let epoch: UUID
    let all: Bool
}

struct ClipboardPage: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("clipboard.kind") private var kind = ""
    @State private var search = ""
    @State private var page = 0
    @State private var selected = Set<String>()
    @State private var details: ClipboardRecordView?
    @State private var sending = false
    @State private var queryingKeys = false
    @State private var cleaning = false
    @State private var prompt: ClipboardClearPrompt?
    @State private var managementEpoch = UUID()
    private var noticeIdentity: UUID { model.clipboardOperationNoticeID }
    private var notice: String? {
        get { model.clipboardOperationNotice }
        nonmutating set { model.clipboardOperationNotice = newValue }
    }
    private let types = [("", "全部"), ("text", "文字"), ("image", "图片"), ("file", "文件"), ("folder", "文件夹"), ("group", "文件组")]
    private var queryText: String { String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256)) }
    private var queryIdentity: String { [model.clipboardSource, kind, String(page), queryText].joined(separator: "|") }
    private var queryReady: Bool { model.snapshot.clipboardQueryID == queryIdentity }
    private var visible: [ClipboardRecordView] { queryReady ? model.snapshot.clipboardPage : [] }
    private var downloadableSelection: [String] {
        model.snapshot.clipboardRecords.filter { selected.contains($0.key) && ($0.kind == "image" || (!$0.originLocal && $0.kind != "text" && $0.downloadState != "downloaded")) }.map(\.key)
    }
    private var sources: [(id: String, name: String)] {
        var result = [String: String]()
        for peer in model.snapshot.peers { result[peer.id] = peer.name }
        for row in model.snapshot.clipboardRecords where result[row.sourceDeviceId] == nil { result[row.sourceDeviceId] = row.sourceName }
        if !model.clipboardSource.isEmpty && result[model.clipboardSource] == nil { result[model.clipboardSource] = model.clipboardSourceName.isEmpty ? "原来源设备" : model.clipboardSourceName }
        return result.map { (id: $0.key, name: $0.value) }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            if let error = model.snapshot.error {
                HStack { NativeNotice(text: error, warning: true); if !model.snapshot.ready { Button("重试连接") { model.server.retry() } } }
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) { Text("剪贴板").font(.system(size: 24, weight: .semibold)); Text("复制的内容，按来源留在这里。").font(.system(size: 12)).foregroundStyle(NativeTheme.muted) }
                Spacer(); Button { sending = true } label: { Label("发送", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent).disabled(model.snapshot.clipboardContext.isEmpty)
            }.padding(.bottom, 4)
            HStack(spacing: 11) {
                NativeSearchField(placeholder: "搜索内容、组内文件名或来源", text: $search, identifier: "clipboard-search")
                Picker("来源设备", selection: $model.clipboardSource) { Text("全部来源").tag(""); ForEach(sources, id: \.id) { Text(deviceLabel($0.name, id: $0.id)).tag($0.id) } }.labelsHidden().frame(width: 155).controlSize(.small).help(sources.first { $0.id == model.clipboardSource }.map { deviceLabel($0.name, id: $0.id) } ?? "全部来源")
                if !visible.isEmpty { Menu {
                    Button("全选当前筛选") { selectAll() }
                    Divider()
                    Button("全部清理…", role: .destructive) { prepareClear(all: true) }
                    Button("缓存与存储") { model.selection = .storage }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 26) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).help("记录管理").accessibilityLabel("记录管理") }
            }
            HStack(spacing: 3) {
                ForEach(types, id: \.0) { type in
                    Button { kind = type.0 } label: { Text(type.1).font(.system(size: 12, weight: kind == type.0 ? .medium : .regular)).foregroundStyle(kind == type.0 ? NativeTheme.blue : NativeTheme.muted).padding(.horizontal, 10).frame(height: 30).background(kind == type.0 ? NativeTheme.blueLight : .clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
                }
                Spacer(); if queryReady { Text("\(model.snapshot.clipboardQueryCount) 条").font(.system(size: 11)).foregroundStyle(NativeTheme.muted) } else { ProgressView().controlSize(.mini).accessibilityLabel("正在查找") }
            }
            OperationNotice(text: Binding(get: { notice }, set: { notice = $0 })).id(noticeIdentity)
            if notice != nil && !model.clipboardSource.isEmpty {
                HStack(spacing: 8) {
                    Text("当前只显示所选来源的记录").foregroundStyle(NativeTheme.muted)
                    Button("查看全部来源") { model.clipboardSource = "" }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue)
                }.font(.system(size: 11)).padding(.horizontal, 14)
            }
            // 延后创建屏幕外记录，避免切页时一次布局整页卡片。
            LazyVStack(spacing: 9) {
                if queryReady && !visible.isEmpty { HStack(spacing: 8) {
                    Button(queryingKeys ? "正在选择…" : "全选当前筛选") { selectAll() }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue).disabled(queryingKeys)
                    if !selected.isEmpty { Text("已选 \(selected.count) 条").foregroundStyle(NativeTheme.muted); Button("取消选择") { selected.removeAll() }.buttonStyle(.plain).foregroundStyle(NativeTheme.muted) }
                    Spacer(); Button("全部清理…") { prepareClear(all: true) }.buttonStyle(.plain).foregroundStyle(NativeTheme.muted).disabled(cleaning || queryingKeys)
                }.font(.system(size: 11)).padding(.horizontal, 15).frame(height: 39)
                    .background(NativeTheme.sidebar.opacity(0.55), in: RoundedRectangle(cornerRadius: 10)) }
                if !queryReady {
                    // 只在当前查询返回后判空，避免输入或翻页时闪现“暂无记录”。
                    ProgressView("正在查找…").frame(maxWidth: .infinity, minHeight: 250)
                        .background(NativeTheme.background, in: RoundedRectangle(cornerRadius: 12))
                } else if visible.isEmpty {
                    ContentUnavailableView {
                        Label(queryText.isEmpty ? "暂无记录" : "未找到相关记录", systemImage: "clipboard")
                    } description: {
                        Text(queryText.isEmpty ? (kind.isEmpty && model.clipboardSource.isEmpty ? "新复制的内容会出现在这里，也可以主动发送。" : "没有符合当前筛选的记录。") : "试试其他关键词，或清除搜索查看当前筛选的记录。")
                    } actions: {
                        if !queryText.isEmpty { Button("清除搜索") { search = "" }.accessibilityIdentifier("clipboard-search-empty-clear") }
                    }.frame(maxWidth: .infinity, minHeight: 250)
                        .background(NativeTheme.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativeTheme.line, lineWidth: 0.8).allowsHitTesting(false))
                }
                ForEach(visible) { row in recordRow(row) }
            }
            if queryReady && model.snapshot.clipboardQueryCount > 50 { HStack {
                Button("上一页") { page = max(0, page - 1) }.disabled(page == 0)
                Spacer(); Text("第 \(page + 1) 页").font(.system(size: 11)).foregroundStyle(NativeTheme.muted); Spacer()
                Button("下一页") { page += 1 }.disabled((page + 1) * 50 >= model.snapshot.clipboardQueryCount)
            }.controlSize(.small) }
        }.padding(26)
        }
        // 批量栏属于视口安全区，选择顶部记录后无需滚动到底。
        .safeAreaInset(edge: .bottom, spacing: 0) {
                if !selected.isEmpty {
                    HStack(spacing: 15) {
                        Text("已选择 \(selected.count) 条").foregroundStyle(NativeTheme.muted)
                        Spacer()
                        if !downloadableSelection.isEmpty { Button("下载所选") { notice = nil; model.server.downloadManyClipboard(keys: downloadableSelection, context: model.snapshot.clipboardContext) }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue) }
                        Button("保存已下载项…") { saveSelected() }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue)
                        Button("清理所选…") { prepareClear(all: false) }.buttonStyle(.plain).foregroundStyle(.red).disabled(cleaning)
                    }.font(.system(size: 11)).padding(14).background(NativeTheme.blueLight.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
        }

        .onAppear { query(); requestPreviews() }
        .onChange(of: kind) { _, _ in filtersChanged() }
        .onChange(of: model.clipboardSource) { _, _ in UserDefaults.standard.set(model.clipboardSource, forKey: "clipboard.source"); filtersChanged() }
        .onChange(of: queryText) { _, _ in filtersChanged() }
        .onChange(of: page) { _, _ in query() }
        .onChange(of: model.snapshot.clipboardContext) { _, _ in invalidate(); query() }
        .onChange(of: model.snapshot.clipboardQueryID) { _, _ in requestPreviews() }
        .onChange(of: visible.map { $0.key + $0.previewState }) { _, _ in requestPreviews() }
        .onDisappear { managementEpoch = UUID(); model.server.cancelClipboardPreviews(context: model.snapshot.clipboardContext) }
        .sheet(isPresented: $sending) { SendClipboardSheet().environmentObject(model) }
        .sheet(item: $details) { row in ClipboardDetailsSheet(original: row).environmentObject(model) }
        .alert(prompt?.all == true ? "清理全部剪贴板记录？" : "清理所选记录？", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { frozen in
            Button("取消", role: .cancel) { prompt = nil }
            Button("清理 \(frozen.keys.count) 条", role: .destructive) {
                guard frozen.epoch == managementEpoch, frozen.context == model.snapshot.clipboardContext else { notice = "列表状态已变化，请重新确认"; prompt = nil; return }
                cleaning = true
                notice = nil; model.server.deleteManyClipboard(keys: frozen.keys, context: frozen.context) { result in cleaning = false; selected.subtract(frozen.keys); notice = managementMessage(result); query() }
                prompt = nil
            }
        } message: { frozen in Text("\(frozen.all ? "清理本机全部来源、全部类型的历史，不受当前筛选影响。" : "仅清理已选的历史记录。")共 \(frozen.keys.count) 条，之后新到的记录不受影响。同时删除无其它记录引用的内部原图和临时内容；用户原文件和已保存文件保留，使用中的内容会跳过。") }
    }
    private func recordRow(_ row: ClipboardRecordView) -> some View {
        HStack(spacing: 13) {
            RecordSelectionBox(selected: Binding(get: { selected.contains(row.key) }, set: { if $0 { selected.insert(row.key) } else { selected.remove(row.key) } }), label: "选择 " + (row.name.isEmpty ? "文字记录" : row.name))
            // 详情只由内容区触发，选择框、复制/下载及更多菜单仍是独立控件。
            Button { details = row } label: {
                HStack(spacing: 13) {
                    if row.kind == "image" { ClipboardThumbnail(url: row.previewURL).frame(width: 64, height: 49) }
                    else if row.kind != "text" { ContentTypeIcon(kind: row.kind, name: row.name) }
                    recordContent(row)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(deviceLabel(row.sourceName, id: row.sourceDeviceId) + " · " + (row.kind == "image" ? "放大查看图片" : "查看详情"))
                .accessibilityLabel(recordAccessibility(row))
            Text(status(row)).font(.system(size: 11)).foregroundStyle(row.downloadState == "downloaded" ? Color.green : NativeTheme.muted).lineLimit(1)
            primaryAction(row)
            Menu {
                if row.kind == "file", isVideoFile(row.name), row.originLocal && row.available || row.downloadState == "downloaded" { Button("播放视频") { details = row } }
                Button("查看详情") { details = row }
                if row.kind == "text" || row.downloadState == "downloaded" || row.originLocal && row.available { Button("复制") { copy(row) } }
                if ["requesting", "downloading"].contains(row.downloadState) { Button("取消下载") { model.server.cancelClipboardDownload(source: row.sourceDeviceId, recordID: row.recordId, context: row.context) } }
                if row.downloadState == "downloaded", row.kind != "image", let task = task(row) { Button("保存…") { model.saveMany([FileTaskSelection(id: task.id, attemptId: task.attemptId)]) } }
                Divider(); Button("清理记录…", role: .destructive) { prompt = ClipboardClearPrompt(keys: [row.key], context: row.context, epoch: managementEpoch, all: false) }
            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).help("记录更多操作").accessibilityLabel("记录更多操作")
        }.padding(.horizontal, 15).padding(.vertical, 15).frame(minHeight: 82)
            .background(selected.contains(row.key) ? NativeTheme.blueLight.opacity(0.65) : NativeTheme.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected.contains(row.key) ? NativeTheme.blue.opacity(0.28) : NativeTheme.line, lineWidth: 0.8).allowsHitTesting(false))
    }
    private func recordContent(_ row: ClipboardRecordView) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(recordTitle(row))
                .font(.system(size: 13, weight: row.kind == "text" ? Font.Weight.regular : Font.Weight.medium))
                .lineLimit(row.kind == "text" || row.kind == "group" ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if row.kind == "text" { Text("文字").font(.system(size: 10, weight: .medium)).foregroundStyle(NativeTheme.muted).padding(.horizontal, 5).padding(.vertical, 2).background(NativeTheme.sidebar, in: RoundedRectangle(cornerRadius: 4)) }
                Text(recordMetadata(row)).font(.system(size: 11)).foregroundStyle(NativeTheme.muted).lineLimit(1)
            }
            if ["requesting", "downloading"].contains(row.downloadState) { ProgressView(value: row.progress).progressViewStyle(.linear).frame(maxWidth: 240) }
            if !row.error.isEmpty { Text(row.error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2) }
        }
    }
    @ViewBuilder private func primaryAction(_ row: ClipboardRecordView) -> some View {
        if row.kind == "image" {
            Button { notice = nil; model.server.downloadClipboard(source: row.sourceDeviceId, recordID: row.recordId, context: row.context) } label: { Image(systemName: "arrow.down").frame(width: 32, height: 32).background(NativeTheme.blueLight, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue)
                .disabled(row.downloadState != "downloaded" && (!row.available || !row.sourceOnline)).help("保存原图到 Downloads/续桥；缓存就绪后导出")
                .accessibilityLabel("下载原图到 Downloads/续桥")
        } else if ["requesting", "downloading"].contains(row.downloadState) {
            Button { model.server.cancelClipboardDownload(source: row.sourceDeviceId, recordID: row.recordId, context: row.context) } label: { Image(systemName: "xmark").frame(width: 30, height: 32) }.buttonStyle(.plain).help("取消下载")
        } else if row.kind == "file", isVideoFile(row.name), row.originLocal && row.available || row.downloadState == "downloaded" {
            Button { details = row } label: { Image(systemName: "play.fill").frame(width: 30, height: 32) }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue).help("播放视频").accessibilityLabel("播放视频 " + row.name)
        } else if row.originLocal || row.kind == "text" || row.downloadState == "downloaded" {
            Button { copy(row) } label: { Image(systemName: "doc.on.doc").frame(width: 30, height: 32) }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue).help("复制").disabled(row.kind != "text" && !row.available && row.downloadState != "downloaded")
        } else {
            Button { notice = nil; model.server.downloadClipboard(source: row.sourceDeviceId, recordID: row.recordId, context: row.context) } label: { Image(systemName: "arrow.down").frame(width: 32, height: 32).background(NativeTheme.blueLight, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue).disabled(!row.available || !row.sourceOnline).help(row.kind == "image" ? "下载原图" : "下载")
        }
    }
    private func recordAccessibility(_ row: ClipboardRecordView) -> String {
        if row.kind == "image" { return "查看图片 " + row.name }
        if row.kind == "text" { return "查看详情 文字记录" }
        if row.kind == "group" { return "查看详情 " + groupContentsPreview(row.roots) + "，" + groupContentsCount(row.roots) }
        return "查看详情 " + row.name
    }
    private func recordTitle(_ row: ClipboardRecordView) -> String {
        if row.kind == "text" { return row.preview }
        if row.kind == "group" { return groupContentsPreview(row.roots) }
        return row.name
    }
    private func recordMetadata(_ row: ClipboardRecordView) -> String {
        let group = row.kind == "group" ? groupContentsCount(row.roots) + " · " : ""
        let source = deviceLabel(row.sourceName, id: row.sourceDeviceId)
        let captured = Date(timeIntervalSince1970: Double(row.capturedAt) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
        let size = readableBytes(row.kind == "group" || row.kind == "folder" ? row.totalBytes : row.size)
        return group + source + " · " + captured + " · " + size
    }
    private func copy(_ row: ClipboardRecordView) { notice = nil; model.server.copyClipboardRecord(source: row.sourceDeviceId, recordID: row.recordId, context: row.context) }
    private func task(_ row: ClipboardRecordView) -> FileTaskView? { model.snapshot.files.tasks.first { $0.id == row.taskId } }
    private func status(_ row: ClipboardRecordView) -> String {
        if row.downloadState == "downloaded" { return row.kind == "image" ? "已缓存原图" : "已下载" }
        if row.downloadState == "requesting" { return row.kind == "image" ? "正在请求原图" : "正在请求" }
        if row.downloadState == "downloading" { return row.kind == "image" ? "缓存原图中" : "下载中" }
        if row.kind == "text" { return "已同步" }
        if row.originLocal { return row.available ? "本机内容" : "副本不可用" }
        if !row.available { return "已过期" }
        if !row.sourceOnline { return "来源离线" }
        return "未下载"
    }
    private func query() {
        // 切换筛选/分页先撤销旧预览请求；同一服务队列保持取消先于新查询和请求。
        model.server.cancelClipboardPreviews(context: model.snapshot.clipboardContext)
        model.server.queryClipboard(source: model.clipboardSource, kind: kind, page: page, query: queryText)
    }
    private func invalidate() { managementEpoch = UUID(); selected.removeAll(); prompt = nil }
    private func filtersChanged() { invalidate(); if page != 0 { page = 0 } else { query() } }
    private func requestPreviews() { guard !visible.isEmpty else { return }; model.server.requestClipboardPreviews(keys: visible.filter { $0.kind == "image" }.map(\.key), context: model.snapshot.clipboardContext) }
    private func selectAll() {
        let identity = queryIdentity; let epoch = managementEpoch; queryingKeys = true
        model.server.allClipboardKeys(source: model.clipboardSource, kind: kind, query: queryText) { keys, context in
            queryingKeys = false
            guard identity == queryIdentity, epoch == managementEpoch, context == model.snapshot.clipboardContext else { return }
            selected = Set(keys)
        }
    }
    private func prepareClear(all: Bool) {
        guard !queryingKeys else { return }
        if !all { prompt = ClipboardClearPrompt(keys: selected.sorted(), context: model.snapshot.clipboardContext, epoch: managementEpoch, all: false); return }
        queryingKeys = true; let epoch = managementEpoch
        model.server.allClipboardKeys(source: "", kind: "", query: "") { keys, context in
            queryingKeys = false
            guard epoch == managementEpoch, context == model.snapshot.clipboardContext else { return }
            prompt = ClipboardClearPrompt(keys: keys, context: context, epoch: epoch, all: true)
        }
    }
    private func saveSelected() {
        let tasks = model.snapshot.clipboardRecords.filter { selected.contains($0.key) && $0.downloadState == "downloaded" }.compactMap(task).map { FileTaskSelection(id: $0.id, attemptId: $0.attemptId) }
        if tasks.isEmpty { notice = "所选记录中还没有已下载的内容" } else { notice = nil; model.saveMany(tasks) }
    }
}

struct SendClipboardSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var manualText = false
    private var validText: Bool { !text.isEmpty && !text.utf8.contains(0) && text.utf8.count <= 16_384 }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("发送剪贴板").font(.system(size: 20, weight: .semibold)); Spacer(); Button("取消") { dismiss() } }
            Text("发送给所有符合接收设置的已配对手机。").font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
            Picker("发送内容", selection: $manualText) { Text("当前剪贴板").tag(false); Text("输入文字").tag(true) }.pickerStyle(.segmented)
            if manualText {
                TextEditor(text: $text).font(.system(size: 13)).frame(height: 140).padding(7).background(NativeTheme.background, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(NativeTheme.line))
                if !text.isEmpty && !validText { Text("文字不能包含空字符，大小不超过 16 KiB。").font(.system(size: 11)).foregroundStyle(.orange) }
            } else {
                Label("同步当前复制的文字、图片、文件、文件夹或文件组。", systemImage: "clipboard").font(.system(size: 13)).foregroundStyle(NativeTheme.muted).padding(.vertical, 18)
            }
            HStack { Spacer(); Button("发送") { model.server.sendClipboardToAll(text: manualText ? text : nil, context: model.snapshot.clipboardContext); dismiss() }.buttonStyle(.borderedProminent).disabled(model.snapshot.clipboardContext.isEmpty || manualText && !validText || model.snapshot.peers.isEmpty) }
        }.padding(26).frame(width: 470)
    }
}

struct ClipboardThumbnail: View {
    let url: URL?
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { ZStack { NativeTheme.sidebar; Text("暂无预览").font(.system(size: 10)).foregroundStyle(NativeTheme.muted) } }
        }.frame(width: 64, height: 49).clipShape(RoundedRectangle(cornerRadius: 7))
            .task(id: url) { image = nil; guard let url else { return }; let value = await loadImage(url, maximum: 320); guard !Task.isCancelled else { return }; image = value }
    }
}

private struct ClipboardDetailsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let original: ClipboardRecordView
    @State private var text = ""
    @State private var image: NSImage?
    @State private var imageLoading = false
    @State private var imageError: String?
    @State private var loadedOriginal = false
    @State private var generation = UUID()
    @State private var localResource: ClipboardLocalResource?
    @State private var resourceLoading = false
    @State private var resourceError: String?
    private var row: ClipboardRecordView? { model.snapshot.clipboardRecords.first { $0.key == original.key && $0.context == original.context } }
    var body: some View {
        Group {
            if let row, row.kind == "image" { imageViewer(row) }
            else { recordDetails }
        }.task(id: imageIdentity) {
            if let row, row.kind == "image" { model.server.requestClipboardPreviews(keys: [row.key], context: row.context) }
            await refreshContent()
        }
            .onDisappear { generation = UUID(); image = nil; localResource = nil }
    }
    private var imageIdentity: String {
        guard let row else { return "missing" }
        let attempt = model.snapshot.files.tasks.first { $0.id == row.taskId }?.attemptId ?? ""
        return [row.key, row.context, row.downloadState, row.downloadState == "downloaded" || row.originLocal ? "original" : row.previewState, row.downloadState == "downloaded" || row.originLocal ? "" : row.previewURL?.path ?? "", row.taskId, attempt,
                String(row.available), String(row.availabilityVersion), String(row.cacheExpiresAt)].joined(separator: "|")
    }
    private var recordDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(row.map { $0.name.isEmpty ? "文字详情" : $0.name } ?? "记录已更新").font(.system(size: 20, weight: .semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            if let row {
                Text(deviceLabel(row.sourceName, id: row.sourceDeviceId) + " · " + readableBytes(row.kind == "folder" || row.kind == "group" ? row.totalBytes : row.size)).font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
                if row.kind == "text" { ScrollView { Text(text).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                else if row.kind == "file" && isVideoFile(row.name) { videoContent(row) }
                else if row.kind == "folder" || row.kind == "group" {
                    Text("\(row.entryCount) 个项目").font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
                    if let task = model.snapshot.files.tasks.first(where: { $0.id == row.taskId }), !task.entries.isEmpty { List(task.entries) { entry in Label(entry.path, systemImage: entry.isDirectory ? "folder" : "doc").font(.system(size: 12)) } }
                    else { List(row.roots, id: \.self) { Label($0, systemImage: "folder").font(.system(size: 12)) }; Text(row.originLocal ? "此处展示顶层项目，本地同步副本保留完整目录结构。" : "下载后可查看完整目录。").font(.system(size: 11)).foregroundStyle(NativeTheme.muted) }
                } else { ContentTypeIcon(kind: row.kind, name: row.name, size: 62); Spacer() }
                if row.kind != "text" { resourcePath(row) }
            } else { ContentUnavailableView("记录已更新", systemImage: "clipboard", description: Text("请关闭后重新打开。")) }
        }.padding(25).frame(width: row.map { $0.kind == "file" && isVideoFile($0.name) } == true ? 690 : 560,
                           height: row.map { $0.kind == "file" && isVideoFile($0.name) } == true ? 590 : 450)
    }
    @ViewBuilder private func videoContent(_ row: ClipboardRecordView) -> some View {
        if let localResource {
            LocalVideoPlayer(resource: localResource, fileName: row.name).id(imageIdentity).frame(minHeight: 235)
        } else if resourceLoading {
            ProgressView("正在校验本地视频…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("暂无可播放的本地视频", systemImage: "play.rectangle", description: Text(resourceError ?? "请先下载视频内容。")).frame(maxHeight: .infinity)
        }
        HStack {
            Text("使用系统播放按钮开始，格式支持取决于当前系统。").font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
            Spacer()
            if !row.originLocal && row.downloadState != "downloaded" {
                if ["requesting", "downloading"].contains(row.downloadState) {
                    Button("取消下载") { model.server.cancelClipboardDownload(source: row.sourceDeviceId, recordID: row.recordId, context: row.context) }
                } else {
                    Button("下载视频") { model.server.downloadClipboard(source: row.sourceDeviceId, recordID: row.recordId, context: row.context) }.buttonStyle(.borderedProminent).disabled(!row.available || !row.sourceOnline)
                }
            }
        }
    }
    private func resourcePath(_ row: ClipboardRecordView, dark: Bool = false) -> some View {
        LocalResourcePathView(title: row.privateOriginal ? "内部原图缓存" : localResource?.isSnapshot == true || row.originLocal ? "本地同步副本" : "本地文件",
                              path: localResource?.url.path, loading: resourceLoading, unavailable: resourceError ?? unavailableMessage(row),
                              dark: dark, reveal: { revealLocal(row) })
    }
    private func unavailableMessage(_ row: ClipboardRecordView) -> String {
        row.originLocal ? "本地同步副本已清理、过期或校验未通过" : row.downloadState == "downloaded" ? "本地文件不存在或校验未通过" : "下载后可查看本地位置"
    }
    private func revealLocal(_ row: ClipboardRecordView) {
        let captured = generation, identity = imageIdentity
        // 展示路径不是定位授权；每次打开 Finder 均重新走来源、记录和内容校验。
        model.server.locateClipboardResource(source: row.sourceDeviceId, recordID: row.recordId, context: row.context) { resource in
            guard generation == captured, imageIdentity == identity, model.snapshot.clipboardContext == row.context else { return }
            guard let resource else {
                localResource = nil; resourceError = unavailableMessage(row)
                if row.kind == "image" { image = nil; loadedOriginal = false; imageError = resourceError }
                return
            }
            localResource = resource
            withExtendedLifetime(resource) { NSWorkspace.shared.activateFileViewerSelecting([resource.url]) }
        }
    }
    private func imageViewer(_ row: ClipboardRecordView) -> some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text(row.name).font(.system(size: 13, weight: .medium)); Text(imageCaption(row)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }; Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 30, height: 30) }.buttonStyle(.plain).keyboardShortcut(.cancelAction) }.padding(20)
            ZStack {
                Color.black.opacity(0.18)
                if let image { ClipboardZoomCanvas(image: image).id(imageIdentity) }
                else if imageLoading { ProgressView().controlSize(.large).tint(.white) }
                else { Text(imageError ?? "暂无图片预览").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)) }
            }
            VStack(spacing: 12) {
            HStack {
                Text(deviceLabel(row.sourceName, id: row.sourceDeviceId)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)); Spacer()
                if ["requesting", "downloading"].contains(row.downloadState) { ProgressView(value: row.progress).frame(width: 80); Button("取消") { model.server.cancelClipboardDownload(source: row.sourceDeviceId, recordID: row.recordId, context: row.context) } }
                Button("下载原图到 Downloads/续桥") { model.server.downloadClipboard(source: row.sourceDeviceId, recordID: row.recordId, context: row.context) }.buttonStyle(.borderedProminent).disabled(row.downloadState != "downloaded" && (!row.available || !row.sourceOnline))
            }
            resourcePath(row, dark: true)
            }.padding(18)
        }.foregroundStyle(.white).background(Color(red: 0.10, green: 0.13, blue: 0.18)).frame(width: 690, height: 530)
    }
    private func imageCaption(_ row: ClipboardRecordView) -> String {
        if row.originLocal { return imageLoading ? "本机内容 · 正在读取图片…" : loadedOriginal ? "\(row.imageWidth) × \(row.imageHeight) · 本地图片" : "本地图片暂不可用" }
        if row.downloadState != "downloaded" { return "预览图 · 等待原图缓存" }
        if imageLoading { return "已缓存原图 · 正在读取…" }
        return loadedOriginal ? "\(row.imageWidth) × \(row.imageHeight) · 原图" : "已缓存原图 · 原图预览暂不可用"
    }
    @MainActor private func refreshContent() async {
        generation = UUID(); let captured = generation, identity = imageIdentity
        image = nil; loadedOriginal = false; imageError = nil; imageLoading = false
        localResource = nil; resourceLoading = false; resourceError = nil
        guard let row else { return }
        if row.kind == "text" {
            text = ""
            model.server.clipboardDetailText(source: row.sourceDeviceId, recordID: row.recordId, context: row.context) { value in
                if generation == captured, imageIdentity == identity, model.snapshot.clipboardContext == row.context { text = value ?? "记录状态已变化，请重新打开" }
            }
            return
        }
        let original = row.originLocal || row.downloadState == "downloaded"
        imageLoading = row.kind == "image"
        if original {
            resourceLoading = true
            let resource: ClipboardLocalResource? = await withCheckedContinuation { continuation in
                model.server.locateClipboardResource(source: row.sourceDeviceId, recordID: row.recordId, context: row.context) { continuation.resume(returning: $0) }
            }
            guard generation == captured, imageIdentity == identity, model.snapshot.clipboardContext == row.context, !Task.isCancelled else { return }
            resourceLoading = false; localResource = resource
            if resource == nil { resourceError = unavailableMessage(row) }
        } else { resourceError = unavailableMessage(row) }
        guard row.kind == "image" else { return }
        // 本机/已下载图片必须读取验证后的原件，不以小预览冒充原图。
        let usingOriginal = original && localResource != nil
        let url = localResource?.url ?? row.previewURL
        guard let url else {
            imageLoading = false
            imageError = original ? resourceError : row.previewState == "unsupported" ? "对端暂不支持图片预览" : row.previewState == "offline" ? "来源设备未连接" : row.previewState == "loading" ? "正在获取预览…" : "暂无图片预览"
            return
        }
        let readingResource = original ? localResource : nil
        // 换身份会清空页面 State；旧解码返回前仍由本轮局部持有者保护快照。
        defer { withExtendedLifetime(readingResource) {} }
        let value = await loadImage(url, maximum: usingOriginal ? max(row.imageWidth, row.imageHeight) : 320)
        guard generation == captured, imageIdentity == identity, model.snapshot.clipboardContext == row.context, !Task.isCancelled else { return }
        imageLoading = false; image = value; loadedOriginal = usingOriginal && value != nil
        if value == nil { imageError = original ? "本地图片暂时无法预览，请尝试在 Finder 中查看" : "图片预览读取失败" }
    }
}

/// 手势只属于图片画布；加载身份变化时新建此视图，旧图的倍率与位移不会带到新图。
struct ClipboardZoomCanvas: View {
    let image: NSImage
    @Environment(\.displayScale) private var displayScale
    @State private var scale: CGFloat = 1
    @State private var restingScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var restingOffset = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            // 工具条拥有独立布局空间，不遮挡图片；平移边界只按实际画布计算。
            let viewport = CGSize(width: geometry.size.width, height: max(1, geometry.size.height - 48))
            let fitted = fittedSize(in: viewport)
            VStack(spacing: 0) {
            Image(nsImage: image).resizable().frame(width: fitted.width, height: fitted.height)
                .scaleEffect(scale).offset(offset)
                .frame(width: viewport.width, height: viewport.height)
                .contentShape(Rectangle()).clipped()
                .gesture(MagnifyGesture()
                    .onChanged { value in
                        scale = min(max(5, actualScale(fitted)), max(minimumScale(fitted), restingScale * value.magnification))
                        offset = bounded(offset, fitted: fitted, viewport: viewport)
                    }
                    .onEnded { _ in restingScale = scale; restingOffset = offset })
                .simultaneousGesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = bounded(CGSize(width: restingOffset.width + value.translation.width, height: restingOffset.height + value.translation.height), fitted: fitted, viewport: viewport)
                    }
                    .onEnded { _ in restingOffset = offset })
                .onTapGesture(count: 2) { toggleZoom() }
                .help("双指缩放，放大后可拖动；双击放大或恢复")
                .accessibilityLabel("图片画布，可双指缩放、放大后拖动，双击放大或恢复")
                .accessibilityValue("\(Int((scale / actualScale(fitted) * 100).rounded()))%")
                .accessibilityIdentifier("clipboard-image-canvas")
            HStack(spacing: 10) {
                Button { zoom(to: scale / 1.25, fitted: fitted, viewport: viewport) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("缩小图片").disabled(scale <= minimumScale(fitted))
                Text("\(Int((scale / actualScale(fitted) * 100).rounded()))%")
                    .monospacedDigit().frame(minWidth: 42).foregroundStyle(.secondary)
                Button { zoom(to: scale * 1.25, fitted: fitted, viewport: viewport) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("放大图片").disabled(scale >= max(5, actualScale(fitted)))
                Divider().frame(height: 16)
                Button("适合窗口 / 重置") { reset() }
                Button("实际大小") { zoom(to: actualScale(fitted), fitted: fitted, viewport: viewport) }
            }.buttonStyle(.bordered).font(.system(size: 11)).frame(maxWidth: .infinity).frame(height: 48).background(.bar)
            }
            .onChange(of: geometry.size) { _, _ in
                offset = bounded(offset, fitted: fitted, viewport: viewport); restingOffset = offset
            }
        }
    }
    private func zoom(to value: CGFloat, fitted: CGSize, viewport: CGSize) {
        scale = min(max(5, actualScale(fitted)), max(minimumScale(fitted), value)); restingScale = scale
        offset = bounded(offset, fitted: fitted, viewport: viewport); restingOffset = offset
    }
    private func fittedSize(in viewport: CGSize) -> CGSize {
        let width = max(1, image.size.width), height = max(1, image.size.height)
        let factor = min(max(1, viewport.width - 50) / width, max(1, viewport.height - 50) / height)
        return CGSize(width: width * factor, height: height * factor)
    }
    private func bounded(_ proposed: CGSize, fitted: CGSize, viewport: CGSize) -> CGSize {
        let x = max(0, (fitted.width * scale - viewport.width) / 2)
        let y = max(0, (fitted.height * scale - viewport.height) / 2)
        return CGSize(width: min(x, max(-x, proposed.width)), height: min(y, max(-y, proposed.height)))
    }
    // 一个图片像素对应一个显示像素，Retina 下按屏幕倍率换算点尺寸。
    private func actualScale(_ fitted: CGSize) -> CGFloat {
        let pixels = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
        return CGFloat(max(1, pixels)) / max(1, displayScale) / max(1, fitted.width)
    }
    private func minimumScale(_ fitted: CGSize) -> CGFloat { min(0.05, actualScale(fitted)) }
    private func reset() { scale = 1; restingScale = 1; offset = .zero; restingOffset = .zero }
    private func toggleZoom() {
        if scale > 1 { reset() }
        else { scale = 2; restingScale = 2; offset = .zero; restingOffset = .zero }
    }
}

private func loadImage(_ url: URL, maximum: Int) async -> NSImage? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continuation.resume(returning: nil); return }
            continuation.resume(returning: NSImage(cgImage: thumbnail, size: .zero))
        }
    }
}
