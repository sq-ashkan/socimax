import AppKit
import SwiftUI

/// A floating NSPanel that stays visible even when the app loses focus.
/// Used instead of MenuBarExtra's auto-dismissing popover.
class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        level = .floating
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    /// Position the panel just below a status bar button
    func positionNear(statusBarButton button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        var x = buttonRect.midX - frame.width / 2
        // Keep within screen bounds
        x = max(screenFrame.minX + 8, min(x, screenFrame.maxX - frame.width - 8))
        let y = buttonRect.minY - frame.height - 4
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
