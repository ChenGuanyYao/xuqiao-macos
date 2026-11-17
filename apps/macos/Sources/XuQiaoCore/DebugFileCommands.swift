#if DEBUG
import Foundation
import Darwin

/// 本地测试夹具，不是生产 IPC；无符号链接、当前用户0600普通文件、最多1MiB。
final class DebugFileCommands {
    private var processed = Set<String>()
    private var previousDigest = ""
    func poll(path: String) -> [[String: Any]] {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return [] }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, (0...1_048_576).contains(info.st_size) else { return [] }
        var data = Data()
        while data.count <= 1_048_576 {
            guard let part = try? readBlock(fd, limit: min(65_536, 1_048_577 - data.count)) else { return [] }
            if part.isEmpty { break }; data.append(part)
        }
        guard data.count <= 1_048_576 else { return [] }
        let hash = digest(data); guard hash != previousDigest else { return [] }; previousDigest = hash
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commands = object["commands"] as? [[String: Any]], commands.count <= 2048 else { return [] }
        var result: [[String: Any]] = []
        for command in commands {
            guard processed.count < 32_768, let id = validIdentifier(command["id"]), !processed.contains(id) else { continue }
            processed.insert(id); result.append(command)
        }
        return result
    }
}
#endif
