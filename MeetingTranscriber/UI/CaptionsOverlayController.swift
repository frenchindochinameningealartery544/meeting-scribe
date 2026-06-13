import AppKit
import SwiftUI

/// A borderless, click-through panel pinned to the bottom-centre of the screen
/// that floats above every other window (including full-screen meeting apps) and
/// shows the live translated captions. Shown while a live-translation session is
/// running, hidden when it stops.
@MainActor
final class CaptionsOverlayController {
    static let shared = CaptionsOverlayController()
    private var panel: NSPanel?

    private static let width: CGFloat = 900
    private static let height: CGFloat = 180

    func show(appState: AppState) {
        if panel == nil { build(appState: appState) }
        reposition()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func build(appState: AppState) {
        let hosting = NSHostingView(rootView: CaptionsOverlay().environment(appState))
        hosting.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true          // clicks pass through to the meeting
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        self.panel = panel
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - Self.width / 2
        let y = visible.minY + 90
        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: Self.height), display: true)
    }
}
