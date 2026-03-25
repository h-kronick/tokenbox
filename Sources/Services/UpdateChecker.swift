import Foundation
import os

/// Checks for app updates by comparing local git HEAD to remote.
/// Polls every 30 minutes. The repo lives at ~/.tokenbox/repo.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var updateAvailable: Bool = false

    private let logger = Logger(subsystem: "com.tokenbox.app", category: "UpdateChecker")
    private let repoPath: String
    private let remoteURL = "https://github.com/h-kronick/tokenbox.git"
    private var timer: Timer?
    private var lastRemoteSHA: String = ""
    private var dismissedSHA: String = ""  // User dismissed this version

    init() {
        self.repoPath = NSHomeDirectory() + "/.tokenbox/repo"
    }

    func startChecking() {
        // Check on launch
        Task { await check() }

        // Then every 30 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.check()
            }
        }
    }

    func stopChecking() {
        timer?.invalidate()
        timer = nil
    }

    /// Dismiss the current update notification. Won't show again until a NEW version appears.
    func dismiss() {
        dismissedSHA = lastRemoteSHA
        updateAvailable = false
    }

    private func check() async {
        do {
            let localSHA = try runGit("rev-parse", "HEAD", in: repoPath).prefix(12)
            let lsRemoteOutput = try runGit("ls-remote", remoteURL, "HEAD")
            // Output format: "<sha>\tHEAD\n"
            let remoteSHA = String(lsRemoteOutput.split(separator: "\t").first?.prefix(12) ?? "")

            guard !localSHA.isEmpty, !remoteSHA.isEmpty else { return }

            lastRemoteSHA = remoteSHA

            if String(localSHA) != remoteSHA && remoteSHA != dismissedSHA {
                updateAvailable = true
            } else {
                updateAvailable = false
            }
        } catch {
            logger.debug("Update check failed: \(error.localizedDescription)")
        }
    }

    private func runGit(_ args: String..., in directory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        if let dir = directory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // Silence stderr
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
