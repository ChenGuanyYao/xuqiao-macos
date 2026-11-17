import Foundation
import Darwin
import CoreFoundation

final class DiscoveryResponder {
    private let fd: Int32
    private let source: DispatchSourceRead
    init(port: UInt16, queue: DispatchQueue, advertisement: @escaping (String) -> [String: Any]?) throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw CoreFailure("无法创建局域网发现通道") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        let descriptor = fd
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { close(fd); throw CoreFailure("发现端口 \(port) 已被占用") }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        for ip in ["0.0.0.0"] + localAddresses().filter({ $0 != "127.0.0.1" }) {
            var request = ip_mreq(); inet_pton(AF_INET, "239.255.76.68", &request.imr_multiaddr); inet_pton(AF_INET, ip, &request.imr_interface)
            setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size))
        }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                var bytes = [UInt8](repeating: 0, count: 8193)
                var remote = sockaddr_in(); var remoteSize = socklen_t(MemoryLayout<sockaddr_in>.size)
                let size = withUnsafeMutablePointer(to: &remote) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &bytes, bytes.count, 0, $0, &remoteSize) } }
                if size < 0 { break }
                guard size <= 8192, size > 0,
                      let object = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(size))) as? [String: Any],
                      object["service"] as? String == "xuqiao.connect", let version = object["v"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1, object["type"] as? String == "discover",
                      let nonce = validIdentifier(object["nonce"]), let answer = advertisement(nonce),
                      let data = try? JSONSerialization.data(withJSONObject: answer), data.count <= 8192 else { continue }
                data.withUnsafeBytes { buffer in
                    withUnsafePointer(to: &remote) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(descriptor, buffer.baseAddress, data.count, 0, $0, remoteSize) }
                    }
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }
    func stop() { source.cancel() }
    deinit { source.cancel() }
}
