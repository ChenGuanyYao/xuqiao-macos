import Foundation
import Network
import CoreFoundation

final class TLSChannel {
    let id = UUID()
    let connection: NWConnection
    let createdAt = Date()
    var authenticatedPeer: String?
    var fileCapable = false
    var groupCapable = false
    var receivedFirstMessage = false
    var isMediaData = false
    var isFileData = false
    var fileControlID: UUID?
    var filePeerID: String?
    var lastPong = Date()
    var lastPing = Date.distantPast
    var pingRequest: String?
    var closing = false
    var protocolViolation = false
    private var buffer = Data()
    private var ended = false
    private var receiving = false
    private var paused = false
    private var remoteEnded = false
    var onMessage: ((TLSChannel, [String: Any]) -> Void)?
    var onClose: ((TLSChannel) -> Void)?

    init(_ connection: NWConnection) { self.connection = connection }
    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receive()
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    /// 数据块写盘/处理前暂停读取，避免把无限网络帧排到文件 IO 队列。
    func pauseReceiving() { paused = true }
    func resumeReceiving() { guard !ended, !closing else { return }; paused = false; drain() }
    private func receive() {
        guard !closing, !ended, !paused, !receiving, !remoteEnded else { return }
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_540) { [weak self] data, _, complete, error in
            guard let self, !self.ended, !self.closing else { return }
            self.receiving = false
            if let data { self.buffer.append(data) }
            if error != nil || complete { self.remoteEnded = true }
            self.drain()
        }
    }
    private func drain() {
        guard !closing, !ended, !paused else { return }
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard (1...65_536).contains(length) else { protocolViolation = true; close(); return }
            if buffer.count < length + 4 { break }
            let payload = buffer.subdata(in: 4..<(length + 4))
            buffer.removeSubrange(0..<(length + 4))
            guard String(data: payload, encoding: .utf8) != nil,
                  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let version = object["v"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                  let type = object["type"] as? String, !type.isEmpty else { protocolViolation = true; close(); return }
            onMessage?(self, object)
            if closing || ended || paused { return }
        }
        guard buffer.count <= 65_540 else { protocolViolation = true; close(); return }
        if remoteEnded { close() } else { receive() }
    }
    func send(_ message: [String: Any], closeAfter: Bool = false) {
        guard !ended, !closing, let body = try? JSONSerialization.data(withJSONObject: message), body.count <= 65_536 else { return }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4); frame.append(body)
        if closeAfter { closing = true }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil || closeAfter { self.close() }
        })
    }
    func close() { connection.cancel(); finish() }
    private func finish() {
        guard !ended else { return }; ended = true; closing = true
        onClose?(self)
        onClose = nil; onMessage = nil; connection.stateUpdateHandler = nil
    }
}
