import CryptoKit
import Foundation

let fm = FileManager.default
let args = CommandLine.arguments.dropFirst()
let keyPath = ProcessInfo.processInfo.environment["FLARESTACK_SIGNING_KEY"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".flarestack/plugin-signing.key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("manifest: \(message)\n".utf8))
    exit(1)
}

func warn(_ message: String) { FileHandle.standardError.write(Data("manifest: \(message)\n".utf8)) }

if args.first == "--keygen" {
    guard !fm.fileExists(atPath: keyPath) else { fail("\(keyPath) は既にあります") }
    let key = Curve25519.Signing.PrivateKey()
    try? fm.createDirectory(atPath: (keyPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700])
    guard fm.createFile(atPath: keyPath, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                        attributes: [.posixPermissions: 0o600]) else { fail("\(keyPath) に書き込めません") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}

guard let rootArg = args.first else { fail("使い方: swift tools/manifest.swift <リポジトリのルート> | --keygen") }
let root = URL(fileURLWithPath: rootArg)
let plugins = root.appendingPathComponent("plugins")

let signer: Curve25519.Signing.PrivateKey? = {
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}()
if signer == nil { warn("署名鍵 \(keyPath) がないため署名しません") }

let nativeSource = (try? String(contentsOf: root.appendingPathComponent("Sources/NativePlugins.swift"), encoding: .utf8)) ?? ""
guard let apiMatch = nativeSource.range(of: #"static let apiVersion = \d+"#, options: .regularExpression),
      let apiVersion = Int(nativeSource[apiMatch].split(separator: " ").last ?? "") else { fail("apiVersion が見つかりません") }

func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func json(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

func inline(_ array: [Any]) -> String { "[" + array.map(json).joined(separator: ", ") + "]" }

func sign(_ data: Data, to url: URL) {
    guard let signer else { return }
    let signature = try! signer.signature(for: data)
    try! Data(signature.base64EncodedString().utf8).write(to: url)
}

func manifestText(_ text: String, hashes: [String: String], native: Bool) -> String {
    var lines = text.components(separatedBy: "\n")
    var skipping = false
    lines = lines.filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if skipping {
            if trimmed.hasPrefix("}") { skipping = false }
            return false
        }
        if trimmed.hasPrefix("\"apiVersion\"") { return false }
        if trimmed.hasPrefix("\"hashes\"") {
            skipping = !trimmed.contains("}")
            return false
        }
        return true
    }
    var body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard body.hasSuffix("}") else { fail("plugin.json の形式が正しくありません") }
    body.removeLast()
    body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasSuffix(",") { body.removeLast() }
    var extra: [String] = []
    if native { extra.append("  \"apiVersion\": \(apiVersion)") }
    let pairs = hashes.keys.sorted().map { "    \(json($0)): \(json(hashes[$0]!))" }
    extra.append("  \"hashes\": {\n" + pairs.joined(separator: ",\n") + "\n  }")
    return body + ",\n" + extra.joined(separator: ",\n") + "\n}\n"
}

let indexURL = plugins.appendingPathComponent("index.json")
guard let indexData = try? Data(contentsOf: indexURL),
      let index = try? JSONSerialization.jsonObject(with: indexData) as? [[String: Any]] else { fail("index.json を読めません") }
let catalogIDs = index.compactMap { $0["id"] as? String }

var entries: [String] = []
let folders = ((try? fm.contentsOfDirectory(atPath: plugins.path)) ?? []).sorted()
var manifests: [String: [String: Any]] = [:]
for id in folders {
    let folder = plugins.appendingPathComponent(id)
    let manifestURL = folder.appendingPathComponent("plugin.json")
    guard let text = try? String(contentsOf: manifestURL, encoding: .utf8),
          let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
    let files = object["files"] as? [String] ?? ["main.js"]
    var hashes: [String: String] = [:]
    for file in files {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { fail("\(id)/\(file) がありません") }
        hashes[file] = sha256(data)
    }
    let updated = manifestText(text, hashes: hashes, native: files.contains("plugin.dylib"))
    if updated != text { try! updated.write(to: manifestURL, atomically: true, encoding: .utf8) }
    sign(Data(updated.utf8), to: folder.appendingPathComponent("plugin.sig"))
    let parsed = try! JSONSerialization.jsonObject(with: Data(updated.utf8)) as! [String: Any]
    manifests[id] = parsed
}

for id in catalogIDs {
    guard let m = manifests[id] else { fail("index.json の \(id) に plugin.json がありません") }
    var fields = ["id", "name", "version", "author", "symbol", "summary"].compactMap { key in
        (m[key] as? String).map { "    \(json(key)): \(json($0))" }
    }
    fields.append("    \"fileExtensions\": \(inline(m["fileExtensions"] as? [Any] ?? []))")
    if let requires = m["requires"] as? [Any], !requires.isEmpty { fields.append("    \"requires\": \(inline(requires))") }
    if let api = m["apiVersion"] as? Int { fields.append("    \"apiVersion\": \(api)") }
    entries.append("  {\n" + fields.joined(separator: ",\n") + "\n  }")
}
let indexText = "[\n" + entries.joined(separator: ",\n") + "\n]\n"
try! indexText.write(to: indexURL, atomically: true, encoding: .utf8)
sign(Data(indexText.utf8), to: plugins.appendingPathComponent("index.sig"))
print(signer == nil ? "manifest: \(manifests.count) 件（署名なし）" : "manifest: \(manifests.count) 件に署名")
