import SwiftUI

@main
struct TokenBoxApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var dataStore = TokenDataStore()
    @StateObject private var sharingManager = SharingManager.shared
    @StateObject private var menuBarState: MenuBarState

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        let ds = TokenDataStore()
        _dataStore = StateObject(wrappedValue: ds)
        _sharingManager = StateObject(wrappedValue: SharingManager.shared)
        _menuBarState = StateObject(wrappedValue: MenuBarState(dataStore: ds))

        // Share with AppDelegate for the main window
        AppDelegate.sharedAppState = _appState
        AppDelegate.sharedDataStore = _dataStore
        AppDelegate.sharedSharingManager = _sharingManager
    }

    var body: some Scene {
        // Menu bar icon — always present
        MenuBarExtra {
            MenuBarView(state: menuBarState)
        } label: {
            MenuBarIcon(state: menuBarState)
        }
        .menuBarExtraStyle(.window)

        // Settings
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(dataStore)
                .environmentObject(sharingManager)
        }
    }
}

/// Extracts a 6-char share code from a URL.
/// Supports: tokenbox://add/XXXXXX, https://.../share/XXXXXX
private func parseShareCode(from url: URL) -> String? {
    if url.scheme == "tokenbox", url.host == "add" {
        let code = url.lastPathComponent
        if code.count == 6 { return code }
    }
    if let idx = url.pathComponents.firstIndex(of: "share"),
       idx + 1 < url.pathComponents.count {
        let code = url.pathComponents[idx + 1]
        if code.count == 6 { return code }
    }
    return nil
}

// MARK: - Custom NSWindow that accepts keyboard input

/// NSWindow subclass that always accepts key status, even with a hidden titlebar.
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    // Shared state objects set by TokenBoxApp.init
    static var sharedAppState: StateObject<AppState>!
    static var sharedDataStore: StateObject<TokenDataStore>!
    static var sharedSharingManager: StateObject<SharingManager>!

    var mainWindow: KeyableWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no Cmd-Tab entry.
        // KeyableWindow + explicit activate() calls ensure keyboard input still works.
        NSApplication.shared.setActivationPolicy(.accessory)

        // Initialize the split-flap sound engine
        // Register defaults so first launch has sound off at 50% volume
        UserDefaults.standard.register(defaults: [
            "soundEnabled": false,
            "soundVolume": 0.5
        ])
        let soundEngine = FlapSoundEngine.shared
        soundEngine.enabled = UserDefaults.standard.bool(forKey: "soundEnabled")
        soundEngine.volume = UserDefaults.standard.double(forKey: "soundVolume")
        soundEngine.setUp()

        createMainWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func createMainWindow() {
        let appState = Self.sharedAppState.wrappedValue
        let dataStore = Self.sharedDataStore.wrappedValue
        let sharingManager = Self.sharedSharingManager.wrappedValue

        let contentView = MainWindowView()
            .environmentObject(appState)
            .environmentObject(dataStore)
            .environmentObject(sharingManager)

        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "TokenBox"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isOpaque = true

        let themeRaw = UserDefaults.standard.string(forKey: "theme") ?? "classicAmber"
        let theme = SplitFlapTheme(rawValue: themeRaw) ?? .classicAmber
        window.backgroundColor = NSColor(theme.windowChrome)

        window.contentView = NSHostingView(rootView: contentView)
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)

        mainWindow = window
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return false
        }
        return true
    }
}
