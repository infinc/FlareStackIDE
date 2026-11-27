import Foundation
import CoreServices

struct FileChanges {
    var structural: Set<String> = []
    var rescan = false
    var modified: Set<String> = []

    var isEmpty: Bool { structural.isEmpty && !rescan && modified.isEmpty }
}

final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: (FileChanges) -> Void
    private var pending: DispatchWorkItem?
    private var changes = FileChanges()

    init?(path: String, handler: @escaping (FileChanges) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let names = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed)
            let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
            let content = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemInodeMetaMod)
            for i in 0..<count {
                if flags[i] & rescan != 0 || i >= names.count {
                    if flags[i] & (rescan | structural) != 0 { watcher.changes.rescan = true }
                    continue
                }
                if flags[i] & structural != 0 { watcher.changes.structural.insert(names[i]) }
                if flags[i] & content != 0 { watcher.changes.modified.insert(names[i]) }
            }
            if !watcher.changes.isEmpty { watcher.schedule() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changes = self.changes
            self.changes = FileChanges()
            self.handler(changes)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func stop() {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
