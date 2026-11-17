import Foundation
import Security
import Network
import Darwin

private struct Authority: Codable {
    let deviceID: String
    let certificatePEM: String
    let privateKeyPEM: String
}

final class ServerIdentity {
    let deviceID: String
    let caPEM: String
    let fingerprint: String
    private let authority: Authority
    private(set) var tlsExpiresAt: Date?
    /// 在服务串行队列检查；提前一天重签叶证书，CA/deviceId/信任凭据不变。
    var needsTLSRenewal: Bool { tlsExpiresAt.map { $0.timeIntervalSinceNow <= 86_400 } ?? true }

    init(store: SecureStore) throws {
        if let existing = try store.readJSON("authority-v1", as: Authority.self) {
            authority = existing
        } else {
            let generated = try ProtectedWorkspace.perform { workspace in
                try workspace.openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca.key"])
                try workspace.protect("ca.key")
                try workspace.write("ca.cnf", """
                [req]
                distinguished_name=dn
                x509_extensions=ca
                prompt=no
                [dn]
                CN=XuQiao Device Root
                [ca]
                basicConstraints=critical,CA:TRUE,pathlen:0
                keyUsage=critical,keyCertSign,cRLSign
                subjectKeyIdentifier=hash
                authorityKeyIdentifier=keyid:always
                """)
                try workspace.openssl(["req", "-new", "-x509", "-sha256", "-days", "3650", "-key", "ca.key", "-config", "ca.cnf", "-out", "ca.pem"])
                return Authority(deviceID: UUID().uuidString.lowercased(), certificatePEM: try workspace.string("ca.pem"), privateKeyPEM: try workspace.string("ca.key"))
            }
            try store.writeJSON("authority-v1", value: generated)
            authority = generated
        }
        deviceID = authority.deviceID; caPEM = authority.certificatePEM
        let base64 = caPEM.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64), SecCertificateCreateWithData(nil, der as CFData) != nil else { throw CoreFailure("设备 CA 证书已损坏，请勿自动替换已有身份") }
        fingerprint = digest(der)
    }

    /// 临时签发覆盖当前 IPv4 的叶证书；根 CA 始终保留，IP 改变无需重新信任。
    func tlsOptions(addresses: [String]) throws -> NWProtocolTLS.Options {
        let issuedAt = Date()
        let identity: sec_identity_t = try ProtectedWorkspace.perform { workspace in
            try workspace.write("ca.pem", caPEM)
            try workspace.write("ca.key", authority.privateKeyPEM)
            try workspace.openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "leaf.key"])
            try workspace.protect("leaf.key")
            try workspace.openssl(["req", "-new", "-sha256", "-key", "leaf.key", "-subj", "/CN=XuQiao LAN", "-out", "leaf.csr"])
            let sans = addresses.enumerated().map { "IP.\($0.offset + 1)=\($0.element)" }.joined(separator: "\n")
            try workspace.write("leaf.cnf", """
            [leaf]
            basicConstraints=critical,CA:FALSE
            keyUsage=critical,digitalSignature
            extendedKeyUsage=serverAuth
            subjectKeyIdentifier=hash
            authorityKeyIdentifier=keyid,issuer
            subjectAltName=@addresses
            [addresses]
            \(sans)
            """)
            let serial = hex(try secureBytes(16))
            try workspace.openssl(["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "0x" + serial, "-days", "30", "-sha256", "-extfile", "leaf.cnf", "-extensions", "leaf", "-out", "leaf.pem"])
            // 签发后先验证链和每个 IP，避免向手机提供缺少 SAN 或不受信任的证书。
            try workspace.openssl(["verify", "-CAfile", "ca.pem", "-purpose", "sslserver", "leaf.pem"])
            func certificate(_ pem: String) throws -> SecCertificate {
                let encoded = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
                guard let der = Data(base64Encoded: encoded), let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw CoreFailure("无法解析 TLS 证书") }
                return cert
            }
            let leafCertificate = try certificate(workspace.string("leaf.pem"))
            let rootCertificate = try certificate(caPEM)
            for ip in addresses {
                var trust: SecTrust?
                guard SecTrustCreateWithCertificates([leafCertificate, rootCertificate] as CFArray, SecPolicyCreateSSL(true, ip as CFString), &trust) == errSecSuccess, let trust else { throw CoreFailure("无法创建 TLS 校验策略") }
                SecTrustSetAnchorCertificates(trust, [rootCertificate] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                var trustError: CFError?
                guard SecTrustEvaluateWithError(trust, &trustError) else { throw CoreFailure("TLS 证书链或 IP 校验失败") }
            }
            let password = hex(try secureBytes(32))
            try workspace.write("password", password)
            try workspace.openssl(["pkcs12", "-export", "-inkey", "leaf.key", "-in", "leaf.pem", "-certfile", "ca.pem", "-name", "XuQiao LAN", "-out", "leaf.p12", "-passout", "file:password"])
            try workspace.protect("leaf.p12")
            let pkcs12 = try Data(contentsOf: workspace.url("leaf.p12"))
            var items: CFArray?
            let status = SecPKCS12Import(pkcs12 as CFData, [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true] as CFDictionary, &items)
            guard status == errSecSuccess, let entry = (items as? [[String: Any]])?.first,
                  let raw = entry[kSecImportItemIdentity as String] else { throw CoreFailure("无法导入临时 TLS 身份（\(status)）") }
            let secIdentity = raw as! SecIdentity
            var importedLeaf: SecCertificate?
            guard SecIdentityCopyCertificate(secIdentity, &importedLeaf) == errSecSuccess, let importedLeaf,
                  SecCertificateCopyData(importedLeaf) as Data == SecCertificateCopyData(leafCertificate) as Data else { throw CoreFailure("TLS 身份与已验证的证书不一致") }
            // sec_identity 已自带叶证书；额外链只传根，避免重复 leaf 导致严格客户端握手失败。
            guard let identity = sec_identity_create_with_certificates(secIdentity, [rootCertificate] as CFArray) else { throw CoreFailure("无法创建 TLS 身份") }
            return identity
        }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        // 仅完整生成并校验TLS配置后推进有效期；签发耗时不能延长证书寿命。
        tlsExpiresAt = issuedAt.addingTimeInterval(30 * 86_400)
        return options
    }
}

/// openssl 只能在 0700 临时目录中运行；私钥、口令和 PKCS12 均为 0600，退出立即清除。
private final class ProtectedWorkspace {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("xuqiao-identity-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    static func perform<T>(_ action: (ProtectedWorkspace) throws -> T) throws -> T {
        let workspace = try ProtectedWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.directory) }
        return try action(workspace)
    }
    func url(_ filename: String) -> URL { directory.appendingPathComponent(filename) }
    func write(_ filename: String, _ contents: String) throws {
        let fd = open(url(filename).path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CoreFailure("无法创建受保护的证书临时文件") }
        close(fd)
        try Data(contents.utf8).write(to: url(filename))
        try protect(filename)
    }
    func protect(_ filename: String) throws { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(filename).path) }
    func string(_ filename: String) throws -> String { try String(contentsOf: url(filename), encoding: .utf8) }
    func openssl(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "umask 077; exec \"$@\"", "xuqiao-openssl", "/usr/bin/openssl"] + arguments; process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CoreFailure("TLS 证书生成或验证失败（openssl \(arguments.first ?? "")）") }
    }
}
