import AppKit

enum LineIndex {
    private final class Entry {
        var starts: [Int]
        var length: Int
        init(_ starts: [Int], length: Int) { self.starts = starts; self.length = length }
    }

    private static let cache = NSMapTable<NSTextStorage, Entry>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private static var observer: NSObjectProtocol?

    static func starts(_ text: NSString) -> [Int] { [0] + breaks(text, in: NSRange(location: 0, length: text.length)) }

    private static func breaks(_ text: NSString, in range: NSRange) -> [Int] {
        var result: [Int] = []
        let chunk = 4096
        var buffer = [unichar](repeating: 0, count: chunk)
        var base = range.location
        let end = NSMaxRange(range)
        buffer.withUnsafeMutableBufferPointer { ptr in
            while base < end {
                let count = min(chunk, end - base)
                text.getCharacters(ptr.baseAddress!, range: NSRange(location: base, length: count))
                for i in 0..<count where ptr[i] == 10 { result.append(base + i + 1) }
                base += count
            }
        }
        return result
    }

    static func starts(of textView: NSTextView) -> [Int] {
        guard let storage = textView.textStorage else { return [0] }
        return starts(of: storage)
    }

    static func starts(of storage: NSTextStorage) -> [Int] {
        if let entry = cache.object(forKey: storage), entry.length == storage.length { return entry.starts }
        observe()
        let result = starts(storage.string as NSString)
        cache.setObject(Entry(result, length: storage.length), forKey: storage)
        return result
    }

    static func line(of location: Int, in starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    static func position(of offset: Int, in text: NSString) -> (line: Int, character: Int) {
        let offset = min(max(offset, 0), text.length)
        let found = breaks(text, in: NSRange(location: 0, length: offset))
        return (found.count, offset - (found.last ?? 0))
    }

    private static func observe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.willProcessEditingNotification, object: nil, queue: nil) { note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters),
                  let entry = cache.object(forKey: storage) else { return }
            let range = storage.editedRange, delta = storage.changeInLength
            guard entry.length == storage.length - delta, range.location != NSNotFound, NSMaxRange(range) <= storage.length else {
                cache.removeObject(forKey: storage)
                return
            }
            let oldEnd = NSMaxRange(range) - delta
            let first = line(of: range.location, in: entry.starts) + 1
            var last = first
            while last < entry.starts.count, entry.starts[last] <= oldEnd { last += 1 }
            let added = breaks(storage.string as NSString, in: range)
            entry.starts.replaceSubrange(first..<last, with: added)
            if delta != 0 {
                for i in (first + added.count)..<entry.starts.count { entry.starts[i] += delta }
            }
            entry.length = storage.length
        }
    }
}
