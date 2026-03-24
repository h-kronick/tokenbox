import Foundation

/// FSEvents-based watcher for the live.json file written by status-relay.sh.
/// Provides near-real-time token updates for the split-flap animation.
/// Target latency: sub-second from file write to callback.
final class LiveFileWatcher {

    private var stream: FSEventStreamRef?
    private let filePath: String
    private let queue = DispatchQueue(label: "com.tokenbox.livewatcher", qos: .userInteractive)

    /// Callback when a new live event is received
    var onLiveEvent: ((LiveEvent) -> Void)?

    init(filePath: String? = nil) {
        self.filePath = filePath ?? Self.defaultPath
    }

    static var defaultPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TokenBox/live.json").path
    }

    // MARK: - Start / Stop

    func start() {
        guard stream == nil else { return }

        let dir = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Read current state if file exists
        readAndPublish()

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let paths = [dir] as CFArray
        stream = FSEventStreamCreate(
            nil,
            { (_, info, numEvents, eventPaths, eventFlags, _) in
                guard let info = info else { return }
                let watcher = Unmanaged<LiveFileWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
                for i in 0..<numEvents {
                    let path = paths[i]
                    if path.hasSuffix("live.json") {
                        watcher.readAndPublish()
                    }
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,  // 100ms latency — prioritize responsiveness
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    // MARK: - Reading

    private func readAndPublish() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return }
        guard let event = try? JSONDecoder().decode(LiveEvent.self, from: data) else { return }
        onLiveEvent?(event)
    }

    deinit {
        stop()
    }
}
