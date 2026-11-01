import Foundation
import Security

/// Guarda a chave de acesso do servidor no Keychain do iPhone.
enum Keychain {
    private static let servico = Bundle.main.bundleIdentifier ?? "hermes-voice"

    private static func base(_ conta: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servico,
            kSecAttrAccount as String: conta,
        ]
    }

    static func guardar(_ valor: String, conta: String) {
        SecItemDelete(base(conta) as CFDictionary)
        guard !valor.isEmpty else { return }
        var item = base(conta)
        item[kSecValueData as String] = Data(valor.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func ler(conta: String) -> String? {
        var consulta = base(conta)
        consulta[kSecReturnData as String] = true
        consulta[kSecMatchLimit as String] = kSecMatchLimitOne
        var resultado: AnyObject?
        guard SecItemCopyMatching(consulta as CFDictionary, &resultado) == errSecSuccess,
              let dados = resultado as? Data
        else { return nil }
        return String(data: dados, encoding: .utf8)
    }
}
