import Foundation
import CoreFoundation

let clipboardProtocol = "xq-clipboard/2"
let clipboardLimit = 16_384
struct ClipboardSettings: Codable {
    var autoSend = true
    var receiveEnabled = true
}
public struct ClipboardPeerView: Identifiable {
    public var id: String
    public var context: String
    public var capable: Bool
    public var autoSend: Bool
    public var receiveEnabled: Bool
    public var effectiveReceive: Bool
    public var remoteAccept: Bool
    public var lastSendStatus: String
    public var lastReceiveStatus: String
    public var sentCount: Int
    public var receivedCount: Int
    public var duplicateCount: Int
    public var inflight: Bool
    public var hasPending: Bool
    public var preview: String
    public var hasReceived: Bool
    var metadata: [String: Any] {
        ["id": id, "capable": capable, "autoSend": autoSend, "receiveEnabled": receiveEnabled, "effectiveReceive": effectiveReceive,
         "remoteAccept": remoteAccept, "lastSendStatus": lastSendStatus, "lastReceiveStatus": lastReceiveStatus,
         "sentCount": sentCount, "receivedCount": receivedCount, "duplicateCount": duplicateCount, "inflight": inflight, "hasPending": hasPending]
    }
}
func clipboardBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}
func clipboardBytes(_ text: String) -> Data? {
    let bytes = Data(text.utf8)
    return (1...clipboardLimit).contains(bytes.count) && !bytes.contains(0) ? bytes : nil
}
func clipboardErrorText(_ code: String) -> String {
    switch code {
    case "CLIP_DISABLED": "接收已关闭或设备当前不可用"
    case "CLIP_STALE": "剪贴板策略已更新，请重新发送"
    case "CLIP_IO": "系统剪贴板或本地存储读写失败"
    case "CLIP_EXPIRED": "来源快照已过期或被清理，请在来源设备重新复制"
    case "CLIP_NOT_FOUND": "来源记录不存在或未向本设备授权"
    case "CLIP_BUSY": "剪贴板正在处理，请稍后再试"
    default: "文本无效或超过16KiB，未同步"
    }
}

#if DEBUG
public enum ClipboardTestConfiguration {
    public static func isValidName(_ name: String) -> Bool { PlatformClipboard.validTestName(name) }
}
#endif
