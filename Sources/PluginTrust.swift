import CryptoKit
import Foundation

enum PluginTrust {
    private static let publicKey = "k6SnwgkIZLpa0WwH1TlOxsoU1qmLRVYQOWtFNXHtSTc="
    static let signatureFile = "plugin.sig"
    private static let allowKey = "Plugins.AllowUnsigned"

    static var allowUnsigned: Bool {
        get { UserDefaults.standard.bool(forKey: allowKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowKey) }
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func isSigned(_ data: Data, signature: Data?) -> Bool {
        guard let signature, let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(raw, for: data)
    }

    static func error(_ message: String) -> Error {
        NSError(domain: appName, code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func checkManifest(_ data: Data, signature: Data?, name: String) throws {
        if isSigned(data, signature: signature) || allowUnsigned { return }
        throw error("\(name) の署名を確認できませんでした。配布元が違うか、ファイルが改ざんされています")
    }

    static func checkFile(_ file: String, data: Data, hashes: [String: String]?, name: String) throws {
        guard let hashes else {
            if allowUnsigned { return }
            throw error("\(name) の \(file) のハッシュがありません")
        }
        guard let expected = hashes[file] else { throw error("\(name) の \(file) のハッシュがありません") }
        guard expected == sha256(data) else { throw error("\(name) の \(file) が改ざんされています（ハッシュが一致しません）") }
    }

    static func verifyInstalled(_ folder: URL, info: PluginInfo, files: [String]) -> String? {
        do {
            let manifest = try Data(contentsOf: folder.appendingPathComponent("plugin.json"))
            try checkManifest(manifest, signature: try? Data(contentsOf: folder.appendingPathComponent(signatureFile)), name: info.name)
            for file in files {
                try checkFile(file, data: try Data(contentsOf: folder.appendingPathComponent(file)), hashes: info.hashes, name: info.name)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
