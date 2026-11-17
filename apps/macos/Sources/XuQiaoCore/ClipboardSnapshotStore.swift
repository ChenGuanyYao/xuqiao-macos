import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum ClipboardCapture {
    case text(String)
    case paths([URL])
    case image(Data)
}
struct ClipboardPrepared {
    var content: ClipboardContent
    var snapshot: ClipboardSnapshotIndex?
}
/// ImageIO先探测尺寸再解码；不以文件扩展名或NSImage点数冒充像素尺寸。
enum ClipboardImage {
    static func properties(_ source: CGImageSource) throws -> (width: Int, height: Int, mime: String) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? NSNumber, let h = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              w.doubleValue.rounded() == w.doubleValue, h.doubleValue.rounded() == h.doubleValue,
              w.int64Value > 0, h.int64Value > 0, w.int64Value <= CLIPBOARD_MAX_PIXEL_COUNT / h.int64Value,
              let type = CGImageSourceGetType(source), let uti = UTType(type as String), uti.conforms(to: .image), let mime = uti.preferredMIMEType else { throw ClipboardFailure.invalid }
        return (w.intValue, h.intValue, mime)
    }
    static func probe(_ url: URL) throws -> (width: Int, height: Int, mime: String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true else { return nil }
        return try properties(source)
    }
    static func png(_ bytes: Data, to url: URL) throws -> (Int, Int) {
        guard bytes.count <= FILE_MAX_SIZE, let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ClipboardFailure.invalid }
        let info = try properties(source)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == info.width, image.height == info.height,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ClipboardFailure.io }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ClipboardFailure.io }
        return (info.width, info.height)
    }
    static func validate(_ record: ClipboardContent, at url: URL) throws {
        if record.kind == "image" {
            guard let image = try probe(url), image.width == record.imageWidth, image.height == record.imageHeight, image.mime == record.mimeType else { throw ClipboardFailure.invalid }
        }
    }
}

final class ClipboardSnapshotStore {
    let storage: FileStorage
    let ttl: Int64
    let maximum: Int64
    // 仅协调器队列更改lease；IO完成前不释放，因此GC不能与复制并发删除同快照。
    private(set) var leases: [String: Int] = [:]
    init(configuration: ServerConfiguration) throws {
        storage = try FileStorage(directory: configuration.fileStoreDirectory)
        #if DEBUG
        ttl = configuration.clipboardCacheTTL ?? 604800; maximum = configuration.clipboardCacheMaximum ?? 536870912
        #else
        ttl = 604800; maximum = 536870912
        #endif
        try FileStorage.directory(storage.root.appendingPathComponent("ClipboardSnapshots"))
    }
    func path(_ id: String) -> URL { storage.root.appendingPathComponent("ClipboardSnapshots").appendingPathComponent(id).appendingPathComponent("payload") }
    func checked(_ index: ClipboardSnapshotIndex) throws -> URL {
        guard validHex(index.recordId, count: 32), index.relativePath == "ClipboardSnapshots/\(index.recordId)/payload" else { throw ClipboardFailure.io }
        for directory in [storage.root.appendingPathComponent("ClipboardSnapshots"), path(index.recordId).deletingLastPathComponent()] {
            var info = stat()
            if lstat(directory.path, &info) != 0 { if errno == ENOENT { throw ClipboardFailure(code: "CLIP_EXPIRED") }; throw ClipboardFailure.io }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw ClipboardFailure.io }
        }
        return path(index.recordId)
    }
    func acquire(_ id: String) { leases[id, default: 0] += 1 }
    func release(_ id: String) { let count = leases[id, default: 0] - 1; if count <= 0 { leases.removeValue(forKey: id) } else { leases[id] = count } }
    func remove(_ index: ClipboardSnapshotIndex) throws {
        guard leases[index.recordId, default: 0] == 0 else { throw ClipboardFailure(code: "CLIP_BUSY") }
        try storage.removeClipboardCache(index)
    }
    func prepare(_ capture: ClipboardCapture, id: String, source: String, capturedAt: Int64, cancellation: WorkCancellation) throws -> ClipboardPrepared {
        var content = ClipboardContent(recordId: id, sourceDeviceId: source, capturedAt: capturedAt, kind: "text", name: "", size: 0, sha256: "")
        if case .text(let text) = capture {
            guard let bytes = clipboardBytes(text) else { throw ClipboardFailure.invalid }
            content.size = Int64(bytes.count); content.sha256 = digest(bytes); content.data = bytes.base64EncodedString(); content.mimeType = "text/plain"
            return ClipboardPrepared(content: content, snapshot: nil)
        }
        let directory = path(id).deletingLastPathComponent(); try FileStorage.directory(directory)
        let temporary = directory.appendingPathComponent(".payload.partial"), stageID = "clipboard-" + id
        var finished = false
        defer {
            try? FileManager.default.removeItem(at: storage.source(stageID).deletingLastPathComponent())
            if !finished { try? FileManager.default.removeItem(at: directory) }
        }
        switch capture {
        case .text: break
        case .paths(let urls):
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }; defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
            let prepared = try storage.prepareMany(urls, id: stageID, cancellation: cancellation)
            content.kind = prepared.group == nil ? "file" : urls.count == 1 ? "folder" : "group"
            content.name = prepared.name; content.size = prepared.size; content.sha256 = prepared.sha256
            if let group = prepared.group {
                content.groupHash = group.groupHash; content.totalBytes = group.totalBytes; content.entryCount = group.entryCount; content.roots = group.roots; content.mimeType = "application/zip"
            } else {
                if let info = try ClipboardImage.probe(storage.source(stageID)) {
                    content.kind = "image"; content.imageWidth = info.width; content.imageHeight = info.height; content.mimeType = info.mime
                } else { content.mimeType = "application/octet-stream" }
            }
            guard rename(storage.source(stageID).path, temporary.path) == 0 else { throw ClipboardFailure.io }
        case .image(let bytes):
            let dimensions = try ClipboardImage.png(bytes, to: temporary)
            let fd = try openRegular(temporary); defer { close(fd) }; var info = stat()
            guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= FILE_MAX_SIZE else { throw ClipboardFailure.invalid }
            content.kind = "image"; content.size = info.st_size; content.sha256 = try hashFile(temporary, expectedSize: info.st_size)
            content.name = "clipboard-" + String(content.sha256.prefix(12)) + ".png"
            content.imageWidth = dimensions.0; content.imageHeight = dimensions.1; content.mimeType = "image/png"
        }
        try cancellation.check()
        let fd = try openRegular(temporary); defer { close(fd) }
        guard fsync(fd) == 0, fchmod(fd, 0o400) == 0, rename(temporary.path, path(id).path) == 0 else { throw ClipboardFailure.io }
        try synchronizeDirectory(directory); try synchronizeDirectory(directory.deletingLastPathComponent())
        _ = try ClipboardContent.parse(content.object)
        let now = milliseconds(); finished = true
        return ClipboardPrepared(content: content, snapshot: ClipboardSnapshotIndex(recordId: id, relativePath: "ClipboardSnapshots/\(id)/payload", createdAt: now, expiresAt: now + ttl * 1000, byteSize: content.size))
    }
}

