import SwiftUI
import AppKit
import XuQiaoCore

struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    @State private var saving = false
    @State private var error: String?
    @State private var bluetoothActionPending = false
    @State private var bluetoothGuidance: String?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(DesktopPreferences.keepRunningInMenuBarKey) private var keepRunningInMenuBar = true
    private let kinds = [("text", "文字", "text.alignleft"), ("image", "图片与截图", "photo"), ("file", "文件", "doc"), ("folder", "文件夹", "folder"), ("group", "文件组", "square.stack.3d.up")]
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            Text("设置").font(.system(size: 24, weight: .semibold))
            if let message = error ?? model.snapshot.clipboardPreferencesError { NativeNotice(text: message, warning: true) }
            section("通用") {
                preferenceRow("关闭窗口后保留在状态栏", subtitle: "关闭主窗口后继续连接，在顶部状态栏菜单中选择“退出续桥”结束运行", symbol: "menubar.rectangle", value: $keepRunningInMenuBar)
                    .accessibilityIdentifier("keep-running-in-menu-bar")
            }
            section("自动同步") {
                preferenceRow("自动同步", subtitle: "向所有已配对手机同步新内容，手机可自行关闭", symbol: "arrow.triangle.2.circlepath", value: binding(\.enabled))
                Divider().padding(.leading, 52)
                Button { model.selection = .devices } label: { navigationRow("同步设备", symbol: "iphone", value: "\(model.snapshot.peers.count) 台已配对") }.buttonStyle(.plain)
            }.disabled(saving || model.snapshot.clipboardContext.isEmpty)
            section("同步内容") {
                ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                    if index > 0 { Divider().padding(.leading, 52) }
                    preferenceRow(kind.1, symbol: kind.2, value: kindBinding(kind.0))
                }
            }.disabled(saving || model.snapshot.clipboardContext.isEmpty)
            section("接收与预览") {
                preferenceRow("文字自动写入剪贴板", subtitle: "关闭后仍保留文字记录，由你选择复制", symbol: "text.badge.checkmark", value: binding(\.autoApplyText))
                Divider().padding(.leading, 52)
                preferenceRow("自动显示图片预览", subtitle: "开启时自动显示小缩略图；图片原图自动保留内部缓存，点击下载后才保存到 Downloads/续桥", symbol: "photo", value: binding(\.previewsEnabled))
            }.disabled(saving || model.snapshot.clipboardContext.isEmpty)
            section("文件接收") {
                preferenceRow("接收文件前确认", subtitle: "默认自动接收已配对设备的文件，在“文件传输”查看；开启后弹窗确认。", symbol: "arrow.down.doc", value: $model.confirmIncomingFiles)
                Divider().padding(.leading, 52)
                HStack(spacing: 12) {
                    rowIcon("folder")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("接收文件夹").font(.system(size: 13))
                        Text(model.snapshot.files.receiveFolderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "请选择接收文件夹")
                            .font(.system(size: 11)).foregroundStyle(NativeTheme.muted).lineLimit(1).truncationMode(.middle)
                            .help(model.snapshot.files.receiveFolderPath ?? "").accessibilityIdentifier("receive-folder-path")
                        Text("文件收完后自动保存；同名文件自动编号。剪贴板缓存单独管理。")
                            .font(.system(size: 10)).foregroundStyle(NativeTheme.muted)
                    }
                    Spacer()
                    Button("更改…") { model.chooseReceiveFolder() }.disabled(model.choosingReceiveFolder || !model.snapshot.ready)
                        .accessibilityIdentifier("receive-folder-change")
                }.padding(.horizontal, 17).padding(.vertical, 13)
            }
            section("存储与连接") {
                Button { model.selection = .storage } label: { navigationRow("缓存与存储", symbol: "internaldrive", value: readableBytes(model.snapshot.clipboardCache.bytes + model.snapshot.clipboardCache.previewBytes + model.snapshot.clipboardCache.privateImageBytes)) }.buttonStyle(.plain)
                Divider().padding(.leading, 52)
                HStack(spacing: 12) { rowIcon("network"); Text("局域网连接").font(.system(size: 13)); Spacer(); Text(model.snapshot.host).font(.system(size: 12)).foregroundStyle(NativeTheme.muted).textSelection(.enabled) }.padding(.horizontal, 17).frame(minHeight: 53)
                Divider().padding(.leading, 52)
                bluetoothRow
            }
            HStack(spacing: 12) { AppIconView(size: 42); VStack(alignment: .leading, spacing: 4) { Text("续桥").font(.system(size: 14, weight: .medium)); Text("设备之间，自然接续").font(.system(size: 11)).foregroundStyle(NativeTheme.muted) }; Spacer(); Text((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—") + ")").font(.system(size: 11)).foregroundStyle(NativeTheme.muted) }.padding(.horizontal, 4).padding(.top, 4)
        }.frame(maxWidth: 740, alignment: .leading)
            .onAppear { model.server.refreshBluetoothWakeAuthorization() }
            .onChange(of: scenePhase) { _, value in
                if value == .active { model.server.refreshBluetoothWakeAuthorization() }
            }
    }
    private var bluetoothRow: some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon("antenna.radiowaves.left.and.right")
            VStack(alignment: .leading, spacing: 6) {
                Text("蓝牙辅助重连").font(.system(size: 13))
                Text(model.snapshot.bluetoothWakeAuthorization.label + " · " + model.snapshot.bluetoothWakeHardware.label)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(NativeTheme.muted)
                    .accessibilityIdentifier("bluetooth-wake-authorization")
                Text(model.snapshot.bluetoothWakeStatus).font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
                Text("蓝牙用于辅助发现与唤醒，内容仍通过局域网同步。拒绝或关闭后局域网功能继续，后台辅助唤醒会受限。")
                    .font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
                if let bluetoothGuidance { Text(bluetoothGuidance).font(.system(size: 11)).foregroundStyle(NativeTheme.blue) }
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(model.snapshot.bluetoothWakeAuthorization == .notDetermined ? "申请蓝牙权限" : "打开系统设置") {
                bluetoothActionPending = true
                model.server.requestBluetoothWakeAuthorization { openSettings in
                    bluetoothActionPending = false
                    guard openSettings else { return }
                    let path = model.snapshot.bluetoothWakeAuthorization == .allowed ? "蓝牙" : "隐私与安全性 → 蓝牙 → 续桥"
                    bluetoothGuidance = "请在系统设置的“\(path)”中检查。系统限制可能需要管理员处理。"
                    // 使用公开的应用打开能力，并展示确定的手动路径；不依赖私有设置 URL。
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                        if !NSWorkspace.shared.open(url) { bluetoothGuidance = "无法打开系统设置，请手动前往“\(path)”。" }
                    } else { bluetoothGuidance = "请手动打开系统设置，前往“\(path)”。" }
                }
            }.controlSize(.small).disabled(bluetoothActionPending)
                .accessibilityIdentifier("bluetooth-wake-permission-action")
        }.padding(.horizontal, 17).padding(.vertical, 13)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) { NativeSectionTitle(title: title); VStack(spacing: 0, content: content).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativeTheme.line, lineWidth: 1)) }
    }
    private func rowIcon(_ symbol: String) -> some View { Image(systemName: symbol).font(.system(size: 15, weight: .regular)).foregroundStyle(NativeTheme.blue).frame(width: 27, height: 29).background(NativeTheme.blueLight, in: RoundedRectangle(cornerRadius: 7)) }
    private func preferenceRow(_ title: String, subtitle: String? = nil, symbol: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            rowIcon(symbol)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 13)); if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(NativeTheme.muted).fixedSize(horizontal: false, vertical: true) } }
            Spacer(minLength: 12); Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(title)
        }.padding(.horizontal, 17).padding(.vertical, 13).frame(minHeight: 54)
    }
    private func navigationRow(_ title: String, symbol: String, value: String) -> some View {
        HStack(spacing: 12) { rowIcon(symbol); Text(title).font(.system(size: 13)); Spacer(); Text(value).font(.system(size: 11)).foregroundStyle(NativeTheme.muted); Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(NativeTheme.muted.opacity(0.7)) }.padding(.horizontal, 17).frame(minHeight: 53).contentShape(Rectangle())
    }
    private func binding(_ path: WritableKeyPath<ClipboardPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { model.snapshot.clipboardPreferences[keyPath: path] }, set: { value in var revised = model.snapshot.clipboardPreferences; revised[keyPath: path] = value; save(revised) })
    }
    private func kindBinding(_ kind: String) -> Binding<Bool> {
        Binding(get: { model.snapshot.clipboardPreferences.kinds.contains(kind) }, set: { value in
            var revised = model.snapshot.clipboardPreferences
            if value { if !revised.kinds.contains(kind) { revised.kinds.append(kind) } } else { revised.kinds.removeAll { $0 == kind } }
            save(revised)
        })
    }
    private func save(_ value: ClipboardPreferences) {
        guard !saving else { return }; saving = true; error = nil
        model.server.saveClipboardPreferences(value, context: model.snapshot.clipboardContext) { message in saving = false; error = message }
    }
}

