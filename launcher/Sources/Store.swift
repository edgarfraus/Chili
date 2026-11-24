import Foundation
import Security

/// A saved Proxmox server. Secrets live in the Keychain, never in preferences.
struct ServerProfile: Identifiable, Codable, Hashable {
    enum AuthMethod: String, Codable, CaseIterable, Identifiable {
        case password, token
        var id: String { rawValue }
    }

    var id = UUID()
    var name = ""
    var host = ""
    var port = 8006
    var authMethod = AuthMethod.password
    var username = "root"
    var realm = "pam"
    var tokenID = ""            // "user@realm!name"
    var rememberSecret = true
    /// Hostname of a Cloudflare Tunnel TCP service for spiceproxy (port 3128), when the server is only
    /// reachable through the tunnel. Empty: SPICE goes to host:3128 directly.
    var spiceTunnelHost = ""
    /// Client ID of a Cloudflare Access service token for the Proxmox hostname (API and web consoles);
    /// the secret is in the Keychain (`accessAccount`).
    var accessClientId = ""
    /// Send that service token to the SPICE tunnel hostname too (when it is behind Access as well).
    /// The tunnel and Access otherwise work independently of each other.
    var spiceTunnelUsesAccess = true

    var title: String { name.isEmpty ? host : name }
    var fullUsername: String { username.contains("@") ? username : "\(username)@\(realm)" }
    /// Keychain account of the Cloudflare Access client secret.
    var accessAccount: String { id.uuidString + ".access" }
}

extension ServerProfile {
    /// Profiles saved by older versions lack the newer keys: use the defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ServerProfile()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? d.authMethod
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? d.username
        realm = try c.decodeIfPresent(String.self, forKey: .realm) ?? d.realm
        tokenID = try c.decodeIfPresent(String.self, forKey: .tokenID) ?? d.tokenID
        rememberSecret = try c.decodeIfPresent(Bool.self, forKey: .rememberSecret) ?? d.rememberSecret
        spiceTunnelHost = try c.decodeIfPresent(String.self, forKey: .spiceTunnelHost) ?? d.spiceTunnelHost
        accessClientId = try c.decodeIfPresent(String.self, forKey: .accessClientId) ?? d.accessClientId
        spiceTunnelUsesAccess = try c.decodeIfPresent(Bool.self, forKey: .spiceTunnelUsesAccess) ?? d.spiceTunnelUsesAccess
    }
}

final class ProfileStore: ObservableObject {
    @Published var profiles: [ServerProfile] = [] {
        didSet { save() }
    }

    private let key = "serverProfiles"

    init() {
        if Demo.isOn {
            profiles = [Demo.profile]
            return
        }
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = decoded
        }
    }

    private func save() {
        if Demo.isOn { return }   // never overwrite the real list with demo data
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func upsert(_ profile: ServerProfile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
    }

    func delete(_ profile: ServerProfile) {
        profiles.removeAll { $0.id == profile.id }
        Keychain.delete(account: profile.id.uuidString)
        Keychain.delete(account: profile.accessAccount)
    }
}

/// Passwords and token secrets in the login Keychain.
///
/// macOS ties each item to the app that created it; for apps without an Apple
/// Developer ID that means the exact build, so after an update macOS asks once
/// for access ("Always Allow" answers it for good). To keep those prompts to a
/// minimum we read each secret at most once per launch and only write it when
/// it actually changes.
enum Keychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "Chili") + ".servers"
    private static var cache: [String: String?] = [:]

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ secret: String, account: String) {
        if case .some(.some(let current)) = cache[account], current == secret { return }
        if load(account: account) == secret { return }
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
        cache[account] = secret
    }

    static func load(account: String) -> String? {
        if let cached = cache[account] { return cached }
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        let value = status == errSecSuccess ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        // Don't cache a refused/cancelled prompt as "no password".
        if status == errSecSuccess || status == errSecItemNotFound { cache[account] = value }
        return value
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
        cache[account] = .some(nil)
    }
}
