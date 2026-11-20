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

    var title: String { name.isEmpty ? host : name }
    var fullUsername: String { username.contains("@") ? username : "\(username)@\(realm)" }
}

final class ProfileStore: ObservableObject {
    @Published var profiles: [ServerProfile] = [] {
        didSet { save() }
    }

    private let key = "serverProfiles"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = decoded
        }
    }

    private func save() {
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
    }
}

enum Keychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "Chili") + ".servers"

    static func save(_ secret: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecValueData as String: Data(secret.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
