import Foundation

enum LineEnding: String, CaseIterable {
    case lf = "LF", crlf = "CRLF", cr = "CR"

    var separator: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    var title: String {
        switch self {
        case .lf: return "LF（macOS・Linux）"
        case .crlf: return "CRLF（Windows）"
        case .cr: return "CR（古い Mac）"
        }
    }
}

struct TextEncoding: Equatable {
    let id: String
    let title: String
    let short: String
    let encoding: String.Encoding
    let bom: [UInt8]

    static func == (a: TextEncoding, b: TextEncoding) -> Bool { a.id == b.id }

    private static func cf(_ value: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
    }

    static let utf8 = TextEncoding(id: "utf-8", title: "UTF-8", short: "UTF-8", encoding: .utf8, bom: [])
    static let utf8BOM = TextEncoding(id: "utf-8-bom", title: "UTF-8（BOM 付き）", short: "UTF-8 BOM", encoding: .utf8, bom: [0xEF, 0xBB, 0xBF])
    static let utf16LE = TextEncoding(id: "utf-16le", title: "UTF-16 LE", short: "UTF-16 LE", encoding: .utf16LittleEndian, bom: [0xFF, 0xFE])
    static let utf16BE = TextEncoding(id: "utf-16be", title: "UTF-16 BE", short: "UTF-16 BE", encoding: .utf16BigEndian, bom: [0xFE, 0xFF])
    static let shiftJIS = TextEncoding(id: "shift_jis", title: "Shift_JIS", short: "Shift_JIS", encoding: cf(.dosJapanese), bom: [])
    static let eucJP = TextEncoding(id: "euc-jp", title: "EUC-JP", short: "EUC-JP", encoding: .japaneseEUC, bom: [])
    static let iso2022JP = TextEncoding(id: "iso-2022-jp", title: "ISO-2022-JP（JIS）", short: "JIS", encoding: .iso2022JP, bom: [])
    static let latin1 = TextEncoding(id: "iso-8859-1", title: "ISO-8859-1（Latin-1）", short: "Latin-1", encoding: .isoLatin1, bom: [])

    static let all: [TextEncoding] = [utf8, utf8BOM, utf16LE, utf16BE, shiftJIS, eucJP, iso2022JP, latin1]
}

struct TextFormat: Equatable {
    var encoding = TextEncoding.utf8
    var lineEnding = LineEnding.lf

    var label: String { "\(encoding.short) · \(lineEnding.rawValue)" }
}

enum TextFile {
    static func failure(_ message: String) -> Error {
        NSError(domain: appName, code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func starts(_ data: Data, with bytes: [UInt8]) -> Bool {
        !bytes.isEmpty && data.count >= bytes.count && data.prefix(bytes.count).elementsEqual(bytes)
    }

    static func isBinary(_ data: Data) -> Bool {
        guard !starts(data, with: TextEncoding.utf16LE.bom), !starts(data, with: TextEncoding.utf16BE.bom) else { return false }
        return data.prefix(8192).contains(0)
    }

    static func decode(_ data: Data, as encoding: TextEncoding) -> String? {
        var body = data
        if starts(data, with: encoding.bom) { body = data.dropFirst(encoding.bom.count) }
        return String(data: body, encoding: encoding.encoding)
    }

    static func detect(_ data: Data) -> (text: String, encoding: TextEncoding)? {
        for encoding in [TextEncoding.utf8BOM, .utf16LE, .utf16BE] where starts(data, with: encoding.bom) {
            if let text = decode(data, as: encoding) { return (text, encoding) }
        }
        guard !isBinary(data) else { return nil }
        if hasJISEscape(data), data.allSatisfy({ $0 < 0x80 }), let text = decode(data, as: .iso2022JP) { return (text, .iso2022JP) }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        let sjis = decode(data, as: .shiftJIS), euc = decode(data, as: .eucJP)
        if let sjis, let euc {
            let sjisLead = data.contains { (0x81...0x9F).contains($0) && $0 != 0x8E && $0 != 0x8F }
            return sjisLead ? (sjis, .shiftJIS) : (euc, .eucJP)
        }
        if let sjis { return (sjis, .shiftJIS) }
        if let euc { return (euc, .eucJP) }
        return nil
    }

    private static func hasJISEscape(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(65536))
        guard bytes.count >= 3 else { return false }
        for i in 0..<(bytes.count - 2) where bytes[i] == 0x1B && bytes[i + 1] == 0x24 && (bytes[i + 2] == 0x42 || bytes[i + 2] == 0x40) {
            return true
        }
        return false
    }

    static func lineEnding(of text: String) -> LineEnding {
        var crlf = 0, cr = 0, lf = 0
        var previousCR = false
        for byte in text.utf8 {
            if byte == 0x0A {
                if previousCR { crlf += 1; cr -= 1 } else { lf += 1 }
            } else if byte == 0x0D {
                cr += 1
            }
            previousCR = byte == 0x0D
        }
        if crlf > 0, lf == 0, cr == 0 { return .crlf }
        if cr > 0, lf == 0, crlf == 0 { return .cr }
        return .lf
    }

    static func normalize(_ text: String, from ending: LineEnding) -> String {
        ending == .lf ? text : text.replacingOccurrences(of: ending.separator, with: "\n")
    }

    static func read(_ data: Data, encoding: TextEncoding? = nil) -> (text: String, format: TextFormat)? {
        let decoded: (text: String, encoding: TextEncoding)?
        if let encoding {
            decoded = decode(data, as: encoding).map { ($0, encoding) }
        } else {
            decoded = detect(data)
        }
        guard let decoded else { return nil }
        let ending = lineEnding(of: decoded.text)
        return (normalize(decoded.text, from: ending), TextFormat(encoding: decoded.encoding, lineEnding: ending))
    }

    static func read(_ url: URL, encoding: TextEncoding? = nil) -> (text: String, format: TextFormat)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return read(data, encoding: encoding)
    }

    static func encode(_ text: String, format: TextFormat) throws -> Data {
        let body = format.lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: format.lineEnding.separator)
        guard let encoded = body.data(using: format.encoding.encoding, allowLossyConversion: false) else {
            throw failure("\(format.encoding.title) では保存できない文字が含まれています。")
        }
        return Data(format.encoding.bom) + encoded
    }

    @discardableResult
    static func write(_ text: String, to url: URL, format: TextFormat, atomically: Bool) throws -> Data {
        let data = try encode(text, format: format)
        try data.write(to: url, options: atomically ? .atomic : [])
        return data
    }
}
