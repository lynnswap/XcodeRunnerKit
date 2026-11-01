import CryptoKit
import Foundation
import Security

/// A secret that the host keeps for one installation, such as GitHub credentials or a pairing key.
protocol SecretStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}

/// A generic password in the login keychain, scoped to one host installation.
struct KeychainSecretStore: SecretStore {
    private let service: String
    private let account: String

    init(service: String, hostRoot: URL, name: String) {
        self.service = service
        account = SHA256.hash(data: Data(hostRoot.standardizedFileURL.path(percentEncoded: false).utf8))
            .map { String(format: "%02x", $0) }.joined() + "." + name
    }

    static func githubCredentials(hostRoot: URL) -> Self {
        Self(service: "lynnpd.xcodehomerunner.github", hostRoot: hostRoot, name: "credentials")
    }

    /// The host that manages this Mac.
    static func managingHost(hostRoot: URL) -> Self {
        Self(service: "lynnpd.xcodehomerunner.pairing", hostRoot: hostRoot, name: "managing-host")
    }

    /// The Macs that this host manages.
    static func managedMacs(hostRoot: URL) -> Self {
        Self(service: "lynnpd.xcodehomerunner.pairing", hostRoot: hostRoot, name: "managed-macs")
    }

    func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The Keychain item has no data."])
        }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData] = data
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private var baseQuery: [CFString: Any] {
        // The host ships without a provisioning profile for data-protection keychain access groups.
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