extension ClipboardSnapshotStore {
    /// 只在启动、还没有准备/lease时调用；按目录FD逐项unlink，不跟随任何子链接。
    func recoverOrphans(indices: [ClipboardSnapshotIndex]) throws {
        let known = Set(indices.map(\.recordId))
        for (directory, clipboardStage) in [(storage.root.appendingPathComponent("ClipboardSnapshots"), false), (storage.root.appendingPathComponent("Staging"), true)] {
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { throw ClipboardFailure.io }; defer { close(fd) }
            let duplicate = dup(fd); guard duplicate >= 0, let listing = fdopendir(duplicate) else { throw ClipboardFailure.io }; defer { closedir(listing) }
            while let entry = readdir(listing) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
                if name == "." || name == ".." { continue }
                let id = clipboardStage && name.hasPrefix("clipboard-") ? String(name.dropFirst(10)) : name
                guard validHex(id, count: 32), !clipboardStage || name == "clipboard-" + id,
                      clipboardStage || !known.contains(id) else { continue }
                var budget = 4096; try removeOwnedNode(parent: fd, name: name, depth: 0, budget: &budget)
            }
            guard fsync(fd) == 0 else { throw ClipboardFailure.io }
        }
        // 已被GC标记的索引不再计ready容量，不能残留未删除的旧payload。
        for index in indices where index.state != "ready" {
            let url: URL
            do { url = try checked(index) } catch let failure as ClipboardFailure where failure.code == "CLIP_EXPIRED" { continue }
            if unlink(url.path) != 0 && errno != ENOENT { throw ClipboardFailure.io }
        }
    }
    private func removeOwnedNode(parent: Int32, name: String, depth: Int, budget: inout Int) throws {
        guard depth <= 20, budget > 0, fileName(name) != nil else { throw ClipboardFailure.io }; budget -= 1
        var info = stat(); guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { if errno == ENOENT { return }; throw ClipboardFailure.io }
        if info.st_mode & S_IFMT == S_IFDIR {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); guard child >= 0 else { throw ClipboardFailure.io }; defer { close(child) }
            for item in try groupDirectoryNames(child) { try removeOwnedNode(parent: child, name: item, depth: depth + 1, budget: &budget) }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw ClipboardFailure.io }
        } else {
            guard info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFLNK, unlinkat(parent, name, 0) == 0 else { throw ClipboardFailure.io }
        }
    }
}
