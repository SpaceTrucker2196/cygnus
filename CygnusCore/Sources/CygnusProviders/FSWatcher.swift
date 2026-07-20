import Foundation
import CoreServices

// Recursive filesystem watcher over FSEvents. Events are only a hint
// that something changed — the manifest diff remains the
// authoritative change signal, so missed or coalesced events can
// never corrupt the graph.

public final class FSWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "io.river.cygnus.fswatcher")
    private let onChange: @Sendable () -> Void
    private let debounce: TimeInterval
    private var pending: DispatchWorkItem?

    public init(roots: [URL], debounce: TimeInterval = 0.5,
                onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        self.debounce = debounce

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))

        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit { stop() }
}
