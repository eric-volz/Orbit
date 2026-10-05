import Foundation
import Security

/// Secret storage. API keys live only here, never in UserDefaults, files or logs.
protocol SecretStoring: Sendable {
    func secret(for account: String) throws -> String?
    /// Stores the secret; nil or empty deletes it.
    func setSecret(_ secret: String?, for account: String) throws
}

enum SecretAccount {
    static let anthropicAPIKey = "anthropic-api-key"
    static let openAICompatibleAPIKey = "openai-compatible-api-key"

    /// Keychain account of the provider's API key. Claude Code uses no key (its own
    /// sign-in); its account name is never read or written.
    static func apiKey(for kind: ProviderKind) -> String {
        switch kind {
        case .anthropic: anthropicAPIKey
        case .openAICompatible: openAICompatibleAPIKey
        case .claudeCode: "claude-code-no-key"
        }
    }
}

enum KeychainError: Error, Hashable {
    case unexpectedStatus(OSStatus)
    case invalidData
}

/// Generic-password items in the login keychain.
struct KeychainStore: SecretStoring {
    var service: String

    init(service: String = "\(AppPaths.bundleIdentifier).credentials") {
        self.service = service
    }

    func secret(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func setSecret(_ secret: String?, for account: String) throws {
        let trimmed = secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
            return
        }
        let data = Data(trimmed.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = baseQuery(account: account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Orbit: \(account)"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// In-memory secrets for tests and DEBUG overrides.
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]

    init(_ secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    func secret(for account: String) throws -> String? {
        lock.withLock { secrets[account] }
    }

    func setSecret(_ secret: String?, for account: String) throws {
        lock.withLock {
            let trimmed = secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            secrets[account] = trimmed.isEmpty ? nil : trimmed
        }
    }
}
