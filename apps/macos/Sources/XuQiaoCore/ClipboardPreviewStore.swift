import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

struct ClipboardPreviewIndex {
    var source: String, record: String, payloadSHA: String, previewSHA: String
    var width: Int, height: Int
    var size: Int64
    var relativePath: String
    var accessed: Int64
    var key: String { source + ":" + record }
}
struct ClipboardPreviewBytes {
    var data: Data, width: Int, height: Int
    var sha: String { digest(data) }
    static func validate(_ data: Data, width: Int, height: Int, sha: String) throws -> ClipboardPreviewBytes {
        guard (1...32_768).contains(data.count), validHex(sha), digest(data) == sha,
              (1...320).contains(width), (1...320).contains(height), width * height <= 102_400,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary), image.width == width, image.height == height else { throw ClipboardFailure.invalid }
        return ClipboardPreviewBytes(data: data, width: width, height: height)
    }
    /// 原图只在IO队列读取：核对不可变摘要，ImageIO直接首帧下采样，不解码完整大图。
    static func make(content: ClipboardContent, url: URL) throws -> ClipboardPreviewBytes {
        guard try hashFile(url, expectedSize: content.size) == content.sha256,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ClipboardFailure.io }
        let properties = try ClipboardImage.properties(source)
        guard properties.width == content.imageWidth, properties.height == content.imageHeight else { throw ClipboardFailure.invalid }
        for edge in [320, 240, 160, 96] {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ClipboardFailure.io }
            for quality in [0.78, 0.55, 0.32] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw ClipboardFailure.io }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ClipboardFailure.io }
                if output.length <= 32_768 { return try validate(output as Data, width: image.width, height: image.height, sha: digest(output as Data)) }
            }
        }
        throw ClipboardFailure.io
    }
}

/// DB只保索引；独立32MiB LRU不触及原图、收件箱或公共下载目录。
final class ClipboardPreviewStore {
    private let database: ClipboardRecordStore
    private let root: URL
    private let directory: URL
    private(set) var indices: [String: ClipboardPreviewIndex] = [:]
    init(database: ClipboardRecordStore, root: URL) throws {
        self.database = database; self.root = root; directory = root.appendingPathComponent("ClipboardPreviews")
        try FileStorage.directory(directory)
        for index in try database.previews() {
            if let url = try? checked(index), (try? read(url, index: index)) != nil { indices[index.key] = index }
            else { try database.removePreview(source: index.source, id: index.record) }
        }
        // 只清本专属平面目录中的无索引普通文件，不跟随链接或递归到用户内容。
        let known = Set(indices.values.map(\.relativePath))
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            guard name.hasSuffix(".jpg"), validHex(String(name.dropLast(4))), !known.contains("ClipboardPreviews/" + name) else { continue }
            var info = stat(); if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { _ = unlink(url.path) }
        }
    }
    var bytes: Int64 { indices.values.reduce(0) { $0 + $1.size } }
    private func checked(_ index: ClipboardPreviewIndex) throws -> URL {
        let name = digest(Data((index.source + ":" + index.record + ":" + index.payloadSHA).utf8)) + ".jpg"
        guard index.relativePath == "ClipboardPreviews/" + name else { throw ClipboardFailure.io }
        var info = stat(); guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ClipboardFailure.io }
        return directory.appendingPathComponent(name)
    }
    private func read(_ url: URL, index: ClipboardPreviewIndex) throws -> ClipboardPreviewBytes {
        let fd = try openRegular(url); defer { close(fd) }; var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == index.size, info.st_size <= 32_768 else { throw ClipboardFailure.io }
        return try ClipboardPreviewBytes.validate(readBlock(fd, limit: 32_769), width: index.width, height: index.height, sha: index.previewSHA)
    }
    func url(_ row: ClipboardRecord) -> URL? {
        guard let index = indices[row.key], index.payloadSHA == row.content.sha256 else { return nil }
        return try? checked(index)
    }
    func cached(_ row: ClipboardRecord) -> ClipboardPreviewBytes? {
        guard let index = indices[row.key], index.payloadSHA == row.content.sha256, let url = try? checked(index) else { return nil }
        return try? read(url, index: index)
    }
    func touch(_ row: ClipboardRecord) {
        guard var index = indices[row.key], milliseconds() - index.accessed > 10_000 else { return }
        index.accessed = milliseconds(); if (try? database.savePreview(index)) != nil { indices[row.key] = index }
    }
    func put(_ preview: ClipboardPreviewBytes, row: ClipboardRecord) throws {
        let relative = "ClipboardPreviews/" + digest(Data((row.key + ":" + row.content.sha256).utf8)) + ".jpg"
        let index = ClipboardPreviewIndex(source: row.content.sourceDeviceId, record: row.content.recordId, payloadSHA: row.content.sha256,
            previewSHA: preview.sha, width: preview.width, height: preview.height, size: Int64(preview.data.count), relativePath: relative, accessed: milliseconds())
        let url = try checked(index), temporary = directory.appendingPathComponent("." + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ClipboardFailure.io }; defer { close(fd); unlink(temporary.path) }
        try writeBlock(fd, preview.data); guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw ClipboardFailure.io }
        try synchronizeDirectory(directory); try database.savePreview(index); indices[row.key] = index
        while bytes > 33_554_432, let oldest = indices.values.min(by: { $0.accessed < $1.accessed }) { try remove(source: oldest.source, id: oldest.record) }
    }
    func remove(source: String, id: String) throws {
        guard let index = indices[source + ":" + id] else { return }
        let url = try checked(index); if unlink(url.path) != 0 && errno != ENOENT { throw ClipboardFailure.io }
        try synchronizeDirectory(directory); try database.removePreview(source: source, id: id); indices.removeValue(forKey: index.key)
    }
    func clear() -> ManagementResult {
        var result = ManagementResult()
        for index in Array(indices.values) { do { try remove(source: index.source, id: index.record); result.removed += 1 } catch { result.failed += 1 } }
        return result
    }
}
