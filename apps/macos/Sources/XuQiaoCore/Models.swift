import Foundation
import CryptoKit
import Security
import Darwin

public struct ServerConfiguration {
    public var port: UInt16 = 49631
    public var discoveryPort: UInt16 = 49630
    public var keychainSuffix = ""
    public var autoApprove = false
    /// 仅正常 GUI 显式启用；隔离命令默认不会创建蓝牙管理器。
    public var bluetoothWakeEnabled = false
    public var testSessionFile: String?
    public var fileStoreDirectory: String?
    #if DEBUG
    public var autoAcceptFiles = false
    public var testFileCommand: String?
    public var clipboardPasteboard: String?
    public var clipboardCacheTTL: Int64?
    public var clipboardCacheMaximum: Int64?
    #endif
    public init() {}
}

public struct PeerView: Identifiable {
    public let id: String
    public let name: String
    public let connected: Bool
    public let paused: Bool
    public let lastSeen: Date
    public var fileCapable = false
    public var groupCapable = false
    public var trustGeneration = ""
    /// 仅来自当前已认证控制连接，不写入设备信任或作为长期身份。
    public var remoteHost: String?
}

public struct PendingView: Identifiable {
    public let id: String
    /// 单次连接请求标识；同一二维码重试时仍可提示，快照心跳不重复抢焦点。
    public let requestID: String
    public let name: String
    public let verificationCode: String
    public let phoneConfirmed: Bool
    public let macConfirmed: Bool
}

public struct ServerSnapshot {
    public var ready = false
    public var bluetoothWakeStatus = "蓝牙辅助未启用"
    public var bluetoothWakeAuthorization = BluetoothWakeAuthorization.notDetermined
    public var bluetoothWakeHardware = BluetoothWakeHardware.unknown
    public var bluetoothWakeAuthenticatedPeers = 0
    public var status = "正在启动安全连接服务…"
    public var host = "127.0.0.1"
    public var port: UInt16 = 49631
    public var discoveryPort: UInt16 = 49630
    public var deviceName = "Mac"
    public var deviceID = ""
    public var fingerprint = ""
    public var pairingCode = ""
    public var qr = ""
    public var expiresAt = Date()
    public var pending: PendingView?
    public var peers: [PeerView] = []
    public var error: String?
    public var files = FileTransferSnapshot()
    public var media: [DeviceMediaView] = []
    public var clipboardPeers: [ClipboardPeerView] = []
    public var clipboardRecords: [ClipboardRecordView] = []
    public var clipboardPage: [ClipboardRecordView] = []
    public var clipboardQueryID = ""
    public var clipboardQueryCount = 0
    public var clipboardCache = ClipboardCacheView()
    public var clipboardNoticeRevision: UInt64 = 0
    public var clipboardNoticeIsReceipt = false
    public var clipboardNotice: String?
    public var clipboardPreferences = ClipboardPreferences()
    public var clipboardContext = ""
    public var clipboardPreferencesError: String?
    public init() {}
}

public enum BluetoothWakeAuthorization: String {
    case notDetermined, allowed, denied, restricted, unknown
    public var label: String {
        switch self {
        case .notDetermined: return "尚未决定"
        case .allowed: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "系统限制"
        case .unknown: return "授权状态未知"
        }
    }
}

public enum BluetoothWakeHardware: String {
    case unknown, poweredOn, poweredOff, unsupported, resetting, unavailable
    public var label: String {
        switch self {
        case .unknown: return "硬件状态待检查"
        case .poweredOn: return "蓝牙已开启"
        case .poweredOff: return "蓝牙已关闭"
        case .unsupported: return "系统不支持蓝牙辅助"
        case .resetting: return "蓝牙服务正在恢复"
        case .unavailable: return "授权后可检查硬件状态"
        }
    }
}

struct StoredPeer: Codable {
    var id: String
    var name: String
    var clipboardTrustGeneration: String? = nil
    var tokenHash: String
    var paused: Bool
    var lastSeen: Date
}

public struct CoreFailure: LocalizedError {
    let detail: String
    public init(_ detail: String) { self.detail = detail }
    public var errorDescription: String? { detail }
}

func secureBytes(_ count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw CoreFailure("无法生成安全随机数") }
    return Data(bytes)
}

func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
func digest(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }
func milliseconds(_ date: Date = Date()) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
func constantEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
func validIdentifier(_ value: Any?) -> String? {
    guard let s = value as? String, !s.isEmpty, s.utf8.count <= 128,
          !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    return s
}
func validHex(_ s: String, count: Int = 64) -> Bool {
    s.count == count && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
func wire(_ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
    var result = fields; result["v"] = 1; result["type"] = type; return result
}

private struct IPv4Interface {
    let name: String
    let address: String
    let flags: UInt32
}
private func ipv4Interfaces() -> [IPv4Interface] {
    var ptr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ptr) == 0 else { return [] }
    defer { freeifaddrs(ptr) }
    var values: [IPv4Interface] = []
    var cursor = ptr
    while let item = cursor {
        defer { cursor = item.pointee.ifa_next }
        guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
              item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
        var v4 = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        if inet_ntop(AF_INET, &v4, &chars, socklen_t(INET_ADDRSTRLEN)) != nil {
            let ip = String(cString: chars)
            if ip != "0.0.0.0" { values.append(IPv4Interface(name: String(cString: item.pointee.ifa_name), address: ip, flags: item.pointee.ifa_flags)) }
        }
    }
    return values
}
/// SAN 覆盖所有已启用 IPv4，身份由持久 CA 决定，不依赖 IP。
func localAddresses() -> [String] {
    Array(Set(ipv4Interfaces().map(\.address) + ["127.0.0.1"])).sorted()
}
private func isPrivateIPv4(_ ip: String) -> Bool {
    if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return true }
    let p = ip.split(separator: ".")
    return p.count == 4 && p[0] == "172" && (16...31).contains(Int(p[1]) ?? 0)
}
func lanAddress(_ ips: [String]) -> String {
    // 二维码必须优先展示可广播的实体 LAN 地址，不能被 utun/VPN 的 10.x 地址抢占。
    let lan = ipv4Interfaces().filter {
        ips.contains($0.address) && $0.flags & UInt32(IFF_BROADCAST) != 0 && $0.flags & UInt32(IFF_POINTOPOINT) == 0
    }.sorted { a, b in
        let rank: (String) -> Int = { $0.hasPrefix("en") ? 0 : $0.hasPrefix("bridge") ? 1 : 2 }
        let x = rank(a.name), y = rank(b.name)
        return x == y ? a.name < b.name : x < y
    }.map(\.address)
    return lan.first(where: isPrivateIPv4) ?? lan.first { $0.hasPrefix("169.254.") }
        ?? ips.first(where: isPrivateIPv4) ?? ips.first { $0.hasPrefix("169.254.") } ?? "127.0.0.1"
}
