import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import CoreImage
import CoreGraphics

/// 真实H264 AnnexB解码；只有输出实际PixelBuffer才产生画面与首帧成功事件。
public final class ScreenDecoder {
    private let queue = DispatchQueue(label:"com.chenguangyao.xuqiao.screen.decode",qos:.userInitiated)
    private let context = CIContext(options:[.cacheIntermediates:false])
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps = Data(), pps = Data()
    private var epoch = 0
    public init() {}
    deinit {if let session{VTDecompressionSessionInvalidate(session)}}
    public func reset() { queue.async { self.epoch += 1; if let s=self.session { VTDecompressionSessionInvalidate(s) }; self.session=nil; self.format=nil; self.sps.removeAll();self.pps.removeAll() } }
    public func decode(_ data: Data, ptsUs: Int64, completion: @escaping (CGImage?, Bool) -> Void) {
        queue.async {
            do {
                let nals = try Self.nals(data)
                for nal in nals {
                    let type=nal.first! & 31
                    if type==7 && nal != self.sps { self.sps=nal;self.invalidate() }
                    if type==8 && nal != self.pps { self.pps=nal;self.invalidate() }
                }
                let slices=nals.filter { let t=$0.first! & 31;return t != 7 && t != 8 && t != 9 }
                guard slices.contains(where:{ [1,5].contains($0.first! & 31) }) else { completion(nil,true);return }
                guard !self.sps.isEmpty,!self.pps.isEmpty else { completion(nil,false);return }
                try self.ensureSession()
                guard let session=self.session,let format=self.format else { throw CoreFailure("H264格式不可用") }
                var avcc=Data()
                for nal in slices { var n=UInt32(nal.count).bigEndian;avcc.append(Data(bytes:&n,count:4));avcc.append(nal) }
                var block: CMBlockBuffer?
                guard CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:avcc.count,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:avcc.count,flags:0,blockBufferOut:&block)==kCMBlockBufferNoErr,let block else { throw CoreFailure("视频缓冲不可用") }
                let copied=avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block,offsetIntoDestination:0,dataLength:avcc.count) }
                guard copied==kCMBlockBufferNoErr else {throw CoreFailure("视频缓冲不可用")}
                var sample: CMSampleBuffer?
                var timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:CMTime(value:ptsUs,timescale:1_000_000),decodeTimeStamp:.invalid)
                var size=avcc.count
                guard CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:format,sampleCount:1,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample)==noErr,let sample else {throw CoreFailure("视频样本不可用")}
                let token=self.epoch
                let status=VTDecompressionSessionDecodeFrame(session,sampleBuffer:sample,flags:[],infoFlagsOut:nil) { [weak self] status,_,buffer,_,_ in
                    guard let self else {completion(nil,false);return}
                    self.queue.async {
                        guard token==self.epoch,status==noErr,let buffer,CVPixelBufferGetWidth(buffer)>0,CVPixelBufferGetHeight(buffer)>0,CVPixelBufferGetWidth(buffer)<=1920,CVPixelBufferGetHeight(buffer)<=1920,CVPixelBufferGetWidth(buffer)*CVPixelBufferGetHeight(buffer)<=2073600,let image=self.context.createCGImage(CIImage(cvPixelBuffer:buffer),from:CGRect(x:0,y:0,width:CVPixelBufferGetWidth(buffer),height:CVPixelBufferGetHeight(buffer))) else {completion(nil,false);return}
                        completion(image,true)
                    }
                }
                if status != noErr { completion(nil,false) }
            } catch {completion(nil,false)}
        }
    }
    private func invalidate() { if let session {VTDecompressionSessionInvalidate(session)};session=nil;format=nil }
    private func ensureSession() throws {
        if session != nil {return}
        let status=sps.withUnsafeBytes { sb in pps.withUnsafeBytes { pb -> OSStatus in
            var pointers=[sb.bindMemory(to:UInt8.self).baseAddress!,pb.bindMemory(to:UInt8.self).baseAddress!]
            var sizes=[sps.count,pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator:kCFAllocatorDefault,parameterSetCount:2,parameterSetPointers:&pointers,parameterSetSizes:&sizes,nalUnitHeaderLength:4,formatDescriptionOut:&format)
        }}
        guard status==noErr,let format else {throw CoreFailure("H264参数无效")}
        let dimensions=CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width>0,dimensions.height>0,dimensions.width<=1920,dimensions.height<=1920,Int64(dimensions.width)*Int64(dimensions.height)<=2073600 else {throw CoreFailure("H264画面尺寸超过限制")}
        let attrs=[kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_32BGRA] as CFDictionary
        guard VTDecompressionSessionCreate(allocator:kCFAllocatorDefault,formatDescription:format,decoderSpecification:nil,imageBufferAttributes:attrs,outputCallback:nil,decompressionSessionOut:&session)==noErr else {throw CoreFailure("H264解码器不可用")}
    }
    static func nals(_ data:Data)throws->[Data] {
        guard !data.isEmpty,data.count<=524288 else {throw CoreFailure("视频帧越界")}
        let a=[UInt8](data);var marks:[(Int,Int)]=[];var i=0
        while i+2<a.count {
            if a[i]==0 && a[i+1]==0 && a[i+2]==1 {marks.append((i,i+3));i+=3}
            else if i+3<a.count && a[i]==0 && a[i+1]==0 && a[i+2]==0 && a[i+3]==1 {marks.append((i,i+4));i+=4}
            else {i+=1}
        }
        guard marks.first?.0==0,marks.count<=256 else {throw CoreFailure("H264 AnnexB无效")}
        var result=[Data]()
        for j in marks.indices {let start=marks[j].1,end=j+1<marks.count ? marks[j+1].0:a.count;guard end>start else{throw CoreFailure("NAL无效")};result.append(Data(a[start..<end]))}
        return result
    }
}
