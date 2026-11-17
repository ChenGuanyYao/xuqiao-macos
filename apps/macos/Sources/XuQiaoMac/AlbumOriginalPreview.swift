import AppKit
import SwiftUI
import ImageIO
import XuQiaoCore

private final class AlbumDecodeCancellation: @unchecked Sendable {
    private let lock=NSLock()
    private var stopped=false
    var cancelled:Bool {lock.lock();defer{lock.unlock()};return stopped}
    func cancel(){lock.lock();stopped=true;lock.unlock()}
}
@MainActor
private final class AlbumOriginalImage:ObservableObject {
    @Published var image:NSImage?
    @Published var message="正在获取内部原图…"
    private var revision=UUID()
    private var cancellation=AlbumDecodeCancellation()
    private let io=DispatchQueue(label:"com.chenguangyao.xuqiao.album-preview",qos:.userInitiated)
    func load(server:PairingServer,peer:PeerView,asset:MediaAssetView,grant:String,context:String) {
        clear();let expected=revision,token=cancellation
        server.previewAlbum(peerID:peer.id,expectedGeneration:peer.trustGeneration,grantID:grant,assetID:asset.id,context:context){[weak self] url in
            guard let self,self.revision==expected else{return}
            guard let url else{self.message="原图暂不可预览，可能超过32 MiB/3200万像素，或授权已失效。可尝试明确下载。";return}
            let expectedSize=asset.size
            self.io.async { [weak self] in
                // 使用NOFOLLOW固定本地收据文件；ImageIO只解码已检查大小和像素的这一张原件。
                guard !token.cancelled else{return}
                let decoded:CGImage? = autoreleasepool {
                    let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
                    guard fd>=0 else{return nil};defer{close(fd)}
                    var stat=Darwin.stat();guard fstat(fd,&stat)==0,stat.st_mode&S_IFMT==S_IFREG,stat.st_size==expectedSize,stat.st_size>0,stat.st_size<=32*1024*1024 else{return nil}
                    let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
                    guard !token.cancelled,let data=try? handle.read(upToCount:Int(stat.st_size)+1),!token.cancelled,data.count==Int(stat.st_size),let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,width>0,height>0,Int64(width)*Int64(height)<=32_000_000 else{return nil}
                    var after=Darwin.stat()
                    guard !token.cancelled,fstat(fd,&after)==0,after.st_size==stat.st_size,after.st_mtimespec.tv_sec==stat.st_mtimespec.tv_sec,after.st_mtimespec.tv_nsec==stat.st_mtimespec.tv_nsec,after.st_ctimespec.tv_sec==stat.st_ctimespec.tv_sec,after.st_ctimespec.tv_nsec==stat.st_ctimespec.tv_nsec else{return nil}
                    // 全尺寸ImageIO输出应用EXIF旋转及镜像方向，不改原件字节或降低预览分辨率。
                    return CGImageSourceCreateThumbnailAtIndex(source,0,[
                        kCGImageSourceCreateThumbnailFromImageAlways:true,
                        kCGImageSourceCreateThumbnailWithTransform:true,
                        kCGImageSourceThumbnailMaxPixelSize:max(width,height),
                        kCGImageSourceShouldCacheImmediately:true
                    ] as CFDictionary)
                }
                DispatchQueue.main.async{[weak self] in
                    guard let self,self.revision==expected,!token.cancelled else{return}
                    self.image=decoded.map{NSImage(cgImage:$0,size:.zero)};self.message=decoded==nil ? "原图格式或尺寸不支持预览，请明确下载后查看。":"原图预览 · 保存在续桥内部，尚未导出"
                }
            }
        }
    }
    func clear(){cancellation.cancel();cancellation=AlbumDecodeCancellation();revision=UUID();image=nil;message="正在获取内部原图…"}
}
struct AlbumOriginalPreview:View {
    @EnvironmentObject var model:AppModel
    let peer:PeerView
    let asset:MediaAssetView
    let grant:String
    let onClose:()->Void
    @StateObject private var original=AlbumOriginalImage()
    @State private var previewContext=UUID().uuidString
    private var valid:Bool {model.snapshot.peers.contains{$0.id==peer.id && $0.trustGeneration==peer.trustGeneration && $0.connected} && model.snapshot.media.contains{$0.peerId==peer.id && $0.grantId==grant && $0.albumState=="shared"}}
    var body:some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(NativeTheme.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).font(.system(size: 15, weight: .semibold)).lineLimit(1).help(asset.name)
                    Text(deviceLabel(peer.name, id: peer.id) + " · " + readableBytes(asset.size) + " · \(asset.width) × \(asset.height)")
                        .font(.system(size: 11)).foregroundStyle(NativeTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.vertical, 16).background(.bar)
            Divider()
            ZStack {
                Color(nsColor: NSColor(calibratedWhite: 0.10, alpha: 1))
                if let image = original.image {
                    ClipboardZoomCanvas(image: image).accessibilityLabel("原图 " + asset.name)
                } else if let data = asset.preview, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 320, maxHeight: 320)
                        .opacity(0.65).accessibilityLabel("缩略图 " + asset.name)
                } else {
                    Image(systemName: "photo").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.white.opacity(0.5))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 16) {
                Text(original.message).font(.system(size: 11)).foregroundStyle(NativeTheme.muted)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.server.downloadAlbum(peerID: peer.id, expectedGeneration: peer.trustGeneration, assetIDs: [asset.id]) } label: {
                    Label("下载原图", systemImage: "arrow.down.to.line")
                }.buttonStyle(.borderedProminent).disabled(!valid || asset.size > 134217728)
                    .help("保存到“下载/续桥”").accessibilityIdentifier("media-album-original-download")
            }.padding(.horizontal, 20).padding(.vertical, 14).background(.bar)
        }.background(NativeTheme.background).frame(minWidth: 620, idealWidth: 880, maxWidth: 960, minHeight: 440, idealHeight: 640, maxHeight: 700)
        .onAppear{if valid {original.load(server:model.server,peer:peer,asset:asset,grant:grant,context:previewContext)}}
        .onChange(of:valid){_,active in if !active {original.clear();onClose()}}
        .onDisappear{original.clear();model.server.closeAlbumPreview(peerID:peer.id,expectedGeneration:peer.trustGeneration,grantID:grant,assetID:asset.id,context:previewContext)}
    }
}
