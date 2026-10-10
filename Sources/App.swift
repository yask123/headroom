// Headroom — what's left of your Claude and Codex week, in the menu bar.
//
//   HEADROOM_DEMO=1   sample numbers, no network
//   HEADROOM_OPEN=1   drop the panel at launch (HEADROOM_PIN=1 keeps it up when focus moves — for screenshots)

import AppKit
import Observation
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var item: NSStatusItem!
    private var panel: DropPanel!
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = Store.shared
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "headroom"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        trackLabel()

        panel = DropPanel(width: 340, content: PanelView().environment(store))

        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in await Store.shared.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8)) // let Wi-Fi come back
                await Store.shared.refresh()
            }
        }
        Task { await store.refresh() }

        if !UserDefaults.standard.bool(forKey: "loginItemSetUp"), !store.demo {
            store.openAtLogin = true
            UserDefaults.standard.set(true, forKey: "loginItemSetUp")
        }
        if Env.flag("OPEN") || (!ClaudeAuth.shared.isSignedIn && !store.demo) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showPanel() }
        }
    }

    private func trackLabel() {
        withObservationTracking { renderLabel() } onChange: {
            Task { @MainActor in self.trackLabel() }
        }
    }

    private func renderLabel() {
        guard let button = item.button else { return }
        let s = Store.shared
        let c = s.claude.snapshot?.weekly?.left, x = s.codex.snapshot?.weekly?.left
        button.image = MenuBarImage.render(claude: c, codex: x, numbers: s.showNumbers)
        func tip(_ p: Provider, _ v: Double?) -> String { "\(p.name): " + (v.map { "\(Int(($0 * 100).rounded()))% left this week" } ?? "—") }
        button.toolTip = tip(.claude, c) + "\n" + tip(.codex, x)
    }

    @objc private func clicked() {
        if panel.isVisible { panel.close() } else if !panel.justClosed { showPanel() }
    }

    func showPanel() {
        guard let button = item.button, let window = button.window else { return }
        panel.show(below: window.convertToScreen(button.convert(button.bounds, to: nil)))
        Task { await Store.shared.refreshIfStale() }
    }
}

/// A borderless Liquid Glass panel that drops down under the menu bar item and
/// keeps its top edge pinned while its content grows or shrinks.
final class DropPanel: NSPanel {
    private(set) var justClosed = false
    private var closing = false
    private let width: CGFloat
    private var height: CGFloat = 400

    init<V: View>(width: CGFloat, content: V) {
        let sizer = Sizer()
        let root = content
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .glassEffect(.regular.tint(.panelTint), in: .rect(cornerRadius: 24, style: .continuous))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sizer.panel?.fit(height: $0) }
            .frame(maxHeight: .infinity, alignment: .top)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        self.width = width
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        sizer.panel = self
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the glass draws its own edge; a window shadow would be rectangular
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        contentView = host
    }

    private final class Sizer { weak var panel: DropPanel? }

    override var canBecomeKey: Bool { true }

    func fit(height: CGFloat) {
        let h = ceil(height)
        guard h > 0 else { return }
        self.height = h
        guard isVisible, abs(frame.height - h) > 0.5 else { return }
        var f = frame
        f.origin.y += f.height - h
        f.size.height = h
        setFrame(f, display: true)
    }

    func show(below anchor: NSRect) {
        let size = NSSize(width: width, height: height)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main!
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        let rest = NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height)
        setFrame(rest.offsetBy(dx: 0, dy: 6), display: true)
        alphaValue = 0
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            animator().setFrame(rest, display: true)
            animator().alphaValue = 1
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow, !Env.flag("PIN") else { return }
            if let key = NSApp.keyWindow, key.parent === self || key.level.rawValue > NSWindow.Level.normal.rawValue { return }
            self.close()
        }
    }

    override func close() {
        guard isVisible, !closing else { return }
        closing = true
        justClosed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.justClosed = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
        }) {
            super.close()
            self.closing = false
        }
    }
}
