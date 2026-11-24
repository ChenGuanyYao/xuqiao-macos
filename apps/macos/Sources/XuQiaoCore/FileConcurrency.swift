import Foundation

let FILE_PENDING_LIMIT = 50

/// 槽位在 offer 时预留，直到收据或终态释放；等待用户确认也计数，防止对端无限打开连接。
struct FileConcurrencyLimits {
    let files: Int
    let clipboard: Int
    let legacy: Bool

    init(hello: [String: Any]) throws {
        func capability(_ key: String, allowed: ClosedRange<Int>) throws -> Int? {
            guard let raw = hello[key] else { return nil }
            guard let n = raw as? NSNumber,
                  !["f", "d"].contains(String(cString: n.objCType)),
                  let value = fileInteger(raw, maximum: Int64(allowed.upperBound)), allowed.contains(Int(value)) else {
                throw FileFailure(code: "FILE_INVALID", message: "文件并发能力无效")
            }
            return Int(value)
        }
        let files = try capability("maxConcurrentFiles", allowed: 1...3)
        let clipboard = try capability("maxConcurrentClipboard", allowed: 1...1)
        self.files = files ?? 1; self.clipboard = clipboard ?? 1
        legacy = files == nil || clipboard == nil
    }
    func permits(_ candidate: FileTask, among tasks: [FileTask]) -> Bool {
        let active = tasks.filter { $0.peerId == candidate.peerId && $0.id != candidate.id && !$0.state.terminal && ![.queued, .waitingConnection].contains($0.state) }
        if legacy { return active.isEmpty }
        let isClipboard = candidate.clipboard != nil
        let used = active.filter { $0.direction == candidate.direction && ($0.clipboard != nil) == isClipboard }.count
        return used < (isClipboard ? clipboard : files)
    }
}
