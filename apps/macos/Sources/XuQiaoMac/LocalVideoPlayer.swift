import AVKit
import SwiftUI
import XuQiaoCore
import UniformTypeIdentifiers

/// 持有服务校验后的完整本地资源；页面离开或身份变更立即暂停并释放播放器。
struct LocalVideoPlayer: View {
    let resource: ClipboardLocalResource
    let fileName: String
    @StateObject private var playback = LocalVideoPlayback()
    var body: some View {
        ZStack {
            Color.black
            if let player = playback.player { NativeVideoSurface(player: player) }
            if playback.loading { ProgressView().tint(.white).allowsHitTesting(false) }
            if let error = playback.error {
                VStack(spacing: 12) { Image(systemName: "video.slash").font(.system(size: 28)); Text(error).font(.system(size: 12)).multilineTextAlignment(.center) }
                    .foregroundStyle(.white.opacity(0.8)).padding(22)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 10))
            .task(id: resource.url) { await playback.load(resource, fileName: fileName) }
            .onDisappear { playback.stop() }
            .accessibilityIdentifier("local-video-player")
    }
}

/// 使用 AppKit 原生承载面，避免实例化当前系统会崩溃的 AVKit SwiftUI overlay 泛型。
private struct NativeVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player?.pause(); view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

@MainActor
private final class LocalVideoPlayback: ObservableObject {
    @Published var player: AVPlayer?
    @Published var loading = false
    @Published var error: String?
    private var epoch = UUID()
    private var statusObservation: NSKeyValueObservation?
    private var retainedResource: ClipboardLocalResource?
    func load(_ resource: ClipboardLocalResource, fileName: String) async {
        stop(); let captured = epoch; loading = true; error = nil
        retainedResource = resource
        // 即使页面已离开，未结束的异步媒体读取仍需持有该快照的 lease。
        defer { withExtendedLifetime(resource) {} }
        let url = resource.url
        guard url.isFileURL else { loading = false; error = "本地视频位置不可用"; return }
        // 不跟随容器中指向其他本地文件或远端地址的媒体引用。
        var options: [String: Any] = [AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)]
        // 私有快照名为无扩展 payload；只补原文件名的格式提示，不复制或改名快照。
        if url.pathExtension.isEmpty,
           let mime = UTType(filenameExtension: URL(fileURLWithPath: fileName).pathExtension)?.preferredMIMEType {
            options[AVURLAssetOverrideMIMETypeKey] = mime
        }
        let asset = AVURLAsset(url: url, options: options)
        do {
            let playable = try await asset.load(.isPlayable)
            guard captured == epoch, !Task.isCancelled else { return }
            guard playable else { loading = false; error = "此视频格式或编码暂不支持播放"; return }
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            self.player = player
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self, self.epoch == captured else { return }
                    switch item.status {
                    case .readyToPlay: self.loading = false
                    case .failed: self.loading = false; self.error = "视频无法播放，文件可能已失效或编码不受支持"; self.player?.pause()
                    default: break
                    }
                }
            }
            // 不自动播放，用户使用 AVKit 原生播放按钮决定何时开始。
        } catch {
            guard captured == epoch, !Task.isCancelled else { return }
            loading = false; self.error = "视频无法读取，文件可能已失效或格式不受支持"
        }
    }
    func stop() {
        epoch = UUID(); statusObservation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; loading = false
        // 必须先停止并释放播放器，再释放资源持有的快照 lease。
        retainedResource = nil
    }
}
