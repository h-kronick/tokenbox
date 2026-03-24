import Foundation

/// User preferences persisted via the config table in SQLite.
struct AppConfig: Codable {
    var defaultPeriod: String = "today"
    var launchAtLogin: Bool = false
    var menuBarShowTokens: Bool = true
    var soundEnabled: Bool = false
    var soundVolume: Double = 0.5
    var animationSpeed: Double = 1.0
    var theme: String = "classicAmber"
    var jsonlScanEnabled: Bool = true
    var sharingEnabled: Bool = false
    var displayName: String = ""
}
