import Foundation

/// FSEvents-based watcher for Claude Code JSONL session logs.
/// Watches ~/.claude/projects/ for new/modified JSONL files,
/// parses new lines, and writes token events to the database.
final class JSONLWatcher {

    private let db: Database
    private var stream: FSEventStreamRef?
    private var fileOffsets: [String: UInt64] = [:]
    private let watchPath: String
    private let queue = DispatchQueue(label: "com.tokenbox.jsonlwatcher", qos: .utility)
    private var initialScanComplete = false

    /// Callback when new token events are ingested into the DB (completed events only)
    var onEventsIngested: (([TokenEvent]) -> Void)?

    /// Callback for ALL events including intermediates — drives real-time display.
    /// Only fires AFTER the initial scan is complete (not during backfill).
    var onDisplayEvent: ((TokenEvent) -> Void)?

    init(db: Database, watchPath: String? = nil) {
        self.db = db
        self.watchPath = watchPath ?? Self.defaultWatchPath
    }

    static var defaultWatchPath: String {
        NSHomeDirectory() + "/.claude/projects"
    }

    // MARK: - Start / Stop

    func start() {
        guard stream == nil else { return }

        // Initial scan
        queue.async { [weak self] in
            self?.scanExistingFiles()
        }

        // Set up FSEvents stream
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let paths = [watchPath] as CFArray
        stream = FSEventStreamCreate(
            nil,
            { (_, info, numEvents, eventPaths, eventFlags, _) in
                guard let info = info else { return }
                let watcher = Unmanaged<JSONLWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
                for i in 0..<numEvents {
                    let flags = eventFlags[i]
                    // Only process file modifications
                    if flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 {
                        watcher.handleFileChange(paths[i])
                    }
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,  // 1 second latency (batch changes)
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

    // MARK: - Scanning

    /// Scan all existing JSONL files on startup for backfill.
    /// Display events are suppressed during this scan to prevent delta inflation.
    private func scanExistingFiles() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: watchPath) else {
            initialScanComplete = true
            return
        }

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: watchPath),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            initialScanComplete = true
            return
        }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "jsonl" {
                processFile(fileURL.path)
            }
        }
        initialScanComplete = true
    }

    /// Handle a file change event from FSEvents.
    private func handleFileChange(_ path: String) {
        guard path.hasSuffix(".jsonl") else { return }
        queue.async { [weak self] in
            self?.processFile(path)
        }
    }

    /// Process a JSONL file — parse new lines from the last known offset.
    /// Complete events are inserted into DB. All events are emitted for real-time display.
    private func processFile(_ path: String) {
        let offset = fileOffsets[path] ?? 0
        let (events, newOffset) = JSONLParser.parseNewLines(at: path, fromOffset: offset)
        fileOffsets[path] = newOffset

        guard !events.isEmpty else { return }

        var inserted: [TokenEvent] = []
        for (event, isComplete) in events {
            // Emit events for real-time display — only after initial scan
            if initialScanComplete {
                onDisplayEvent?(event)
            }

            // Only insert completed events into DB for accurate totals
            if isComplete {
                do {
                    if let rowId = try db.insertTokenEvent(event) {
                        var e = event
                        e.id = rowId
                        inserted.append(e)
                    }
                } catch {
                    continue
                }
            }
        }

        if !inserted.isEmpty {
            onEventsIngested?(inserted)
        }
    }

    deinit {
        stop()
    }
}
