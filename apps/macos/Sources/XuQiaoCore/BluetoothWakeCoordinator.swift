import Foundation
import CoreBluetooth
import CryptoKit
import OSLog

/// 只在 PairingServer 的私有串行队列使用；蓝牙身份仅为本次传输句柄，认证身份始终来自既有信任。
final class BluetoothWakeCoordinator: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let service = CBUUID(string: "0f9e089b-a5fa-40cc-9036-431b5f8e277b")
    private static let control = CBUUID(string: "22c41c6d-b782-4193-9f15-d07ceb2ea1a8")
    private struct Target: Equatable {
        let id: String
        let generation: String
        let tokenHash: String
        let key: Data
    }
    private enum Phase { case connecting, service, characteristic, challenge, client, server, authenticated, wake, cancelled }
    private final class Session {
        let peripheral: CBPeripheral
        var phase = Phase.connecting
        var characteristic: CBCharacteristic?
        var target: Target?
        var nonce = Data()
        var sequence: UInt16 = 0
        var pendingWake = false
        var deadline: DispatchWorkItem?
        init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }
    }
    private let logger = Logger(subsystem: "com.chenguangyao.xuqiao.mac", category: "BluetoothWake")
    private let queue: DispatchQueue
    private let changed: () -> Void
    private var central: CBCentralManager?
    private var targets: [String: Target] = [:]
    private var sessions: [UUID: Session] = [:]
    private var recentNonces: [String: [Data]] = [:]
    private var cooldowns: [UUID: Date] = [:]
    private var retry: DispatchWorkItem?
    private var scanDeadline: DispatchWorkItem?
    private var retryDelay: Double = 1
    private var active = false
    private var epoch = UUID()
    private(set) var status = "蓝牙辅助未启用"
    static var currentAuthorization: BluetoothWakeAuthorization { authorization(CBManager.authorization) }
    var authorization: BluetoothWakeAuthorization { Self.currentAuthorization }
    var hardware: BluetoothWakeHardware {
        guard authorization == .allowed else { return .unavailable }
        return Self.hardware(central?.state)
    }
    var authenticatedPeers: Int { sessions.values.filter { $0.phase == .authenticated || $0.phase == .wake }.count }

    init(queue: DispatchQueue, changed: @escaping () -> Void) { self.queue = queue; self.changed = changed }

    /// lastSeen 不参与比较，避免 LAN 心跳导致密钥派生、重连或读取钥匙串。
    func update(macID: String, peers: [StoredPeer]) {
        dispatchPrecondition(condition: .onQueue(queue))
        var revised: [String: Target] = [:]
        for peer in peers where !peer.paused {
            let generation = peer.clipboardTrustGeneration ?? "legacy"
            if let old = targets[peer.id], old.generation == generation,
               old.tokenHash == peer.tokenHash {
                revised[peer.id] = old
            } else if let key = Self.deriveKey(macID: macID, phoneID: peer.id, tokenHash: peer.tokenHash) {
                revised[peer.id] = Target(id: peer.id, generation: generation, tokenHash: peer.tokenHash, key: key)
            }
        }
        guard !active || targets != revised else { return }
        let previous = targets; targets = revised; active = true
        for session in Array(sessions.values) {
            if session.target.map({ revised[$0.id] != $0 }) ?? true { cancel(session) }
        }
        recentNonces = recentNonces.filter { previous[$0.key] == revised[$0.key] }
        if targets.isEmpty { stopConnections() }
        refreshAuthorization()
    }
    /// 以系统当前授权为准；更新签名后可能回到未决定，不能被旧申请标记永久挡住。
    func refreshAuthorization() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active else { return }
        if central == nil, Self.shouldCreateManager(authorization: authorization, hasTargets: !targets.isEmpty, manual: false) { createManager() }
        updateAvailability()
    }
    /// 返回 true 时由界面打开公开的系统设置入口，不尝试重置 TCC。
    func requestAuthorization() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active else { return false }
        if central == nil, Self.shouldCreateManager(authorization: authorization, hasTargets: !targets.isEmpty, manual: true) {
            createManager(); updateAvailability(); return false
        }
        return true
    }
    static func shouldCreateManager(authorization: BluetoothWakeAuthorization, hasTargets: Bool, manual: Bool) -> Bool {
        authorization == .allowed || (authorization == .notDetermined && (manual || hasTargets))
    }
    private func createManager() {
        central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    static func authorization(_ value: CBManagerAuthorization) -> BluetoothWakeAuthorization {
        switch value {
        case .notDetermined: return .notDetermined
        case .allowedAlways: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }
    static func hardware(_ value: CBManagerState?) -> BluetoothWakeHardware {
        switch value {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .unsupported: return .unsupported
        case .resetting: return .resetting
        case .unauthorized: return .unavailable
        default: return .unknown
        }
    }
    private func updateAvailability() {
        switch authorization {
        case .notDetermined: setStatus(central == nil ? "尚未授权，点击按钮可申请蓝牙权限" : "等待系统蓝牙授权；如未出现弹窗，请在系统设置中检查")
        case .denied: stopConnections(); setStatus("蓝牙权限已拒绝，局域网连接与同步仍可使用")
        case .restricted: stopConnections(); setStatus("蓝牙权限受系统限制，局域网连接与同步仍可使用")
        case .unknown: stopConnections(); setStatus("无法确认蓝牙权限，局域网连接与同步仍可使用")
        case .allowed:
            switch hardware {
            case .poweredOn:
                if targets.isEmpty { setStatus("已授权；配对并允许连接后启用蓝牙辅助") }
                else { discover() }
            case .poweredOff: setStatus("蓝牙已关闭，局域网连接与同步仍可使用")
            case .unsupported: setStatus("系统不支持蓝牙辅助，局域网连接与同步仍可使用")
            default: setStatus("正在检查蓝牙硬件状态")
            }
        }
        changed()
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        active = false; targets.removeAll(); recentNonces.removeAll(); stopHardware(); setStatus("蓝牙辅助已停止")
    }
    private func stopHardware() {
        stopConnections(); central?.delegate = nil; central = nil
    }
    private func stopConnections() {
        epoch = UUID(); retry?.cancel(); retry = nil; scanDeadline?.cancel(); scanDeadline = nil
        if central?.isScanning == true { central?.stopScan() }
        for session in sessions.values { session.deadline?.cancel(); session.target = nil; session.nonce.removeAll(); session.peripheral.delegate = nil; central?.cancelPeripheralConnection(session.peripheral) }
        sessions.removeAll(); cooldowns.removeAll()
    }
    /// 诊断只记录固定事件与数量；不包含设备ID、蓝牙句柄、报文、凭据或原始错误。
    private func event(_ name: String) { logger.notice("BLE event=\(name, privacy: .public) authenticated=\(self.authenticatedPeers)") }
    func lanAuthenticated() { event("lan_tls_authenticated") }
    private func setStatus(_ value: String) { if status != value { status = value; changed() } }
    private func live(_ central: CBCentralManager) -> Bool { active && authorization == .allowed && self.central === central && !targets.isEmpty }
    private func current(_ peripheral: CBPeripheral) -> Session? {
        guard active, authorization == .allowed, central?.state == .poweredOn, let session = sessions[peripheral.identifier], session.peripheral === peripheral, session.phase != .cancelled,
              session.target.map({ targets[$0.id] == $0 }) ?? true else { return nil }
        return session
    }
    /// 扫描有固定服务过滤与窗口；已认证目标保持系统连接，不主动制造断连/重连业务。
    private func discover() {
        guard active, authorization == .allowed, !targets.isEmpty, let central, central.state == .poweredOn else { return }
        let bound = Set(sessions.values.compactMap { $0.phase == .cancelled ? nil : $0.target?.id })
        guard bound.count < targets.count, sessions.count < 4 else { central.stopScan(); return }
        guard !central.isScanning, retry == nil else { return }
        central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        setStatus(authenticatedPeers > 0 ? "蓝牙辅助已认证，正在发现其他目标" : "正在发现受信任蓝牙目标")
        let expected = epoch
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.epoch == expected else { return }
            self.scanDeadline = nil; self.central?.stopScan(); self.scheduleDiscovery()
        }
        scanDeadline = work; queue.asyncAfter(deadline: .now() + 10, execute: work)
    }
    private func scheduleDiscovery() {
        guard active, authorization == .allowed, !targets.isEmpty, retry == nil, central?.state == .poweredOn else { return }
        let expected = epoch
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.epoch == expected else { return }
            self.retry = nil; self.discover()
        }
        retry = work; queue.asyncAfter(deadline: .now() + retryDelay, execute: work); retryDelay = min(60, retryDelay * 2)
    }
    private func timeout(_ session: Session, seconds: Double) {
        session.deadline?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.sessions[session.peripheral.identifier] === session else { return }
            self.cancel(session); self.setStatus("蓝牙辅助连接或认证超时")
        }
        session.deadline = work; queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func cancel(_ session: Session) {
        session.deadline?.cancel(); session.deadline = nil; session.phase = .cancelled
        session.target = nil; session.nonce.removeAll(); session.pendingWake = false
        event("connection_cancelled")
        cooldowns[session.peripheral.identifier] = Date().addingTimeInterval(60)
        central?.cancelPeripheralConnection(session.peripheral)
        // 留存取消中的句柄直至系统断开回调，迟到的读取不能串入新会话。
        // 取消尚未连上的 pending connect 不保证有断开回调；确认系统已断开后有界回收。
        let cleanup = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.sessions[session.peripheral.identifier] === session,
                  session.phase == .cancelled, session.peripheral.state == .disconnected else { return }
            self.sessions.removeValue(forKey: session.peripheral.identifier); session.peripheral.delegate = nil
            self.scheduleDiscovery()
        }
        session.deadline = cleanup; queue.asyncAfter(deadline: .now() + 5, execute: cleanup)
        changed()
    }
    func wake(peerID: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active, targets[peerID] != nil else { return }
        if let session = sessions.values.first(where: { $0.target?.id == peerID && ($0.phase == .authenticated || $0.phase == .wake) }) {
            if session.phase == .wake { session.pendingWake = true } else { sendWake(session) }
        } else { discover() }
    }
    private func sendWake(_ session: Session) {
        guard let target = session.target, targets[target.id] == target, session.phase == .authenticated,
              let characteristic = session.characteristic else { return }
        guard session.sequence < UInt16.max else { cancel(session); return }
        session.sequence += 1
        let seq = Data([UInt8(session.sequence >> 8), UInt8(session.sequence & 255)])
        let tag = Self.tag(target.key, prefix: "XuQiao BLE wake v1|", suffix: session.nonce + seq, count: 16)
        session.phase = .wake; timeout(session, seconds: 15); event("wake_write_requested")
        session.peripheral.writeValue(Data([1, 4]) + seq + tag, for: characteristic, type: .withResponse)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard active, self.central === central else { return }
        if central.state == .poweredOn { retry?.cancel(); retry = nil; retryDelay = 1 }
        else { stopConnections() }
        updateAvailability()
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard live(central), central.state == .poweredOn, sessions.count < 4, sessions[peripheral.identifier] == nil else { return }
        cooldowns = cooldowns.filter { $0.value > Date() }
        guard cooldowns[peripheral.identifier] == nil else { return }
        // 地址只作临时限流句柄，不作为信任身份；缓存始终有界。
        guard cooldowns.count < 64 else { return }
        event("service_discovered")
        let session = Session(peripheral); sessions[peripheral.identifier] = session; peripheral.delegate = self
        timeout(session, seconds: 30); central.connect(peripheral, options: nil)
        if sessions.count >= 4 { central.stopScan() }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard live(central), let session = current(peripheral), session.phase == .connecting else { central.cancelPeripheralConnection(peripheral); return }
        event("gatt_connected"); session.phase = .service; timeout(session, seconds: 30); peripheral.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { disconnected(central, peripheral) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { disconnected(central, peripheral) }
    private func disconnected(_ central: CBCentralManager, _ peripheral: CBPeripheral) {
        guard live(central), let session = sessions[peripheral.identifier], session.peripheral === peripheral else { return }
        session.deadline?.cancel(); session.target = nil; session.nonce.removeAll(); peripheral.delegate = nil
        sessions.removeValue(forKey: peripheral.identifier); setStatus(authenticatedPeers > 0 ? "蓝牙辅助已认证" : "蓝牙辅助已断开，等待重新发现")
        changed(); scheduleDiscovery()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let session = current(peripheral), session.phase == .service else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { cancel(session); return }
        session.phase = .characteristic; peripheral.discoverCharacteristics([Self.control], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let session = current(peripheral), session.phase == .characteristic else { return }
        guard error == nil, service.uuid == Self.service, let characteristic = service.characteristics?.first(where: { $0.uuid == Self.control }),
              characteristic.properties.contains(.read), characteristic.properties.contains(.write) else { cancel(session); return }
        session.characteristic = characteristic; session.phase = .challenge; peripheral.readValue(for: characteristic)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let session = current(peripheral), session.characteristic === characteristic else { return }
        guard error == nil, let value = characteristic.value, value.count == 20 else { cancel(session); return }
        let bytes = [UInt8](value)
        if session.phase == .challenge {
            guard Array(bytes.prefix(4)) == [1, 1, 0, 0] else { cancel(session); return }
            let nonce = Data(bytes[4..<16]), hint = Data(bytes[16..<20])
            let candidates = targets.values.filter { Self.equal(hint, Self.tag($0.key, prefix: "XuQiao BLE hint v1|", suffix: nonce, count: 4)) }
            // hint 只选键，碰撞或已见 nonce 一律拒绝；完整 server 标签验证前不绑定业务身份。
            guard candidates.count == 1, let target = candidates.first,
                  !(recentNonces[target.id] ?? []).contains(nonce), !sessions.values.contains(where: { $0 !== session && $0.target?.id == target.id && $0.phase != .cancelled }) else { cancel(session); return }
            session.target = target; session.nonce = nonce; session.phase = .client
            recentNonces[target.id] = Array(((recentNonces[target.id] ?? []) + [nonce]).suffix(64))
            peripheral.writeValue(Data([1, 2, 0, 0]) + Self.tag(target.key, prefix: "XuQiao BLE client v1|", suffix: nonce, count: 16), for: characteristic, type: .withResponse)
        } else if session.phase == .server {
            guard let target = session.target, Array(bytes.prefix(4)) == [1, 3, 0, 0],
                  Self.equal(Data(bytes[4..<20]), Self.tag(target.key, prefix: "XuQiao BLE server v1|", suffix: session.nonce, count: 16)) else { cancel(session); return }
            session.deadline?.cancel(); session.deadline = nil; session.phase = .authenticated; retryDelay = 1
            event("server_hmac_authenticated"); setStatus("蓝牙辅助已认证"); changed(); sendWake(session)
            central?.stopScan(); scanDeadline?.cancel(); scanDeadline = nil; discover()
        } else { cancel(session) }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let session = current(peripheral), session.characteristic === characteristic else { return }
        guard error == nil else { cancel(session); return }
        if session.phase == .client {
            // ATT 写回包只表示传输完成，必须再读并核验完整 server HMAC。
            session.phase = .server; peripheral.readValue(for: characteristic)
        } else if session.phase == .wake {
            event("wake_att_write_ack")
            session.deadline?.cancel(); session.deadline = nil; session.phase = .authenticated
            if session.pendingWake { session.pendingWake = false; sendWake(session) }
        } else { cancel(session) }
    }
    private static func deriveKey(macID: String, phoneID: String, tokenHash: String) -> Data? {
        guard [macID, phoneID].allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ $0 >= 32 && $0 < 127 && $0 != 124 }) }), validHex(tokenHash) else { return nil }
        let chars = Array(tokenHash.utf8)
        func digit(_ b: UInt8) -> UInt8 { b <= 57 ? b - 48 : b - 87 }
        let digest = Data(stride(from: 0, to: 64, by: 2).map { digit(chars[$0]) << 4 | digit(chars[$0 + 1]) })
        return Data(HMAC<SHA256>.authenticationCode(for: Data(("XuQiao BLE wake key v1|" + macID + "|" + phoneID).utf8), using: SymmetricKey(data: digest)))
    }
    private static func tag(_ key: Data, prefix: String, suffix: Data, count: Int) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(prefix.utf8) + suffix, using: SymmetricKey(data: key)).prefix(count))
    }
    private static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
