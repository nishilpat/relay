//
//  MenuBarPanelManager.swift
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let relayDismissPanel = Notification.Name("relayDismissPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager

    private let defaultPanelWidth: CGFloat = 560
    private let minPanelWidth: CGFloat = 420
    private let maxPanelWidth: CGFloat = 1000
    private let minPanelHeight: CGFloat = 350

    /// Tracks whether the panel has been shown before so we preserve the
    /// user's resized dimensions on subsequent open/close cycles.
    private var hasPanelBeenShownBefore: Bool = false

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .relayDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeRelayMenuBarIcon()
        // isTemplate is intentionally not set — the Relay logo uses specific
        // colors that must show through rather than being masked to monochrome.
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the Relay logo as the menu bar icon — three colored circles
    /// matching the SVG: orange (cx=7,cy=16), blue (cx=14,cy=6.5), green (cx=17,cy=16.5)
    /// in a 24×24 viewBox, scaled down to 18pt. AppKit Y-axis is flipped vs SVG.
    private func makeRelayMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let svgViewboxSize: CGFloat = 24
        let scale = iconSize / svgViewboxSize

        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let circleData: [(svgCX: CGFloat, svgCY: CGFloat, svgR: CGFloat, color: NSColor)] = [
            (7,  16,   2.2, NSColor(red: 0.949, green: 0.325, blue: 0.082, alpha: 1)), // #f25314 orange
            (14, 6.5,  2.2, NSColor(red: 0.075, green: 0.596, blue: 0.831, alpha: 1)), // #1398d4 blue
            (17, 16.5, 2.2, NSColor(red: 0.314, green: 0.937, blue: 0.553, alpha: 1)), // #50ef8d green
        ]

        for circle in circleData {
            let cx = circle.svgCX * scale
            let cy = iconSize - (circle.svgCY * scale) // flip Y: SVG top-down → AppKit bottom-up
            let r  = circle.svgR * scale

            let path = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            circle.color.setFill()
            path.fill()
        }

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        // No fixed width on the root view — the panel drives the size.
        let companionPanelView = CompanionPanelView(companionManager: companionManager)

        let hostingView = NSHostingView(rootView: companionPanelView)
        // Let the hosting view stretch to fill whatever size the panel is.
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(x: 0, y: 0, width: defaultPanelWidth, height: 600)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: defaultPanelWidth, height: 600),
            // .resizable allows edge-dragging to resize; .borderless keeps it chrome-free.
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        // Constrain resize range so content stays usable at any size.
        let maxScreenHeight = NSScreen.main?.visibleFrame.height ?? 1000
        menuBarPanel.minSize = NSSize(width: minPanelWidth, height: minPanelHeight)
        menuBarPanel.maxSize = NSSize(width: maxPanelWidth, height: maxScreenHeight)

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4
        let availableScreenHeight = (NSScreen.main?.visibleFrame.height ?? 800) - gapBelowMenuBar

        let panelSize: NSSize
        if hasPanelBeenShownBefore {
            // Preserve the dimensions the user has resized to — only update position.
            panelSize = panel.frame.size
        } else {
            // First show: default width, height fitted to SwiftUI content.
            let fittingHeight = panel.contentView?.fittingSize.height ?? 600
            let clampedHeight = min(fittingHeight, availableScreenHeight)
            panelSize = NSSize(width: defaultPanelWidth, height: clampedHeight)
            hasPanelBeenShownBefore = true
        }

        // Horizontally center beneath the status item, clamped so the panel
        // never extends off the left or right edge of the screen.
        let screenMinX = NSScreen.main?.visibleFrame.minX ?? 0
        let screenMaxX = NSScreen.main?.visibleFrame.maxX ?? 1440
        let idealOriginX = statusItemFrame.midX - (panelSize.width / 2)
        let clampedOriginX = min(max(idealOriginX, screenMinX), screenMaxX - panelSize.width)
        let panelOriginY = statusItemFrame.minY - panelSize.height - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: clampedOriginX, y: panelOriginY, width: panelSize.width, height: panelSize.height),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
