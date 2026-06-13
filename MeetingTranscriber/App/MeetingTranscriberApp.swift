import SwiftUI

@main
struct MeetingTranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state: AppState

    init() {
        // Create the single AppState explicitly and wire it into @State so we hold
        // a concrete reference here. App.init reliably runs at launch — unlike
        // applicationDidFinishLaunching and MenuBarExtra `.task`, which are flaky
        // in this menu-bar (LSUIElement) SwiftUI config. Kick off process-level
        // bootstrap (background services + interrupted-recording recovery) on the
        // captured instance — NOT via AppState.shared, which can still be nil this
        // early. bootstrap() is idempotent, so the window `.task` re-invoking it is
        // harmless.
        let appState = AppState()
        _state = State(initialValue: appState)
        Task { @MainActor in await appState.bootstrap() }
    }

    var body: some Scene {
        WindowGroup("Meeting Transcriber", id: "main") {
            RootView()
                .environment(state)
                .frame(minWidth: 960, minHeight: 620)
                .task { await state.bootstrap() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Import Audio or Video…") {
                    state.importPanelRequested.toggle()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button(state.isMicMuted ? "Unmute Microphone" : "Mute Microphone") {
                    state.setMicMuted(!state.isMicMuted)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!state.recordingState.isRecording)
            }
        }

        Settings {
            SettingsView()
                .environment(state)
        }

        MenuBarExtra {
            MenuBarMenu(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Keeps the app alive for the menu-bar extra after the main window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        MCPLocalServer.shared.start()
        NotificationManager.shared.configure()
        // Background services must come up per process launch, not on main-window
        // appearance — a menu-bar app runs windowless. `AppState.shared` is a weak
        // handle set by the App's @State initializer; it can lag this callback by a
        // runloop tick, so poll briefly until it appears. startBackgroundServices
        // is idempotent, so a later window/App.init bootstrap is harmless.
        Task { @MainActor in
            for _ in 0..<50 {
                if let app = AppState.shared {
                    app.startBackgroundServices()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Foundation.Notification) {
        // The app is frontmost here — the only reliable moment to present the
        // calendar TCC prompt. `start()` is guarded so this runs exactly once.
        CalendarMonitor.shared.start()
        // Belt-and-suspenders: also drive bootstrap whenever the app is brought to
        // front (menu-bar click, Dock), independent of the launch paths. Idempotent.
        Task { @MainActor in await AppState.shared?.bootstrap() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Foundation.Notification) {
        MCPLocalServer.shared.stop()
        CalendarMonitor.shared.stop()
    }
}
