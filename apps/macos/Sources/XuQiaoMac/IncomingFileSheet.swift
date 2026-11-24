import SwiftUI
import XuQiaoCore

struct IncomingFilePrompt: Identifiable {
    let task: FileTaskView
    let peer: PeerView
    var id: String { peer.id + "|" + peer.trustGeneration + "|" + task.id + "|" + task.attemptId }
}

struct IncomingFileSheet: View {
    @EnvironmentObject var model: AppModel
    let prompt: IncomingFilePrompt
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("接收文件？", systemImage: "arrow.down.doc").font(.system(size: 21, weight: .semibold))
            Text("来自 " + deviceLabel(prompt.peer.name, id: prompt.peer.id)).font(.system(size: 13)).foregroundStyle(NativeTheme.muted)
            VStack(alignment: .leading, spacing: 9) {
                Text(prompt.task.kind == "group" ? groupContentsPreview(prompt.task.roots) : prompt.task.name).font(.system(size: 15, weight: .medium)).lineLimit(3)
                Text((prompt.task.kind == "group" ? groupContentsCount(prompt.task.roots) + " · " : "") + readableBytes(prompt.task.totalBytes ?? prompt.task.size)).font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(NativeTheme.sidebar, in: RoundedRectangle(cornerRadius: 12))
            Text("文件收完后会自动保存到设置的接收文件夹，可在“文件传输”中打开。").font(.system(size: 12)).foregroundStyle(NativeTheme.muted)
            HStack {
                Button("稍后", role: .cancel) { model.fileReceivePrompt = nil }
                Spacer()
                Button("拒绝", role: .destructive) { model.respondToFileOffer(prompt, accept: false) }
                Button(prompt.task.kind == "group" ? "接收全部" : "接收") { model.respondToFileOffer(prompt, accept: true) }.buttonStyle(.borderedProminent)
            }
        }.padding(26).frame(width: 440)
    }
}
