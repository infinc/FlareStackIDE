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

if args.first == "--sign" {
    guard let path = args.dropFirst().first, let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
        fail("使い方: swift tools/manifest.swift --sign <ファイル>")
    }
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        warn("署名鍵 \(keyPath) がないため \(path) に署名しません")
        exit(0)
    }
    let signature = try! key.signature(for: data)
    try! Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: path + ".sig"))
    exit(0)
}

guard let rootArg = args.first else { fail("使い方: swift tools/manifest.swift <リポジトリのルート> | --keygen | --sign <ファイル>") }
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

let lockURL = plugins.appendingPathComponent("abi.lock")
if let module = try? Data(contentsOf: root.appendingPathComponent("build/module/FlareStackIDE.swiftmodule")) {
    let current = "\(apiVersion) \(sha256(module))"
    let locked = (try? String(contentsOf: lockURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let locked, locked != current, locked.hasPrefix("\(apiVersion) ") {
        warn("本体のプラグイン向けの型が変わりました。公開済みのプラグインが落ちないよう Sources/NativePlugins.swift の apiVersion を上げてください（意図した互換なら plugins/abi.lock を消して再ビルド）")
    } else if locked != current {
        try! (current + "\n").write(to: lockURL, atomically: true, encoding: .utf8)
    }
}

func json(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

func inline(_ array: [Any]) -> String { "[" + array.map(json).joined(separator: ", ") + "]" }

func sign(_ data: Data, to url: URL) {
    guard let signer else { return }
    if let existing = try? Data(contentsOf: url), let raw = Data(base64Encoded: existing),
       signer.publicKey.isValidSignature(raw, for: data) { return }
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
    let updated = manifestText(text, hashes: hashes, native: files.contains("plugin.dylib") && object["abi"] as? String != "c")
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
    if let category = m["category"] as? String { fields.append("    \"category\": \(json(category))") }
    if let permissions = m["permissions"] as? [Any], !permissions.isEmpty { fields.append("    \"permissions\": \(inline(permissions))") }
    if let api = m["apiVersion"] as? Int { fields.append("    \"apiVersion\": \(api)") }
    if let abi = m["abi"] as? String { fields.append("    \"abi\": \(json(abi))") }
    if let host = m["hostAPI"] as? Int { fields.append("    \"hostAPI\": \(host)") }
    entries.append("  {\n" + fields.joined(separator: ",\n") + "\n  }")
}
let indexText = "[\n" + entries.joined(separator: ",\n") + "\n]\n"
try! indexText.write(to: indexURL, atomically: true, encoding: .utf8)
sign(Data(indexText.utf8), to: plugins.appendingPathComponent("index.sig"))
print(signer == nil ? "manifest: \(manifests.count) 件（署名なし）" : "manifest: \(manifests.count) 件に署名")

func git(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

let generated: Set<String> = ["plugin.dylib", "plugin.json", "plugin.sig"]
var changedPlugins: Set<String> = []
for line in (git(["status", "--porcelain", "-z", "--", "plugins"]) ?? "").split(separator: "\0") where line.count > 3 {
    let parts = line.dropFirst(3).split(separator: "/")
    guard parts.count >= 3, parts[0] == "plugins", !generated.contains(String(parts.last!)) else { continue }
    changedPlugins.insert(String(parts[1]))
}
for id in changedPlugins.sorted() {
    guard let current = manifests[id]?["version"] as? String,
          let committed = git(["show", "HEAD:plugins/\(id)/plugin.json"]),
          let object = try? JSONSerialization.jsonObject(with: Data(committed.utf8)) as? [String: Any],
          object["version"] as? String == current else { continue }
    warn("\(id) を変更しましたが version が \(current) のままです（plugin.json の version を上げ、README.md の更新履歴に追記してください）")
}

let lookbehind = try! NSRegularExpression(pattern: #"\(\?<[=!]"#)
for (id, manifest) in manifests.sorted(by: { $0.key < $1.key }) {
    for file in manifest["files"] as? [String] ?? ["main.js"] where file.hasSuffix(".js") && !file.hasSuffix(".min.js") {
        guard let text = try? String(contentsOf: plugins.appendingPathComponent("\(id)/\(file)"), encoding: .utf8) else { continue }
        for (number, line) in text.components(separatedBy: "\n").enumerated()
        where lookbehind.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            warn("\(id)/\(file):\(number + 1) で正規表現の後読みを使っています（macOS 13.3 未満の JavaScriptCore で動きません）")
        }
    }
}

for id in folders {
    let folder = plugins.appendingPathComponent(id)
    for file in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() where file.hasSuffix(".swift") {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { continue }
        for (number, line) in text.components(separatedBy: "\n").enumerated() where line.contains("Notification.Name(\"FlareStackIDE.") {
            warn("\(id)/\(file):\(number + 1) で通知名を直接書いています（PluginKit/PluginEvents.swift の PluginEvent に足してください）")
        }
    }
}
