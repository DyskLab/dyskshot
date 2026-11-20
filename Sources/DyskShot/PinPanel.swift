import AppKit

/// Always-on-top floating screenshot. Drag to move, scroll to resize, right-click for options, Esc / double-click to close.
final class PinPanel: NSPanel {
    @MainActor private static var all: [PinPanel] = []
    let capture: Capture

    @MainActor
    static func show(_ capture: Capture) {
        let p = PinPanel(capture: capture)
        all.append(p)
        p.orderFrontRegardless()
        p.makeKey()
    }

    init(capture: Capture) {
        self.capture = capture
        let screen = NSScreen.underMouse ?? NSScreen.screens[0]
        var size = capture.pointSize
        let maxW = screen.visibleFrame.width * 0.6, maxH = screen.visibleFrame.height * 0.6
        let r = min(1, maxW / size.width, maxH / size.height)
        size = NSSize(width: (size.width * r).rounded(), height: (size.height * r).rounded())
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hasShadow = Prefs.bool("pin.shadow")
        backgroundColor = .clear
        isOpaque = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PinView(panel: self)
    }

    @MainActor private static var hidden = false
    @MainActor static var count: Int { all.count }

    @MainActor
    static func toggleAll() {
        guard !all.isEmpty else { Toast.show("No pinned screenshots", symbol: "pin.slash"); return }
        hidden.toggle()
        all.forEach { hidden ? $0.orderOut(nil) : $0.orderFrontRegardless() }
    }

    @MainActor
    static func closeAll() {
        all.forEach { $0.orderOut(nil) }
        all.removeAll()
        hidden = false
    }

    override var canBecomeKey: Bool { true }

    @MainActor
    func closePin() {
        orderOut(nil)
        Self.all.removeAll { $0 === self }
    }
}

final class PinView: NSView {
    private unowned let panel: PinPanel

    init(panel: PinPanel) {
        self.panel = panel
        super.init(frame: NSRect(origin: .zero, size: panel.frame.size))
        wantsLayer = true
        layer?.contents = panel.capture.image
        layer?.contentsGravity = .resize
        layer?.cornerRadius = Prefs.bool("pin.rounded") ? 8 : 0
        layer?.masksToBounds = true
        layer?.borderWidth = Prefs.bool("pin.border") ? 1 : 0
        layer?.borderColor = NSColor(white: 0.5, alpha: 0.4).cgColor
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { panel.closePin(); return }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        let factor = 1 + delta * 0.01
        var f = panel.frame
        let aspect = f.width / f.height
        let newW = max(60, min(f.width * factor, 6000))
        let newH = newW / aspect
        f = NSRect(x: f.midX - newW / 2, y: f.midY - newH / 2, width: newW, height: newH)
        panel.setFrame(f, display: true)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { panel.closePin() } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        m.addItem(withTitle: "Save", action: #selector(saveImage), keyEquivalent: "").target = self
        m.addItem(withTitle: "Annotate", action: #selector(annotate), keyEquivalent: "").target = self
        m.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "").target = self
        let opacity = NSMenu()
        for v in [100, 75, 50, 25] {
            let item = opacity.addItem(withTitle: "\(v)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = v
            item.state = Int((panel.alphaValue * 100).rounded()) == v ? .on : .off
        }
        let opItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opItem.submenu = opacity
        m.addItem(opItem)
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self
        return m
    }

    @objc private func copyImage() { Output.copy(panel.capture); Toast.show("Copied to clipboard") }
    @objc private func saveImage() { if Output.save(panel.capture) != nil { Toast.show("Saved") } }
    @objc private func annotate() { EditorWindowController.open(panel.capture) }
    @objc private func closePin() { panel.closePin() }
    @objc private func setOpacity(_ sender: NSMenuItem) { panel.alphaValue = CGFloat(sender.tag) / 100 }
    @objc private func actualSize() {
        let s = panel.capture.pointSize
        let f = panel.frame
        panel.setFrame(NSRect(x: f.midX - s.width / 2, y: f.midY - s.height / 2, width: s.width, height: s.height), display: true)
    }
}
