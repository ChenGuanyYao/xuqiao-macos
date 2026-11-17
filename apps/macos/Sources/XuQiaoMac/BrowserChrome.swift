import SwiftUI

/// 相册与文件共享固定的标题和状态位置，内容区只负责展示当前页。
struct BrowserHeader<Actions: View>: View {
    let title: String
    let symbol: String
    let device: String
    let connected: Bool
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 21, weight: .regular))
                .foregroundStyle(NativeTheme.blue).frame(width: 36, height: 36)
                .background(NativeTheme.blueLight, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(NativeTheme.ink)
                HStack(spacing: 6) {
                    Circle().fill(connected ? Color.green : NativeTheme.muted).frame(width: 5, height: 5)
                    Text(device).lineLimit(1).help(device)
                    Text(connected ? "已连接" : "未连接").fixedSize()
                }.font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
            }
            Spacer(minLength: 16)
            actions
        }.controlSize(.large).padding(.horizontal, 20).padding(.vertical, 16).background(.bar)
    }
}

struct BrowserStatus: View {
    let message: String
    var busy = false
    var warning = false
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if busy { ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14) }
            else { Image(systemName: warning ? "exclamationmark.circle" : "info.circle").frame(width: 14) }
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.foregroundStyle(warning ? Color.orange : NativeTheme.muted)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(warning ? Color.orange.opacity(0.05) : NativeTheme.sidebar.opacity(0.5))
    }
}

struct BrowserIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30)
        }.buttonStyle(.plain).foregroundStyle(NativeTheme.blue)
            .background(NativeTheme.blueLight.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .help(title).accessibilityLabel(title)
    }
}

/// 只在提交或选择排序时请求对端完整授权范围，不对当前页做伪搜索。
struct BrowserQueryBar: View {
    let placeholder: String
    @Binding var query: String
    @Binding var sort: String
    let options: [(String, String)]
    let capable: Bool
    let disabled: Bool
    let submit: () -> Void
    private var valid: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count <= 128 }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField(placeholder, text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit { if valid && capable && !disabled { submit() } }
                Button("查找", action: submit).disabled(!valid)
                Picker("排序", selection: $sort) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }.labelsHidden().frame(width: 130)
                    .onChange(of: sort) { _, _ in if capable && !disabled && valid { submit() } }
            }.disabled(!capable || disabled)
            if !capable { Text("手机版本暂不支持范围查找与排序，当前仅显示默认列表。") }
            else if !valid { Text("查找关键词不能超过128字节，请缩短后重试。").foregroundStyle(.orange) }
        }.font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
            .padding(.horizontal, 20).padding(.bottom, 10)
    }
}
