import AppKit
import SwiftUI
import XuQiaoCore

enum NativeTheme {
    static let ink = Color(red: 0.11, green: 0.15, blue: 0.20)
    static let muted = Color(red: 0.41, green: 0.47, blue: 0.56)
    static let line = Color(red: 0.89, green: 0.92, blue: 0.95)
    static let blue = Color(red: 0.19, green: 0.47, blue: 0.96)
    static let blueLight = Color(red: 0.92, green: 0.95, blue: 1)
    static let sidebar = Color(red: 0.94, green: 0.95, blue: 0.97)
    static let background = Color(red: 0.98, green: 0.985, blue: 0.995)
}

// roots 已是协议中的顶层名称，直接展示以保留名称原貌。
func groupContentsPreview(_ roots: [String]) -> String {
    guard !roots.isEmpty else { return "文件组" }
    return roots.prefix(3).joined(separator: "、")
}

func groupContentsCount(_ roots: [String]) -> String {
    guard !roots.isEmpty else { return "文件组" }
    let remaining = max(0, roots.count - 3)
    return remaining > 0 ? "文件组 · 共 \(roots.count) 项，另 \(remaining) 项" : "文件组 · 共 \(roots.count) 项"
}

struct NativeCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(NativeTheme.line, lineWidth: 1))
    }
}

struct NativeSectionTitle: View {
    let title: String
    var trailing: String = ""
    var body: some View {
        HStack { Text(title).font(.system(size: 12, weight: .medium)); Spacer(); Text(trailing).font(.system(size: 11)) }
            .foregroundStyle(NativeTheme.muted).padding(.horizontal, 2)
    }
}

struct NativeNotice: View {
    let text: String
    var warning = false
    var body: some View {
        Label(text, systemImage: warning ? "exclamationmark.circle" : "info.circle")
            .font(.system(size: 12)).foregroundStyle(warning ? Color.orange : NativeTheme.muted)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(warning ? Color.orange.opacity(0.06) : NativeTheme.blueLight.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct NativeSearchField: View {
    let placeholder: String
    @Binding var text: String
    var identifier = "record-search"
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12)).accessibilityIdentifier(identifier)
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索").accessibilityIdentifier(identifier + "-clear") }
        }.padding(.horizontal, 11).frame(height: 33).background(NativeTheme.sidebar.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct NativeStatus: View {
    let title: String
    var color: Color = NativeTheme.muted
    var body: some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(title).font(.system(size: 11)) }.foregroundStyle(color)
    }
}

struct ContentTypeIcon: View {
    let kind: String
    var name = ""
    var size: CGFloat = 38
    private var ext: String { URL(fileURLWithPath: name).pathExtension.lowercased() }
    private var family: String {
        if kind != "file" { return kind }
        if isVideoFile(name) { return "video" }
        if ext == "pdf" { return "pdf" }
        if ["txt", "md", "markdown", "log", "json", "yaml", "yml", "xml", "ini", "conf", "toml"].contains(ext) { return "text-file" }
        if ["doc", "docx", "pages"].contains(ext) { return "document" }
        if ["xls", "xlsx", "csv", "numbers"].contains(ext) { return "sheet" }
        if ["zip", "7z", "rar", "gz", "tar"].contains(ext) { return "archive" }
        return "file"
    }
    private var tint: Color {
        switch family { case "pdf": Color(red: 0.81, green: 0.34, blue: 0.34); case "sheet": Color(red: 0.22, green: 0.59, blue: 0.43); case "archive": Color(red: 0.68, green: 0.48, blue: 0.23); case "text-file": Color(red: 0.43, green: 0.50, blue: 0.58); case "video": Color(red: 0.68, green: 0.39, blue: 0.57); case "folder": Color(red: 0.29, green: 0.56, blue: 0.83); case "group": Color(red: 0.47, green: 0.48, blue: 0.72); default: NativeTheme.blue }
    }
    private var symbol: String {
        switch family { case "text": "text.alignleft"; case "text-file": "doc.plaintext"; case "image": "photo"; case "video": "play.rectangle"; case "folder": "folder.fill"; case "group": "square.stack.3d.up.fill"; case "sheet": "tablecells"; case "archive": "doc.zipper"; case "pdf": "doc.richtext"; default: "doc.text" }
    }
    private var extensionLabel: String {
        switch family {
        case "pdf": "PDF"
        case "sheet": "XLS"
        case "archive": "ZIP"
        case "text-file": ext == "markdown" ? "MD" : String(ext.uppercased().prefix(5))
        case "video": ext.isEmpty ? "VIDEO" : String(ext.uppercased().prefix(5))
        default: "DOC"
        }
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.085))
            Image(systemName: symbol).font(.system(size: size * 0.53, weight: .light)).foregroundStyle(tint).frame(maxHeight: .infinity)
            if ["pdf", "document", "sheet", "archive", "video", "text-file"].contains(family) {
                Text(extensionLabel)
                    .font(.system(size: 7, weight: .bold)).tracking(0.5).foregroundStyle(tint)
                    .padding(.bottom, 3).frame(maxWidth: .infinity).background(tint.opacity(0.08))
            }
        }.frame(width: size, height: size + 5).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
    }
}

