import Foundation
import ImageIO
import AppKit

private final class MediaPeerSession {
    let peer:String, control:UUID, generation:String
    var view:DeviceMediaView
    var screenRequest="",nonce="",stream:UUID?,screenDeadline=Date.distantFuture
    var lastSequence:Int64=0,frameSequence:Int64=0,frameTotal=0,framePTS:Int64=0,frameWidth=0,frameHeight=0
    var frameKey=false,frameConfig=false,frame=Data(),frameDeadline=Date.distantFuture,decoding=false
    var screenHeartbeat=false,heartbeatSequence:Int64=0
    let decoder=ScreenDecoder()
    var albumPageActive=false
    var albumRequest="",pageRequests:[String:Int]=[:],previewRequests:[String:(String,Date)]=[:],assets:[String:MediaAssetView]=[:]
    var positions:[Int:String]=[:]
    var previewAsset = "", previewContext = ""
    var originalCompletion: ((URL?) -> Void)?
    var cachedOriginals: [String:FileTaskView] = [:]
    var previewRevision = UUID()
    var publicDownloads = Set<String>()
    var albumQueueBlocked = false, filesQueueBlocked = false
    var completingOriginal = false, completingFile = false
    var exports: [String:WorkCancellation] = [:]
    var previewAttempted=Set<String>(),downloads:[String]=[],downloadRequest="",downloadTask="",downloadDeadline=Date.distantFuture
    var filesRequest = "", filesPageRequest = "", filesExpectedFolder = "", filesRootFolder = ""
    var filesExpectedOffset = 0
    var filesRetiredRequests = Set<String>()
    var filesDownloads: [DirectoryEntryView] = []
    var filesDownloadRequest = "", filesDownloadTask = ""
    var filesDownloadDeadline = Date.distantFuture, filesPageDeadline = Date.distantFuture
    init(peer:String,control:UUID,generation:String){self.peer=peer;self.control=control;self.generation=generation;view=DeviceMediaView(peerId:peer)}
}
/// 设备协作控制只在服务器队列运行，媒体流与持久剪贴板互不借用授权。
final class DeviceMediaCoordinator {
    private let queue:DispatchQueue,engine:FileTransferEngine,serverID:String,hub:ScreenImageHub
    private let send:(UUID,[String:Any])->Void,close:(UUID)->Void,changed:()->Void
    private var peers:[String:MediaPeerSession]=[:]
    private var lockObserver:NSObjectProtocol?,sleepObserver:NSObjectProtocol?,unlockObserver:NSObjectProtocol?,wakeObserver:NSObjectProtocol?
    private var locked=false
    private var screenActivity:NSObjectProtocol?
    init(queue:DispatchQueue,engine:FileTransferEngine,serverID:String,hub:ScreenImageHub,send:@escaping(UUID,[String:Any])->Void,close:@escaping(UUID)->Void,changed:@escaping()->Void){
        self.queue=queue;self.engine=engine;self.serverID=serverID;self.hub=hub;self.send=send;self.close=close;self.changed=changed
        locked=(CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        unlockObserver=DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("com.apple.screenIsUnlocked"),object:nil,queue:nil){[weak self]_ in self?.queue.async{self?.unlocked()}}
        lockObserver=DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("com.apple.screenIsLocked"),object:nil,queue:nil){[weak self]_ in self?.queue.async{self?.pauseForLock()}}
        wakeObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:nil){[weak self]_ in self?.queue.async{guard let self else{return};self.locked=(CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool ?? true;self.changed()}}
        sleepObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:nil){[weak self]_ in self?.queue.async{self?.pauseForLock()}}
    }
    deinit {if let screenActivity{ProcessInfo.processInfo.endActivity(screenActivity)};if let wakeObserver{NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)};if let unlockObserver{DistributedNotificationCenter.default().removeObserver(unlockObserver)};if let lockObserver{DistributedNotificationCenter.default().removeObserver(lockObserver)};if let sleepObserver{NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)}}
    var views:[DeviceMediaView]{peers.values.map(\.view)}
    func authenticated(peer:String,control:UUID,generation:String){if let old=peers[peer]{end(old,reason:"连接会话已变化")};peers[peer]=MediaPeerSession(peer:peer,control:control,generation:generation)}
    func disconnected(_ control:UUID){for p in peers.values where p.control==control{end(p,reason:"设备连接已断开");peers.removeValue(forKey:p.peer)};changed()}
    func stop(){for p in peers.values{end(p,reason:"连接服务已停止")};peers.removeAll()}
    func streamClosed(_ id:UUID){for p in peers.values where p.stream==id{p.stream=nil;if ["active","streaming","starting"].contains(p.view.screenState){screenEnd(p,state:"error",message:"投屏连接已中断，请重新开始",notify:true)}}}
    func isStream(_ id:UUID)->Bool{peers.values.contains{$0.stream==id}}
    private func current(_ peer:String,_ generation:String)->MediaPeerSession?{guard !locked,let p=peers[peer],p.generation==generation,p.view.capable else{return nil};return p}
    private func id()->String{(try? hex(secureBytes(16))) ?? UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()}
    private func emit(_ p:MediaPeerSession,_ type:String,_ fields:[String:Any]=[:]){send(p.control,wire(type,fields))}
    private func updateScreenActivity(){
        let active=peers.values.contains{["awaiting","starting","active","streaming"].contains($0.view.screenState)}
        if active && screenActivity==nil{screenActivity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"处理用户授权的手机投屏")}
        if !active,let activity=screenActivity{screenActivity=nil;ProcessInfo.processInfo.endActivity(activity)}
    }
    func startScreen(peer:String,generation:String){
        guard let p=current(peer,generation),p.view.screenCapable else{return}
        screenEnd(p,state:"stopped",message:"",notify:true)
        p.screenRequest=id();p.view.screenId=id();p.nonce=(try? hex(secureBytes(32))) ?? ""
        guard validHex(p.nonce,count:64) else{screenEnd(p,state:"error",message:"无法创建投屏会话",notify:false);return}
        p.view.screenState="awaiting";p.view.screenMessage="请打开手机续桥，允许这台 Mac 投屏";p.view.decodedFrames=0;p.heartbeatSequence=0;updateScreenActivity();p.screenDeadline=Date().addingTimeInterval(60)
        emit(p,"device.screen.request",["requestId":p.screenRequest,"screenId":p.view.screenId,"bindNonce":p.nonce,"width":720,"height":1280,"fps":15,"bitrate":2000000]);changed()
    }
    func stopScreen(peer:String,generation:String){guard let p=peers[peer],p.generation==generation else{return};screenEnd(p,state:"stopped",message:"投屏已停止",notify:true)}
    private func screenEnd(_ p:MediaPeerSession,state:String,message:String,notify:Bool){
        if notify && !p.view.screenId.isEmpty{emit(p,"device.screen.stop",["screenId":p.view.screenId,"reason":"user"])}
        let stream=p.stream;p.stream=nil;p.nonce="";p.screenRequest="";p.screenDeadline = .distantFuture;p.frame.removeAll();p.frameDeadline = .distantFuture;p.decoding=false;p.lastSequence=0;p.frameSequence=0
        p.decoder.reset();p.view.screenState=state;p.view.screenMessage=message;updateScreenActivity();hub.publish(peerId:p.peer,generation:p.generation,image:nil);if let stream{close(stream)};changed()
    }
    func bind(channel:UUID,message:[String:Any])->Bool{
        guard !locked,message["serverId"] as? String==serverID,let peer=validIdentifier(message["clientId"]),let p=peers[peer],p.view.screenCapable,
              message["screenId"] as? String==p.view.screenId,let nonce=message["bindNonce"] as? String,validHex(nonce,count:64),!p.nonce.isEmpty,constantEqual(p.nonce,nonce),p.stream==nil,Date()<p.screenDeadline else{return false}
        p.nonce="";p.stream=channel;send(channel,wire("device.screen.bound",["screenId":p.view.screenId]));return true
    }
    func frame(channel:UUID,message:[String:Any]){
        guard let p=peers.values.first(where:{$0.stream==channel}),!locked else{close(channel);return}
        func invalid(){screenEnd(p,state:"error",message:"投屏数据无效，请重新开始",notify:true)}
        if message["type"] as? String=="device.screen.ping" {
            guard p.screenHeartbeat,message["screenId"] as? String==p.view.screenId,["active","streaming"].contains(p.view.screenState),let seq=fileInteger(message["seq"],maximum:9_007_199_254_740_991),seq>p.heartbeatSequence else{invalid();return}
            p.heartbeatSequence=seq
            // 静止画面可以没有新帧；心跳只证明已授权流存活，不能替代首帧或完整帧。
            if p.view.decodedFrames>0{p.screenDeadline=Date().addingTimeInterval(15)}
            send(channel,wire("device.screen.pong",["screenId":p.view.screenId,"seq":seq]));return
        }
        guard message["type"] as? String=="device.screen.frame",message["screenId"] as? String==p.view.screenId,!p.decoding,
              let seq=fileInteger(message["seq"],maximum:9_007_199_254_740_991),seq>0,
              let offset=fileInteger(message["offset"],maximum:524288),let total=fileInteger(message["total"],maximum:524288),total>0,
              let pts=fileInteger(message["ptsUs"],maximum:9_007_199_254_740_991),let width=fileInteger(message["width"],maximum:1920),let height=fileInteger(message["height"],maximum:1920),width>0,height>0,width%2==0,height%2==0,width*height<=2073600,
              let key=clipboardBool(message["keyFrame"]),let config=clipboardBool(message["codecConfig"]),let encoded=message["data"] as? String,encoded.utf8.count<=21848,let data=Data(base64Encoded:encoded),!data.isEmpty,data.count<=16384,data.base64EncodedString()==encoded else{invalid();return}
        if p.frame.isEmpty {
            guard offset==0,seq==p.lastSequence+1 else{invalid();return}
            p.frameSequence=seq;p.frameTotal=Int(total);p.framePTS=pts;p.frameWidth=Int(width);p.frameHeight=Int(height);p.frameKey=key;p.frameConfig=config;p.frameDeadline=Date().addingTimeInterval(3)
        }
        guard seq==p.frameSequence,offset==p.frame.count,total==p.frameTotal,pts==p.framePTS,Int(width)==p.frameWidth,Int(height)==p.frameHeight,key==p.frameKey,config==p.frameConfig,p.frame.count+data.count<=p.frameTotal else{invalid();return}
        p.frame.append(data)
        guard p.frame.count==p.frameTotal else{return}
        p.decoding=true;let frame=p.frame,screen=p.view.screenId;p.frame.removeAll();p.frameDeadline = .distantFuture
        p.decoder.decode(frame,ptsUs:pts){[weak self,weak p] image,valid in self?.queue.async{
            guard let self,let p,self.peers[p.peer]===p,p.stream==channel,p.view.screenId==screen,!self.locked else{return}
            p.decoding=false
            guard valid else{self.screenEnd(p,state:"error",message:"无法解码投屏画面，请重新开始",notify:true);return}
            p.lastSequence=seq
            self.send(channel,wire("device.screen.ack",["screenId":screen,"seq":seq]))
            if let image {
                p.view.decodedFrames += 1;p.screenDeadline=Date().addingTimeInterval(p.screenHeartbeat ? 15:10)
                let first=p.view.screenState != "streaming";p.view.screenState="streaming";p.view.screenMessage="投屏中";self.hub.publish(peerId:p.peer,generation:p.generation,image:image);if first{self.changed()}
            }
        }}
    }
    func requestAlbum(peer:String,generation:String,kind:String="image") {
        guard let p=current(peer,generation),p.view.albumCapable,["image","video"].contains(kind) else{return}
        guard albumNavigationAllowed(p) else{return}
        revokeAlbum(p,notify:true,state:"awaiting",message:"正在检查手机图库权限")
        p.albumPageActive=true;p.view.albumKind=kind;p.albumRequest=id()
        emit(p,"device.album.request",["requestId":p.albumRequest,"kind":kind]);changed()
    }
    /// 原件队列包含用户已确认的保存意图，浏览操作不得静默撤销它们。
    private func albumNavigationAllowed(_ p:MediaPeerSession)->Bool {
        guard p.downloadRequest.isEmpty,p.downloads.isEmpty,!p.completingOriginal else {
            p.view.albumMessage="请等待原件下载及保存队列完成后再翻页、刷新或查找";changed();return false
        }
        return true
    }
    func listAlbum(peer:String,generation:String,offset:Int,query:String?=nil,sort:String?=nil) {
        guard let p=current(peer,generation),!p.view.grantId.isEmpty,albumNavigationAllowed(p) else{return}
        let q=(query ?? p.view.albumQuery).trimmingCharacters(in:.whitespacesAndNewlines),order=sort ?? p.view.albumSort
        guard q.utf8.count<=128,["newest","oldest","name"].contains(order) else{p.view.albumMessage="查找条件无效（名称最多128字节）";changed();return}
        guard p.view.browserQueryCapable || (q.isEmpty && order=="newest") else{p.view.albumMessage="手机尚不支持图库查找与排序";changed();return}
        let changedQuery=q != p.view.albumQuery || order != p.view.albumSort
        let page=changedQuery ? 0:offset
        guard (0..<max(1,p.view.albumTotal)).contains(page),page%30==0 else{return}
        p.view.albumQuery=q;p.view.albumSort=order
        p.albumPageActive=true;p.previewRequests.removeAll();p.previewAttempted.removeAll();p.positions.removeAll()
        let request=id();p.pageRequests=[request:page];p.view.albumMessage="正在读取图库…"
        var fields:[String:Any]=["requestId":request,"grantId":p.view.grantId,"offset":page,"limit":30]
        if p.view.browserQueryCapable {fields["query"]=q;fields["sort"]=order}
        emit(p,"device.album.list",fields);changed()
    }
    func leaveAlbum(peer:String,generation:String){revokeAlbum(peer:peer,generation:generation)}
    func revokeAlbum(peer:String,generation:String){guard let p=peers[peer],p.generation==generation else{return};p.albumPageActive=false;revokeAlbum(p,notify:true,state:"revoked",message:"浏览已结束，重新打开可恢复图库访问");changed()}
    private func revokeAlbum(_ p:MediaPeerSession,notify:Bool,state:String,message:String,preserveRequest:Bool=false){
        let anchor=preserveRequest ? p.albumRequest:""
        if notify && !p.albumRequest.isEmpty{emit(p,"device.album.revoke",["requestId":p.albumRequest,"grantId":p.view.grantId,"reason":"user"])}
        // 只撤销相册自己的显式意图；目录共享使用独立的请求与队列。
        if !p.downloadRequest.isEmpty { engine.cancelMediaRequest(p.downloadRequest) }
        p.previewRevision=UUID();p.originalCompletion?(nil);p.originalCompletion=nil;p.previewAsset="";p.previewContext="";p.cachedOriginals.removeAll();p.publicDownloads.removeAll();p.completingOriginal=false
        for key in Array(p.exports.keys) where key.hasPrefix(p.view.grantId+":") {p.exports.removeValue(forKey:key)?.cancel()}
        p.albumQueueBlocked=false;p.albumRequest=anchor;p.pageRequests.removeAll();p.previewRequests.removeAll();p.previewAttempted.removeAll();p.assets.removeAll();p.positions.removeAll();p.downloads.removeAll();p.downloadRequest="";p.downloadTask="";p.downloadDeadline = .distantFuture
        p.view.grantId="";p.view.assets=[];p.view.albumTotal=0;p.view.albumOffset=0;p.view.albumState=state;p.view.albumMessage=message;p.view.downloading="";p.view.queuedDownloads=0
    }
    func download(peer:String,generation:String,assets:[String]){
        guard let p=current(peer,generation),!p.view.grantId.isEmpty,assets.count<=100 else{return}
        p.albumQueueBlocked=false
        for asset in assets where (p.assets[asset]?.size ?? (FILE_MAX_SIZE+1))<=FILE_MAX_SIZE {
            if p.publicDownloads.count<100 {p.publicDownloads.insert(asset)}
            if !p.downloads.contains(asset) && p.view.downloading != asset && p.downloads.count<100 {p.downloads.append(asset)}
        }
        pumpDownload(p);changed()
    }
    private func pumpDownload(_ p:MediaPeerSession){
        guard !p.albumQueueBlocked,p.downloadRequest.isEmpty,!p.downloads.isEmpty,!p.view.grantId.isEmpty else{p.view.queuedDownloads=p.downloads.count;return}
        let assetID=p.downloads.removeFirst();guard let asset=p.assets[assetID] else{pumpDownload(p);return}
        if let cached=p.cachedOriginals[assetID],cached.peerId==p.peer,cached.direction == .incoming,let mediaRequest=cached.mediaRequestId {
            let grant=p.view.grantId,validation=id()
            p.downloadRequest=validation;p.view.downloading=assetID;p.view.queuedDownloads=p.downloads.count;p.completingOriginal=true
            // 历史清理可删除私有原件但保留任务元数据；每次复用前按原任务/attempt核验收据。
            engine.location(id:cached.id,expectedAttempt:cached.attemptId){[weak self,weak p] url in self?.queue.async{
                guard let self,let p,self.current(p.peer,p.generation)===p,p.view.albumState=="shared",p.view.grantId==grant,p.downloadRequest==validation,p.view.downloading==assetID else{return}
                guard url != nil else{
                    // 只剔除失效缓存，保留本次明确保存意图；下一次pump直接走认证网络请求。
                    p.cachedOriginals.removeValue(forKey:assetID);p.downloadRequest="";p.view.downloading="";p.completingOriginal=false
                    p.downloads.insert(assetID,at:0);self.pumpDownload(p);self.changed();return
                }
                if p.previewAsset==assetID {self.deliverOriginal(p,asset:assetID,task:cached)}
                let finish:()->Void = {[weak self,weak p] in
                    guard let self,let p,self.peers[p.peer]===p,p.downloadRequest==validation,p.view.grantId==grant else{return}
                    p.publicDownloads.remove(assetID);p.downloadRequest="";p.view.downloading="";p.completingOriginal=false;p.downloadDeadline = .distantFuture;self.pruneAlbum(p);self.pumpDownload(p);self.changed()
                }
                if p.publicDownloads.contains(assetID) {self.exportMedia(p,task:cached,grant:grant,asset:assetID,request:mediaRequest,completion:finish)} else{finish()}
            }}
            return
        }
        let request=id(),grant=p.view.grantId
        p.downloadRequest=request;p.view.downloading=assetID;p.view.queuedDownloads=p.downloads.count;p.downloadDeadline=Date().addingTimeInterval(120)
        let binding=MediaBinding(peerId:p.peer,trustGeneration:p.generation,controlId:p.control.uuidString,grantId:grant,assetId:assetID,requestId:request)
        engine.registerMediaRequest(binding,control:p.control,name:asset.name,size:asset.size){[weak self,weak p] ok in self?.queue.async{
            guard let self,let p,self.peers[p.peer]===p,p.downloadRequest==request,p.view.grantId==grant else{return}
            if ok{self.emit(p,"device.album.download",["requestId":request,"grantId":grant,"assetId":assetID])}
            else{if p.previewAsset==assetID {p.originalCompletion?(nil);p.originalCompletion=nil};p.downloadRequest="";p.view.downloading="";p.view.albumMessage="文件任务正忙，请稍后再下载";p.albumQueueBlocked=true;p.downloads.insert(assetID,at:0);p.view.queuedDownloads=p.downloads.count;p.view.albumMessage="文件任务正忙，已保留\(p.downloads.count)项下载；请再次点击下载重试";self.pruneAlbum(p);self.changed()}
        }}
    }
    /// 原件定位复用已校验的传输收据；仅保留当前页/活动意图的任务ID。
    func previewAlbum(peer:String,generation:String,grantID:String,assetID:String,context:String,completion:@escaping(URL?)->Void) {
        guard let p=current(peer,generation),let asset=p.assets[assetID],p.view.albumState=="shared",p.view.grantId==grantID,UUID(uuidString:context) != nil,asset.mimeType.hasPrefix("image/"),asset.size<=32*1024*1024,asset.width>0,asset.height>0,Int64(asset.width)*Int64(asset.height)<=32_000_000 else{completion(nil);return}
        p.previewRevision=UUID();p.originalCompletion?(nil);p.previewAsset=assetID;p.previewContext=context;p.originalCompletion=completion
        if let task=p.cachedOriginals[assetID] {deliverOriginal(p,asset:assetID,task:task);return}
        if p.view.downloading != assetID && !p.downloads.contains(assetID),p.downloads.count<100 {p.downloads.insert(assetID,at:0)}
        pumpDownload(p);changed()
    }
    func closeAlbumPreview(peer:String,generation:String,grantID:String,assetID:String,context:String) {
        guard let p=peers[peer],p.generation==generation,p.view.grantId==grantID,p.previewAsset==assetID,p.previewContext==context else{return}
        let asset=p.previewAsset;p.previewRevision=UUID();p.previewAsset="";p.previewContext="";p.originalCompletion?(nil);p.originalCompletion=nil
        if !p.publicDownloads.contains(asset) {
            p.downloads.removeAll{$0==asset}
            if p.view.downloading==asset {engine.cancelMediaRequest(p.downloadRequest);p.downloadRequest="";p.downloadTask="";p.view.downloading="";p.downloadDeadline = .distantFuture;p.completingOriginal=false;pumpDownload(p)}
        };pruneAlbum(p);changed()
    }
    private func deliverOriginal(_ p:MediaPeerSession,asset:String,task:FileTaskView) {
        let grant=p.view.grantId,revision=p.previewRevision
        engine.location(id:task.id,expectedAttempt:task.attemptId){[weak self,weak p] url in self?.queue.async{
            guard let self,let p,self.peers[p.peer]===p,!self.locked,p.view.grantId==grant,p.previewAsset==asset,p.previewRevision==revision else{return}
            if url==nil {p.cachedOriginals.removeValue(forKey:asset)}
            let callback=p.originalCompletion;p.originalCompletion=nil;callback?(url)
        }}
    }
    private func pruneAlbum(_ p:MediaPeerSession) {
        var keep=Set(p.view.assets.map(\.id));keep.formUnion(p.downloads)
        if !p.view.downloading.isEmpty {keep.insert(p.view.downloading)}
        if !p.previewAsset.isEmpty {keep.insert(p.previewAsset)}
        p.assets=p.assets.filter{keep.contains($0.key)};p.cachedOriginals=p.cachedOriginals.filter{keep.contains($0.key)}
        p.positions=p.positions.filter{keep.contains($0.value)}
        p.previewAttempted=p.previewAttempted.intersection(Set(p.view.assets.map(\.id)))
    }
    private func exportMedia(_ p:MediaPeerSession,task:FileTaskView,grant:String,asset:String,request:String,completion:@escaping()->Void) {
        guard let downloads=FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first else{completion();return}
        let token=WorkCancellation();p.exports[grant+":"+task.id]=token
        let binding=MediaBinding(peerId:p.peer,trustGeneration:p.generation,controlId:p.control.uuidString,grantId:grant,assetId:asset,requestId:request)
        engine.exportMany([FileTaskSelection(id:task.id,attemptId:task.attemptId)],parent:downloads,cancellation:token,mediaAuthorization:binding){[weak self,weak p] in self?.queue.async{
            guard let self,let p,self.peers[p.peer]===p else{return}
            p.exports.removeValue(forKey:grant+":"+task.id);completion()
        }}
    }
    func tasksChanged(_ tasks:[FileTaskView]) {
        filesTasksChanged(tasks)
        for p in peers.values where !p.downloadRequest.isEmpty && !p.completingOriginal {
            guard let task=tasks.first(where:{$0.mediaRequestId==p.downloadRequest && $0.peerId==p.peer}) else{continue}
            p.downloadTask=task.id;p.downloadDeadline=Date().addingTimeInterval(120)
            guard task.state.terminal else{continue}
            let asset=p.view.downloading,request=p.downloadRequest,grant=p.view.grantId
            p.completingOriginal=true
            if task.state == .completed {
                p.cachedOriginals[asset]=task
                if p.previewAsset==asset {deliverOriginal(p,asset:asset,task:task)}
            } else if p.previewAsset==asset {p.originalCompletion?(nil);p.originalCompletion=nil}
            let finish:()->Void = {[weak self,weak p] in
                guard let self,let p,self.peers[p.peer]===p,p.view.grantId==grant,p.downloadRequest==request else{return}
                p.view.albumMessage=task.state == .completed ? "原件已接收；明确下载的保存结果见文件传输":"原件传输未完成，请重试"
                p.publicDownloads.remove(asset);p.downloadRequest="";p.downloadTask="";p.view.downloading="";p.downloadDeadline = .distantFuture;p.completingOriginal=false;self.pruneAlbum(p);self.pumpDownload(p);self.changed()
            }
            if task.state == .completed && p.publicDownloads.contains(asset) {exportMedia(p,task:task,grant:grant,asset:asset,request:request,completion:finish)} else{finish()}
        }
    }
    private func failOriginal(_ p:MediaPeerSession,message:String) {
        let asset=p.view.downloading
        engine.cancelMediaRequest(p.downloadRequest)
        if p.previewAsset==asset {p.originalCompletion?(nil);p.originalCompletion=nil}
        p.publicDownloads.remove(asset);p.downloadRequest="";p.downloadTask="";p.view.downloading="";p.completingOriginal=false;p.downloadDeadline = .distantFuture;p.view.albumMessage=message;pruneAlbum(p);pumpDownload(p)
    }
    private func previewMore(_ p:MediaPeerSession){
        guard p.albumPageActive,p.view.albumState=="shared" else{return}
        for asset in p.view.assets where p.previewRequests.count<3 && !p.previewAttempted.contains(asset.id) && asset.mimeType.hasPrefix("image/"){let request=id();p.previewAttempted.insert(asset.id);p.previewRequests[request]=(asset.id,Date());emit(p,"device.album.preview",["requestId":request,"grantId":p.view.grantId,"assetId":asset.id])}
    }
    func requestFiles(peer:String,generation:String) {
        guard let p=current(peer,generation),p.view.filesCapable else{return}
        revokeFiles(p,notify:true,state:"awaiting",message:"正在恢复已保存的访问范围")
        p.filesRequest=id();emit(p,"device.files.request",["requestId":p.filesRequest]);changed()
    }
    func authorizeFiles(peer:String,generation:String){requestFilesAction(peer:peer,generation:generation,type:"device.files.authorize",message:"请在手机添加访问范围")}
    func forgetFiles(peer:String,generation:String){requestFilesAction(peer:peer,generation:generation,type:"device.files.forget",message:"正在清除已保存授权")}
    private func requestFilesAction(peer:String,generation:String,type:String,message:String) {
        guard let p=current(peer,generation),p.view.filesCapable else{return}
        revokeFiles(p,notify:true,state:"awaiting",message:message);p.filesRequest=id();emit(p,type,["requestId":p.filesRequest]);changed()
    }
    func listFiles(peer:String,generation:String,folderID:String,offset:Int,query:String?=nil,sort:String?=nil) {
        guard let p=current(peer,generation),p.view.filesCapable,!p.view.filesGrantId.isEmpty,validHex(folderID,count:32) else{return}
        // 导航只使用已授权目录ID；查询仅当前层，由手机在元数据边界内执行。
        guard folderID==p.filesRootFolder || folderID==p.view.filesFolderId || p.view.filesBreadcrumbs.contains(where:{$0.id==folderID}) || p.view.filesEntries.contains(where:{$0.id==folderID && $0.isDirectory}) else{return}
        let changingFolder=p.view.filesFolderId != folderID
        let q=(changingFolder ? "":query ?? p.view.filesQuery).trimmingCharacters(in:.whitespacesAndNewlines),order=sort ?? p.view.filesSort
        guard q.utf8.count<=128,["name","modified","size"].contains(order) else{p.view.filesMessage="查找条件无效（名称最多128字节）";changed();return}
        guard p.view.browserQueryCapable || (q.isEmpty && order=="name") else{p.view.filesMessage="手机尚不支持目录查找与排序";changed();return}
        let changedQuery=q != p.view.filesQuery || order != p.view.filesSort
        let page=changingFolder || changedQuery ? 0:offset
        guard page>=0,page<1024,page%30==0 else{return}
        if !changingFolder {guard page<max(1,p.view.filesTotal) else{return}} else if page != 0{return}
        p.view.filesQuery=q;p.view.filesSort=order
        let request=id();p.filesPageRequest=request;p.filesExpectedFolder=folderID;p.filesExpectedOffset=page;p.filesPageDeadline=Date().addingTimeInterval(30)
        if changingFolder {p.view.filesTotal=0;p.view.filesSkippedCount=0}
        p.view.filesState="loading";p.view.filesMessage="正在读取共享文件…";p.view.filesFolderId=folderID;p.view.filesOffset=page;p.view.filesEntries=[]
        var fields:[String:Any]=["requestId":request,"grantId":p.view.filesGrantId,"folderId":folderID,"offset":page,"limit":30]
        if p.view.browserQueryCapable {fields["query"]=q;fields["sort"]=order}
        emit(p,"device.files.list",fields);changed()
    }
    func downloadFiles(peer:String,generation:String,entryIDs:[String]) {
        guard let p=current(peer,generation),p.view.filesCapable,!p.view.filesGrantId.isEmpty,entryIDs.count<=100 else{return}
        p.filesQueueBlocked=false
        for entryID in entryIDs {
            guard let entry=p.view.filesEntries.first(where:{$0.id==entryID}),!entry.isDirectory,entry.downloadable,entry.size<=FILE_MAX_SIZE else{continue}
            if p.filesDownloads.count+(p.filesDownloadRequest.isEmpty ? 0:1)<100,p.view.filesDownloading != entryID,!p.filesDownloads.contains(where:{$0.id==entryID}) {p.filesDownloads.append(entry)}
        }
        pumpFilesDownload(p);changed()
    }
    func revokeFiles(peer:String,generation:String) {
        guard let p=peers[peer],p.generation==generation else{return}
        revokeFiles(p,notify:true,state:"revoked",message:"文件共享已结束，请重新授权");changed()
    }
    func leaveFiles(peer:String,generation:String) {revokeFiles(peer:peer,generation:generation)}
    private func revokeFiles(_ p:MediaPeerSession,notify:Bool,state:String,message:String,preserveRequest:Bool=false) {
        let request=preserveRequest ? p.filesRequest:""
        if !preserveRequest,!p.filesRequest.isEmpty {
            // 迟到Picker结果也必须释放手机侧根引用；仅保留有界的请求ID墓碑。
            if p.filesRetiredRequests.count>=16 {p.filesRetiredRequests.removeAll()}
            p.filesRetiredRequests.insert(p.filesRequest)
        }
        if notify,!p.filesRequest.isEmpty,(!p.view.filesGrantId.isEmpty || (!preserveRequest && ["awaiting","selecting"].contains(p.view.filesState))) {
            // 授权尚未发布时也按原始request取消Picker，不能依赖未来grant才释放共享。
            emit(p,"device.files.revoke",["requestId":p.filesRequest,"grantId":p.view.filesGrantId,"reason":"user"])
        }
        if !p.filesDownloadRequest.isEmpty {engine.cancelMediaRequest(p.filesDownloadRequest)}
        for key in Array(p.exports.keys) where key.hasPrefix(p.view.filesGrantId+":") {p.exports.removeValue(forKey:key)?.cancel()}
        p.completingFile=false;p.filesQueueBlocked=false
        p.filesRequest=request;p.filesPageRequest="";p.filesPageDeadline = .distantFuture;p.filesExpectedFolder="";p.filesRootFolder="";p.filesExpectedOffset=0
        p.filesDownloads=[];p.filesDownloadRequest="";p.filesDownloadTask="";p.filesDownloadDeadline = .distantFuture
        p.view.filesGrantId="";p.view.filesState=state;p.view.filesMessage=message;p.view.filesRootName="";p.view.filesFolderId="";p.view.filesOffset=0;p.view.filesTotal=0;p.view.filesSkippedCount=0;p.view.filesEntries=[];p.view.filesBreadcrumbs=[];p.view.filesDownloading="";p.view.filesQueuedDownloads=0
    }
    private func pumpFilesDownload(_ p:MediaPeerSession) {
        guard !p.filesQueueBlocked,p.filesDownloadRequest.isEmpty,!p.filesDownloads.isEmpty,!p.view.filesGrantId.isEmpty else{p.view.filesQueuedDownloads=p.filesDownloads.count;return}
        let entry=p.filesDownloads.removeFirst(),request=id(),grant=p.view.filesGrantId
        p.filesDownloadRequest=request;p.view.filesDownloading=entry.id;p.view.filesQueuedDownloads=p.filesDownloads.count;p.filesDownloadDeadline=Date().addingTimeInterval(120)
        let binding=MediaBinding(peerId:p.peer,trustGeneration:p.generation,controlId:p.control.uuidString,grantId:grant,assetId:entry.id,requestId:request)
        engine.registerMediaRequest(binding,control:p.control,name:entry.name,size:entry.size){[weak self,weak p] ok in self?.queue.async{
            guard let self,let p,self.peers[p.peer]===p,p.filesDownloadRequest==request,p.view.filesGrantId==grant else{return}
            if ok {self.emit(p,"device.files.download",["requestId":request,"grantId":grant,"assetId":entry.id])}
            else {p.filesDownloadRequest="";p.filesDownloadDeadline = .distantFuture;p.view.filesDownloading="";p.view.filesMessage="文件任务正忙，请稍后再下载";p.filesQueueBlocked=true;p.filesDownloads.insert(entry,at:0);p.view.filesQueuedDownloads=p.filesDownloads.count;p.view.filesMessage="文件任务正忙，已保留\(p.filesDownloads.count)项下载；请再次点击下载重试";self.changed()}
        }}
    }
    private func filesTasksChanged(_ tasks:[FileTaskView]) {
        for p in peers.values where !p.filesDownloadRequest.isEmpty && !p.completingFile {
            guard let task=tasks.first(where:{$0.mediaRequestId==p.filesDownloadRequest && $0.peerId==p.peer}) else{continue}
            p.filesDownloadTask=task.id;p.filesDownloadDeadline=Date().addingTimeInterval(120)
            if task.state.terminal {
                let request=p.filesDownloadRequest,grant=p.view.filesGrantId,asset=p.view.filesDownloading
                p.completingFile=true
                let finish:()->Void = {[weak self,weak p] in
                    guard let self,let p,self.peers[p.peer]===p,p.view.filesGrantId==grant,p.filesDownloadRequest==request else{return}
                    p.view.filesMessage=task.state == .completed ? "文件已接收，保存结果见文件传输":"文件下载未完成，请重试"
                    p.filesDownloadRequest="";p.filesDownloadTask="";p.view.filesDownloading="";p.filesDownloadDeadline = .distantFuture;p.completingFile=false;self.pumpFilesDownload(p);self.changed()
                }
                if task.state == .completed {exportMedia(p,task:task,grant:grant,asset:asset,request:request,completion:finish)} else{finish()}
            }
        }
    }
    private func filesError(_ p:MediaPeerSession,request:String) {
        guard !request.isEmpty else{return}
        if request==p.filesDownloadRequest {engine.cancelMediaRequest(request);p.filesDownloadRequest="";p.filesDownloadTask="";p.filesDownloadDeadline = .distantFuture;p.view.filesDownloading="";p.view.filesMessage="文件暂不可下载，请重新选择共享内容";pumpFilesDownload(p)}
        if request==p.filesPageRequest {p.filesPageRequest="";p.filesPageDeadline = .distantFuture;p.view.filesState="error";p.view.filesEntries=[];p.view.filesMessage="共享文件读取失败，请刷新或重新授权"}
        if request==p.filesRequest {revokeFiles(p,notify:true,state:"error",message:"共享请求未完成，请重试")}
    }
    private func filesControl(_ p:MediaPeerSession,message:[String:Any],type:String) {
        switch type {
        case "device.files.state":
            guard let request=message["requestId"] as? String,validHex(request,count:32),let state=message["state"] as? String,["awaiting","selecting","shared","denied","revoked","paused","error"].contains(state),let text=message["message"] as? String,text.utf8.count<=512 else{return}
            if request != p.filesRequest {
                if p.filesRetiredRequests.contains(request),state=="shared",let grant=message["grantId"] as? String,validHex(grant,count:32),grant != p.view.filesGrantId {emit(p,"device.files.revoke",["requestId":request,"grantId":grant,"reason":"stale"])}
                return
            }
            if state=="shared" {
                guard let grant=message["grantId"] as? String,validHex(grant,count:32),let folder=message["folderId"] as? String,validHex(folder,count:32),let root=fileName(message["rootName"]) else{return}
                if grant==p.view.filesGrantId {return}
                revokeFiles(p,notify:true,state:"shared",message:"仅显示手机授权的文件",preserveRequest:true)
                p.view.filesGrantId=grant;p.filesRootFolder=folder;p.view.filesRootName=root;p.view.filesMessage=text
                listFiles(peer:p.peer,generation:p.generation,folderID:folder,offset:0)
            } else {
                let descriptions=["awaiting":"请在手机确认文件共享","selecting":"正在手机选择共享内容","denied":"手机未选择共享内容，可重新申请","revoked":"手机已结束文件共享","paused":"文件共享已暂停，请重新授权","error":"共享文件读取失败，请重新授权"]
                revokeFiles(p,notify:false,state:state,message:mediaText(message,fallback:descriptions[state] ?? "文件浏览已结束"),preserveRequest:["awaiting","selecting"].contains(state))
            };changed()
        case "device.files.page":
            guard !p.filesPageRequest.isEmpty,message["requestId"] as? String==p.filesPageRequest,!p.view.filesGrantId.isEmpty,message["grantId"] as? String==p.view.filesGrantId,message["folderId"] as? String==p.filesExpectedFolder,
                  let offset=fileInteger(message["offset"],maximum:1023),offset==Int64(p.filesExpectedOffset),let total=fileInteger(message["total"],maximum:1024),offset<max(1,total),
                  let skipped=fileInteger(message["skippedCount"],maximum:9_007_199_254_740_991),let items=message["entries"] as? [[String:Any]],items.count==min(30,Int(total-offset)),
                  let crumbs=message["breadcrumbs"] as? [[String:Any]],(1...18).contains(crumbs.count) else{return}
            guard !p.view.browserQueryCapable || (message["query"] as? String==p.view.filesQuery && message["sort"] as? String==p.view.filesSort) else{return}
            var breadcrumbs=[DirectoryCrumbView](),crumbIDs=Set<String>()
            for crumb in crumbs {
                guard let folder=crumb["folderId"] as? String,validHex(folder,count:32),crumbIDs.insert(folder).inserted,let name=fileName(crumb["name"]) else{return}
                breadcrumbs.append(DirectoryCrumbView(id:folder,name:name))
            }
            guard breadcrumbs.first?.id==p.filesRootFolder,breadcrumbs.first?.name==p.view.filesRootName,breadcrumbs.last?.id==p.filesExpectedFolder else{return}
            var entries=[DirectoryEntryView](),entryIDs=Set<String>()
            for item in items {
                guard let entry=item["entryId"] as? String,validHex(entry,count:32),entryIDs.insert(entry).inserted,!crumbIDs.contains(entry),let name=fileName(item["name"]),let directory=clipboardBool(item["isDirectory"]),let size=fileInteger(item["size"],maximum:9_007_199_254_740_991),let modified=fileInteger(item["modifiedAt"],maximum:9_007_199_254_740_991),let downloadable=clipboardBool(item["downloadable"]),(!directory || (size==0 && !downloadable)),(!downloadable || size<=FILE_MAX_SIZE) else{return}
                entries.append(DirectoryEntryView(id:entry,name:name,isDirectory:directory,size:size,modifiedAt:modified,downloadable:downloadable))
            }
            let sorted=entries.sorted { a,b in
                if a.isDirectory != b.isDirectory {return a.isDirectory}
                if p.view.filesSort=="modified",a.modifiedAt != b.modifiedAt {return a.modifiedAt>b.modifiedAt}
                if p.view.filesSort=="size",a.size != b.size {return a.size>b.size}
                if a.name != b.name {return a.name.utf8.lexicographicallyPrecedes(b.name.utf8)}
                return a.id<b.id
            }
            guard entries==sorted else{return}
            // 全量替换当前页，迟到回复不能覆盖新导航；下载队列另持有已批准条目的元数据。
            p.filesPageRequest="";p.filesPageDeadline = .distantFuture;p.view.filesState="shared";p.view.filesFolderId=p.filesExpectedFolder;p.view.filesOffset=Int(offset);p.view.filesTotal=Int(total);p.view.filesSkippedCount=Int(skipped);p.view.filesEntries=entries;p.view.filesBreadcrumbs=breadcrumbs;if p.view.filesMessage=="正在读取共享文件…" {p.view.filesMessage=entries.isEmpty ? "没有可显示的文件":"仅显示系统允许的文件范围"};changed()
        case "device.files.revoke":
            guard let request=message["requestId"] as? String,validHex(request,count:32),request==p.filesRequest,
                  let grant=message["grantId"] as? String,let reason=message["reason"] as? String,reason.utf8.count<=128 else{return}
            if p.view.filesGrantId.isEmpty {
                guard grant.isEmpty,["awaiting","selecting"].contains(p.view.filesState) else{return}
            } else {guard validHex(grant,count:32),grant==p.view.filesGrantId else{return}}
            let replacing=reason=="replace"
            revokeFiles(p,notify:false,state:replacing ? "selecting":"revoked",message:replacing ? "手机正在更换共享内容":"手机已结束文件共享",preserveRequest:replacing);changed()
        default: emit(p,"device.error",["requestId":message["requestId"] as? String ?? "","code":"INVALID","message":"目录消息无效"])
        }
    }
    func control(peer:String,channel:UUID,message:[String:Any]){
        guard let p=peers[peer],p.control==channel,let type=message["type"] as? String else{return}
        guard JSONSerialization.isValidJSONObject(message), let controlData=try? JSONSerialization.data(withJSONObject:message), controlData.count<=65536 else{close(channel);return}
        if type=="device.hello" {
            guard message["protocol"] as? String=="xq-device/1" else{return}
            p.view.browserQueryCapable=message["browserQueryProtocol"] as? String=="xq-browser-query/1"
            p.screenHeartbeat=message["screenHeartbeatProtocol"] as? String=="xq-screen-heartbeat/1";p.view.capable=true;p.view.screenCapable=message["screenProtocol"] as? String=="xq-screen/1";p.view.albumCapable=message["albumProtocol"] as? String=="xq-album/2";p.view.filesCapable=message["filesProtocol"] as? String=="xq-files/2"
            emit(p,"device.hello",["browserQueryProtocol":p.view.browserQueryCapable ? "xq-browser-query/1":"","screenHeartbeatProtocol":p.screenHeartbeat ? "xq-screen-heartbeat/1":"","protocol":"xq-device/1","screenProtocol":p.view.screenCapable ? "xq-screen/1":"","albumProtocol":p.view.albumCapable ? "xq-album/2":"","filesProtocol":p.view.filesCapable ? "xq-files/2":""]);changed();return
        }
        guard p.view.capable else{return}
        if type.hasPrefix("device.files.") {
            guard p.view.filesCapable else{return}
            filesControl(p,message:message,type:type);return
        }
        switch type {
        case "device.screen.state":
            guard !p.screenRequest.isEmpty,message["requestId"] as? String==p.screenRequest,message["screenId"] as? String==p.view.screenId,let state=message["state"] as? String,["awaiting","starting","active","paused","stopped","denied","unsupported","error"].contains(state) else{return}
            if ["paused","stopped","denied","unsupported","error"].contains(state){screenEnd(p,state:state,message:["unsupported","error"].contains(state) ? mediaText(message,fallback:screenText(state)):screenText(state),notify:false)}
            else{p.view.screenState=state;p.view.screenMessage=screenText(state);if state=="active"{p.screenDeadline=Date().addingTimeInterval(10)};changed()}
        case "device.screen.stop": if message["screenId"] as? String==p.view.screenId{screenEnd(p,state:"stopped",message:"手机已停止投屏",notify:false)}
        case "device.album.state":
            guard !p.albumRequest.isEmpty,message["requestId"] as? String==p.albumRequest,let state=message["state"] as? String,["awaiting","selecting","shared","denied","revoked","error","paused"].contains(state) else{return}
            if state=="shared" {
                guard let grant=message["grantId"] as? String,validHex(grant,count:32),let total=fileInteger(message["total"],maximum:200000) else{return}
                if grant==p.view.grantId {return}
                revokeAlbum(p,notify:false,state:"shared",message:total==0 ? "图库中没有此类型的内容":"已允许图库访问",preserveRequest:true);p.view.grantId=grant;p.view.albumTotal=Int(total);if p.albumPageActive{listAlbum(peer:peer,generation:p.generation,offset:0)}
            }else if ["denied","revoked","error","paused"].contains(state){revokeAlbum(p,notify:false,state:state,message:mediaText(message,fallback:state=="denied" ? "未允许图库访问，请在手机系统设置允许":"图库访问不可用，请检查手机权限后刷新"),preserveRequest:state=="error" || state=="denied")}
            else{p.view.albumState=state;p.view.albumMessage=mediaText(message,fallback:state=="selecting" ? "请在手机系统提示中允许图库访问":"请将续桥切到前台完成图库授权")};changed()
        case "device.album.page":
            guard p.albumPageActive,let request=message["requestId"] as? String,let offset=p.pageRequests[request],message["grantId"] as? String==p.view.grantId,
                  !p.view.browserQueryCapable || (message["query"] as? String==p.view.albumQuery && message["sort"] as? String==p.view.albumSort),
                  fileInteger(message["offset"],maximum:200000)==Int64(offset),let total=fileInteger(message["total"],maximum:200000),offset<max(1,Int(total)),
                  let items=message["assets"] as? [[String:Any]],items.count==min(30,Int(total)-offset),offset+items.count<=Int(total) else{return}
            var assets=[MediaAssetView](),seen=Set<String>()
            for (index,item) in items.enumerated() {
                guard let asset=item["assetId"] as? String,validHex(asset,count:32),seen.insert(asset).inserted,let name=fileName(item["name"]),let size=fileInteger(item["size"],maximum:9_007_199_254_740_991),let width=fileInteger(item["width"],maximum:65535),let height=fileInteger(item["height"],maximum:65535),let mime=item["mimeType"] as? String,mime.utf8.count<=100,mime.range(of:"^(image|video)/[a-zA-Z0-9.+-]+$",options:.regularExpression) != nil,mime.hasPrefix(p.view.albumKind+"/") else{return}
                guard p.positions[offset+index]==nil || p.positions[offset+index]==asset else{return}
                if let old=p.assets[asset] {guard old.name==name,old.size==size,old.width==Int(width),old.height==Int(height),old.mimeType==mime else{return}}
                let row=MediaAssetView(id:asset,name:name,size:size,width:Int(width),height:Int(height),mimeType:mime,preview:p.assets[asset]?.preview);assets.append(row)
            }
            p.pageRequests.removeValue(forKey:request);p.view.albumTotal=Int(total)
            p.view.assets=assets;p.view.albumOffset=offset;p.view.albumMessage="已允许图库访问";p.positions.removeAll();for (index,asset) in assets.enumerated(){p.assets[asset.id]=asset;p.positions[offset+index]=asset.id};pruneAlbum(p);previewMore(p);changed()
        case "device.album.previewResult":
            guard p.albumPageActive,let request=message["requestId"] as? String,let pending=p.previewRequests.removeValue(forKey:request),message["grantId"] as? String==p.view.grantId,message["assetId"] as? String==pending.0,let encoded=message["data"] as? String,encoded.utf8.count<=43692,let data=Data(base64Encoded:encoded),data.count<=32768,data.base64EncodedString()==encoded,let src=CGImageSourceCreateWithData(data as CFData,nil),let props=CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [CFString:Any],let width=props[kCGImagePropertyPixelWidth] as? Int,let height=props[kCGImagePropertyPixelHeight] as? Int,width>0,height>0,width<=320,height<=320,fileInteger(message["width"],maximum:320)==Int64(width),fileInteger(message["height"],maximum:320)==Int64(height) else{return}
            p.assets[pending.0]?.preview=data;if let i=p.view.assets.firstIndex(where:{$0.id==pending.0}){p.view.assets[i].preview=data};previewMore(p);changed()
        case "device.album.revoke": if !p.view.grantId.isEmpty,message["grantId"] as? String==p.view.grantId{let replacing=message["reason"] as? String=="replace";revokeAlbum(p,notify:false,state:replacing ? "selecting":"revoked",message:replacing ? "手机正在更换共享范围":"手机已撤销相册共享",preserveRequest:replacing);changed()}
        case "device.error":
            guard let request=message["requestId"] as? String,validHex(request,count:32) else{return}
            if p.previewRequests.removeValue(forKey:request) != nil{previewMore(p)}
            if request==p.downloadRequest{failOriginal(p,message:mediaText(message,fallback:"原件暂不可用，请刷新"))}
            if p.pageRequests.removeValue(forKey:request) != nil {p.view.albumMessage="图库分页读取失败，请刷新"}
            if request==p.albumRequest{revokeAlbum(p,notify:false,state:"error",message:mediaText(message,fallback:"相册请求未完成，请重试"))}
            filesError(p,request:request)
            if request==p.screenRequest{screenEnd(p,state:"error",message:mediaText(message,fallback:"投屏未能启动，请打开手机续桥完成确认后重试"),notify:true)};changed()
        default: emit(p,"device.error",["requestId":message["requestId"] as? String ?? "","code":"INVALID","message":"设备协作消息无效"])
        }
    }
    private func mediaText(_ message:[String:Any],fallback:String)->String {
        guard let text=message["message"] as? String,!text.isEmpty,text.utf8.count<=512,!text.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{return fallback};return text
    }
    private func screenText(_ state:String)->String{switch state{case"awaiting":return"请打开手机续桥，允许这台 Mac 投屏";case"starting":return"请在手机系统弹窗中允许屏幕共享";case"active":return"等待手机首帧画面…";case"paused":return"上次屏幕共享已被系统中断。请打开手机续桥，点击重新投屏并确认本次系统授权。";case"denied":return"手机未允许投屏，可重新申请";case"unsupported":return"此设备当前不支持屏幕采集或H264编码";case"error":return"投屏未能启动，请打开手机续桥检查提示后重试";default:return"投屏已停止"}}
    func tick(){let now=Date();for p in peers.values{
        if now>=p.filesPageDeadline && !p.filesPageRequest.isEmpty {p.filesPageRequest="";p.filesPageDeadline = .distantFuture;p.view.filesState="error";p.view.filesMessage="共享文件读取超时，请刷新或重新授权";changed()}
        if now>=p.filesDownloadDeadline && !p.filesDownloadRequest.isEmpty && !p.completingFile {engine.cancelMediaRequest(p.filesDownloadRequest);p.filesDownloadRequest="";p.filesDownloadTask="";p.view.filesDownloading="";p.filesDownloadDeadline = .distantFuture;p.view.filesMessage="文件下载超时，可重新下载";pumpFilesDownload(p);changed()}
        if now>=p.screenDeadline{screenEnd(p,state:"error",message:["active","streaming"].contains(p.view.screenState) ? "未收到可解码画面，请重新开始":"手机确认已超时，请打开手机续桥，再点击重新投屏并完成授权",notify:true)}
        if now>=p.frameDeadline{screenEnd(p,state:"error",message:"投屏帧接收超时，请重新开始",notify:true)}
        p.previewRequests=p.previewRequests.filter{now.timeIntervalSince($0.value.1)<10};previewMore(p)
        if now>=p.downloadDeadline && !p.downloadRequest.isEmpty && !p.completingOriginal {failOriginal(p,message:"原件下载超时，可重新下载");changed()}
    }}
    private func end(_ p:MediaPeerSession,reason:String){screenEnd(p,state:"stopped",message:reason,notify:false);revokeAlbum(p,notify:false,state:"revoked",message:reason);revokeFiles(p,notify:false,state:"revoked",message:reason)}
    private func pauseForLock(){locked=true;for p in peers.values{screenEnd(p,state:"paused",message:"Mac已锁屏或休眠，请解锁后重新开始",notify:true);revokeAlbum(p,notify:true,state:"paused",message:"Mac已锁屏，共享已暂停");revokeFiles(p,notify:true,state:"paused",message:"Mac已锁屏，文件共享已暂停")};changed()}
    func unlocked(){locked=false;changed()}
}