struct StoragePage: View {
    @EnvironmentObject var model: AppModel
    @State private var previews = true
    @State private var sources = false
    @State private var clearing = false
    @State private var confirmation = false
    @State private var historyConfirmation = false
    @State private var originalsConfirmation = false
    @State private var historyKeys: [String] = []
    @State private var historyContext = ""
    @State private var frozenContext = ""
    @State private var frozenPreviews = false
    @State private var frozenSources = false
    @State private var result: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button { model.selection = .settings } label: { Label("设置", systemImage: "chevron.left") }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(NativeTheme.blue)
            Text("缓存与存储").font(.system(size: 24, weight: .semibold))
            NativeCard {
                VStack(alignment: .leading, spacing: 15) {
                    Text("临时缓存").font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
                    Text(readableBytes(model.snapshot.clipboardCache.bytes + model.snapshot.clipboardCache.previewBytes + model.snapshot.clipboardCache.privateImageBytes)).font(.system(size: 33, weight: .semibold)).monospacedDigit()
                    HStack(spacing: 18) { Label("发送快照", systemImage: "circle.fill").foregroundStyle(NativeTheme.blue); Label("预览 / 内部原图", systemImage: "circle.fill").foregroundStyle(NativeTheme.muted) }.font(.system(size: 10))
                }
            }
            VStack(spacing: 0) {
                cacheOption("图片预览", subtitle: "\(model.snapshot.clipboardCache.previewCount) 项 · 可按需重新获取", bytes: model.snapshot.clipboardCache.previewBytes, selected: $previews)
                Divider().padding(.leading, 18)
                cacheOption("发送快照", subtitle: "\(model.snapshot.clipboardCache.snapshotCount) 项 · 清理后其他设备将无法下载这些原内容", bytes: model.snapshot.clipboardCache.bytes, selected: $sources)
            }.background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativeTheme.line, lineWidth: 1))
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("内部原图缓存").font(.system(size: 13, weight: .medium))
                    Text("\(model.snapshot.clipboardCache.privateImageCount) 项 · 可独立清理；保留记录、缩略图和已导出文件").font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
                }
                Spacer(); Text(readableBytes(model.snapshot.clipboardCache.privateImageBytes)).font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
                Button("清理内部原图…", role: .destructive) {
                    frozenContext = model.snapshot.clipboardContext; originalsConfirmation = true
                }.disabled(clearing || model.snapshot.clipboardContext.isEmpty || model.snapshot.clipboardCache.privateImageCount == 0)
            }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 12))
            Button("清理剪贴板历史…", role: .destructive) {
                clearing = true
                model.server.allClipboardKeys(source: "", kind: "", query: "") { keys, context in
                    clearing = false; historyKeys = keys; historyContext = context; historyConfirmation = true
                }
            }.disabled(clearing || model.snapshot.clipboardContext.isEmpty)
            OperationNotice(text: $result)
            HStack { Spacer(); Button(clearing ? "正在清理…" : "清理所选缓存…") { frozenContext = model.snapshot.clipboardContext; frozenPreviews = previews; frozenSources = sources; confirmation = true }.buttonStyle(.borderedProminent).disabled(clearing || !previews && !sources || model.snapshot.clipboardContext.isEmpty) }
            Text("预览、发送快照与内部原图分别清理。独立清理原图保留记录、缩略图及导出成品；活动项和无法重新获取的内容会保留，并在结果中说明。").font(.system(size: 11)).foregroundStyle(NativeTheme.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: 740, alignment: .leading)
            .alert("仅清理内部原图？", isPresented: $originalsConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清理可释放原图", role: .destructive) {
                    guard frozenContext == model.snapshot.clipboardContext else { result = "状态已变化，请重新确认"; return }
                    clearing = true; result = nil
                    // Core按引用和可重取性决定保护项，UI不能把跳过项描述成全部成功。
                    model.server.clearClipboardPrivateImages(context: frozenContext) { value in
                        clearing = false
                        result = managementMessage(value) + "。记录、缩略图和导出成品保留；使用中或无法确认可重取的原图已保留。"
                    }
                }
            } message: { Text("保留历史记录、缩略图和已导出的文件。释放后查看原图可能需要来源设备在线并重新获取；活动任务及不可重取的内容会受到保护，结果会报告保留和失败数量。") }
            .alert("清理全部剪贴板历史？", isPresented: $historyConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清理 \(historyKeys.count) 条", role: .destructive) {
                    guard historyContext == model.snapshot.clipboardContext else { result = "状态已变化，请重新确认"; return }
                    clearing = true
                    model.server.deleteManyClipboard(keys: historyKeys, context: historyContext) { value in clearing = false; result = managementMessage(value) }
                }
            } message: { Text("清理全部来源的历史，并回收无其它记录引用的内部原图及临时数据。原始文件、Downloads/续桥和其他已保存文件保留；活动任务跳过。") }
            .alert("清理所选缓存？", isPresented: $confirmation) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    guard frozenContext == model.snapshot.clipboardContext else { result = "状态已变化，请重新确认"; return }
                    clearing = true
                    model.server.clearClipboardCache(previews: frozenPreviews, sources: frozenSources, context: frozenContext) { value in clearing = false; result = managementMessage(value) }
                }
            } message: { Text(frozenSources ? "发送快照清理后，其他设备将不能再下载这些原内容。已下载文件和历史记录保留；使用中的缓存跳过。" : "仅清理小缩略图，不删除原图、历史记录或已下载文件。需要时可重新获取预览。") }
    }
    private func cacheOption(_ title: String, subtitle: String, bytes: Int64, selected: Binding<Bool>) -> some View {
        HStack(spacing: 12) { Toggle(title, isOn: selected).labelsHidden().toggleStyle(.checkbox); VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 13, weight: .medium)); Text(subtitle).font(.system(size: 11)).foregroundStyle(NativeTheme.muted).fixedSize(horizontal: false, vertical: true) }; Spacer(); Text(readableBytes(bytes)).font(.system(size: 12)).foregroundStyle(NativeTheme.muted) }.padding(18).disabled(clearing)
    }
}