/// 扩展名仅决定图标和播放器入口，能否播放仍由系统解码能力判断。
func isVideoFile(_ name: String) -> Bool {
    ["mp4", "mov", "m4v", "webm", "mkv", "avi", "3gp", "3g2", "mpg", "mpeg", "wmv", "flv", "mts", "m2ts", "ogv"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
}

func isImageFile(_ name: String) -> Bool {
    ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "bmp", "tif", "tiff", "avif", "ico", "svg"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
}

struct LocalResourcePathView: View {
    let title: String
    let path: String?
    let loading: Bool
    let unavailable: String
    var dark = false
    let reveal: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                if path != nil {
                    Button("在 Finder 中显示", action: reveal).font(.system(size: 11)).buttonStyle(.plain)
                        .foregroundStyle(dark ? Color.white : NativeTheme.blue).disabled(loading)
                        .accessibilityLabel("在 Finder 中显示本地文件")
                }
            }
            if loading {
                HStack(spacing: 7) { ProgressView().controlSize(.mini); Text("正在校验本地位置…").font(.system(size: 11)) }
            } else if let path {
                ScrollView(.horizontal) { Text(path).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
                    .scrollIndicators(.hidden).frame(height: 18).accessibilityIdentifier("local-resource-path")
            } else { Text(unavailable).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
        }.foregroundStyle(dark ? Color.white.opacity(0.65) : NativeTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecordSelectionBox: View {
    @Binding var selected: Bool
    let label: String
    var body: some View {
        Toggle(label, isOn: $selected).labelsHidden().toggleStyle(.checkbox).controlSize(.small).accessibilityLabel(label)
    }
}

func readableBytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
func managementMessage(_ value: ManagementResult) -> String {
    "已清理 \(value.removed) 项" + (value.keptActive > 0 ? " · 保留使用中的 \(value.keptActive) 项" : "") + (value.failed > 0 ? " · \(value.failed) 项未完成" : "")
}

/// 短后缀来自已信任的稳定设备ID；名称用于展示，地址不作为身份。
func deviceLabel(_ name: String, id: String) -> String {
    name + " · " + String(id.suffix(8))
}

/// 兼容Core现有结果文案：仅明确成功前缀可短暂显示，未知或部分失败结果保留。
func operationNoticeIsTransient(_ text: String) -> Bool {
    let prefixes = ["已清理", "已复制", "已保存", "文件已导出", "已写入系统剪贴板", "原图已保存到", "记录已删除"]
    guard prefixes.contains(where: { text.hasPrefix($0) }) else { return false }
    // 只消除完整的零失败计数；失败1/10/01项、无计数失败、部分失败均不会被消除。
    let outcome = text.replacingOccurrences(of: #"失败\s*0\s*项"#, with: "", options: .regularExpression)
    return !["失败", "未完成", "错误", "未能", "无法"].contains(where: { outcome.contains($0) })
}

struct OperationNotice: View {
    @Binding var text: String?
    private var transient: Bool { text.map(operationNoticeIsTransient) ?? false }
    var body: some View {
        if let value = text {
            HStack(alignment: .top) {
                NativeNotice(text: value)
                Button { text = nil } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
            }.task(id: value) {
                guard transient else { return }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, text == value else { return }
                text = nil
            }
        }
    }
}
