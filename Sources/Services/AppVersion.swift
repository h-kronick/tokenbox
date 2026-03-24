import Foundation

/// Reads version info from the local git repo clone at ~/.tokenbox/repo.
/// No manual versioning — the git commit hash IS the version.
/// Checks GitHub for updates by comparing local HEAD against remote HEAD.
final class AppVersion: ObservableObject {
    /// Short git hash of the locally installed version (e.g. "282adb7")
    @Published private(set) var localHash: String = "—"
    /// Commit date of the local version
    @Published private(set) var localDate: String = "—"
    /// Whether a newer version is available on GitHub
    @Published private(set) var updateAvailable: Bool = false
    /// Short hash of the remote version (if different)
    @Published private(set) var remoteHash: String?
    /// Whether initial load has completed
    @Published private(set) var loaded: Bool = false

    private let repoPath = NSHomeDirectory() + "/.tokenbox/repo"
    private let githubAPI = "https://api.github.com/repos/h-kronick/tokenbox/commits/main"

    // Empty init — all work deferred to load()
    init() {}

    // MARK: - Load (call from .task, never from init)

    /// Loads local git version info. Safe to call from a .task modifier.
    func load() {
        guard !loaded else { return }
        let hash = runGit(["rev-parse", "--short=7", "HEAD"])
        let date = runGit(["log", "-1", "--format=%ci", "HEAD"])

        DispatchQueue.main.async {
            if let hash, !hash.isEmpty {
                self.localHash = hash
            }
            if let date, !date.isEmpty {
                self.localDate = String(date.prefix(10))
            }
            self.loaded = true
        }
    }

    // MARK: - Update Check

    /// Checks GitHub API for the latest commit on main. Lightweight, no auth needed.
    func checkForUpdate() async {
        if !loaded { load() }

        guard let url = URL(string: githubAPI) else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = json["sha"] as? String else { return }

            let remoteShort = String(sha.prefix(7))
            let fullLocalHash = runGit(["rev-parse", "HEAD"]) ?? ""

            await MainActor.run {
                if !fullLocalHash.hasPrefix(remoteShort) && !sha.hasPrefix(self.localHash) {
                    self.updateAvailable = true
                    self.remoteHash = remoteShort
                } else {
                    self.updateAvailable = false
                    self.remoteHash = nil
                }
            }
        } catch {
            // Silently fail — no network is fine
        }
    }

    /// Runs `git pull + swift build` in the background.
    func performUpdate() async -> Bool {
        let repoPath = self.repoPath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments = ["-c", "cd '\(repoPath)' && git pull origin main --ff-only && swift build 2>&1"]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice

                do {
                    try task.run()
                    task.waitUntilExit()
                    let success = task.terminationStatus == 0
                    if success {
                        let hash = self.runGit(["rev-parse", "--short=7", "HEAD"])
                        let date = self.runGit(["log", "-1", "--format=%ci", "HEAD"])
                        DispatchQueue.main.async {
                            if let hash, !hash.isEmpty { self.localHash = hash }
                            if let date, !date.isEmpty { self.localDate = String(date.prefix(10)) }
                            self.updateAvailable = false
                            self.remoteHash = nil
                        }
                    }
                    continuation.resume(returning: success)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Helpers

    private func runGit(_ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", repoPath] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
