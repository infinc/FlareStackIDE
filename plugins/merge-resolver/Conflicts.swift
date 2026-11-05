import Foundation

struct Conflict: Equatable {
    var whole: NSRange
    var header: NSRange
    var ours: NSRange
    var base: NSRange?
    var theirs: NSRange
    var markers: [NSRange]
}

enum ConflictScan {
    private static func marker(_ line: String, _ char: Character, exact: Bool = false) -> Bool {
        guard line.count >= 7, line.prefix(7).allSatisfy({ $0 == char }) else { return false }
        let rest = line.dropFirst(7)
        if exact { return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return rest.isEmpty || rest.first == " " || rest.first == "\n" || rest.first == "\r"
    }

    static func scan(_ text: NSString) -> [Conflict] {
        var found: [Conflict] = []
        var start: NSRange?
        var baseLine: NSRange?
        var middle: NSRange?
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let content = text.substring(with: line)
            if marker(content, "<") {
                start = line
                baseLine = nil
                middle = nil
            } else if start != nil, middle == nil, baseLine == nil, marker(content, "|") {
                baseLine = line
            } else if start != nil, middle == nil, marker(content, "=", exact: true) {
                middle = line
            } else if let open = start, let mid = middle, marker(content, ">") {
                let oursEnd = baseLine?.location ?? mid.location
                let ours = NSRange(location: NSMaxRange(open), length: oursEnd - NSMaxRange(open))
                let base = baseLine.map { NSRange(location: NSMaxRange($0), length: mid.location - NSMaxRange($0)) }
                let theirs = NSRange(location: NSMaxRange(mid), length: line.location - NSMaxRange(mid))
                let markers = [open, baseLine, mid, line].compactMap { $0 }
                found.append(Conflict(whole: NSRange(location: open.location, length: NSMaxRange(line) - open.location),
                                      header: open, ours: ours, base: base, theirs: theirs, markers: markers))
                start = nil
                baseLine = nil
                middle = nil
            }
            location = NSMaxRange(line)
        }
        return found
    }

    enum Choice { case ours, theirs, both }

    static func resolution(_ conflict: Conflict, _ choice: Choice, in text: NSString) -> String {
        let ours = text.substring(with: conflict.ours)
        let theirs = text.substring(with: conflict.theirs)
        switch choice {
        case .ours: return ours
        case .theirs: return theirs
        case .both: return ours.isEmpty || ours.hasSuffix("\n") ? ours + theirs : ours + "\n" + theirs
        }
    }
}
