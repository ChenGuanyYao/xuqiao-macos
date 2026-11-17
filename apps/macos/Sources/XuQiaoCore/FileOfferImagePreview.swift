import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 独立的小 JPEG 元数据；它不代表原件已接收，也不参与原件接收授权。
public struct FileOfferImagePreview: Codable {
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let byteSize: Int
    public let sha256: String
    public let data: Data

    var wireFields: [String: Any] {
        ["mimeType": mimeType, "width": width, "height": height, "byteSize": byteSize,
         "sha256": sha256, "data": data.base64EncodedString()]
    }
    static func imageName(_ name: String) -> Bool {
        let suffix = URL(fileURLWithPath: name).pathExtension
        return UTType(filenameExtension: suffix)?.conforms(to: .image) == true
    }
    static func parse(_ input: Any?) -> FileOfferImagePreview? {
        // 先限制声明值和 Base64，之后才分配解码内容及请求 ImageIO 解码。
        guard let value = input as? [String: Any], value["mimeType"] as? String == "image/jpeg",
              let width = fileInteger(value["width"], maximum: 320), width > 0,
              let height = fileInteger(value["height"], maximum: 320), height > 0,
              let size = fileInteger(value["byteSize"], maximum: 24_576), size > 0,
              let sha = value["sha256"] as? String, validHex(sha),
              let encoded = value["data"] as? String, encoded.utf8.count <= 32_768,
              encoded.utf8.count == ((Int(size) + 2) / 3) * 4,
              encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43, 47, 61].contains($0) }),
              let bytes = Data(base64Encoded: encoded), bytes.count == size,
              bytes.base64EncodedString() == encoded, digest(bytes) == sha,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier, CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              fileInteger(properties[kCGImagePropertyPixelWidth], maximum: 320) == width,
              fileInteger(properties[kCGImagePropertyPixelHeight], maximum: 320) == height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height else { return nil }
        return FileOfferImagePreview(mimeType: "image/jpeg", width: Int(width), height: Int(height), byteSize: Int(size), sha256: sha, data: bytes)
    }
    /// 只由文件准备 IO 队列传入应用私有快照，失败时原件仍按原协议发送。
    static func make(name: String, snapshot: URL, cancellation: WorkCancellation) -> FileOfferImagePreview? {
        guard !cancellation.isCancelled, imageName(name),
              let source = CGImageSourceCreateWithURL(snapshot as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              (try? ClipboardImage.properties(source)) != nil else { return nil }
        for edge in [320, 240, 160, 96] {
            guard !cancellation.isCancelled,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: edge,
                    kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            for quality in [0.78, 0.55, 0.32] {
                guard !cancellation.isCancelled else { return nil }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { return nil }
                if output.length <= 24_576 {
                    let bytes = output as Data
                    return parse(["mimeType": "image/jpeg", "width": image.width, "height": image.height,
                                  "byteSize": bytes.count, "sha256": digest(bytes), "data": bytes.base64EncodedString()])
                }
            }
        }
        return nil
    }
}
