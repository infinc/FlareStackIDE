import Foundation
import CoreServices

final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: (_ structural: Bool, _ modified: Set<String>) -> Void
    private var pending: DispatchWorkItem?
    private var structural = false
    private var modified: Set<String> = []

    init?(path: String, handler: @escaping (_ structural: Bool, _ modified: Set<String>) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let names = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
            let content = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemInodeMetaMod)
            for i in 0..<count {
                if flags[i] & structural != 0 { watcher.structural = true }
                if flags[i] & content != 0, i < names.count { watcher.modified.insert(names[i]) }
            }
            if watcher.structural || !watcher.modified.isEmpty { watcher.schedule() }
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
            let structural = self.structural, modified = self.modified
            self.structural = false
            self.modified = []
            self.handler(structural, modified)
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
