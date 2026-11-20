import AppKit

/// All rects are global Cocoa coordinates.
enum SelectionResult {
    case cancelled
    case area(NSRect, OverlayDisplay)
    case window(CGWindowID, NSRect, OverlayDisplay)
    case screen(OverlayDisplay)
}

struct SelectionOptions {
    var windowMode = false
    /// Click without dragging / Return without selection selects the whole screen.
    var allowsScreen = false
    var hint = "Drag to select · Space: window mode · Shift: square · Esc: cancel"
}

/// One borderless window per display; the user drags an area or picks a window.
@MainActor
final class SelectionOverlayController {
    private let displays: [OverlayDisplay]
    private let windowsInfo: [WindowInfo]
    private let options: SelectionOptions
    private var windowMode: Bool
    private let completion: (SelectionResult) -> Void
    private var overlayWindows: [OverlayWindow] = []
    private var finished = false

    init(displays: [OverlayDisplay], windows: [WindowInfo], options: SelectionOptions,
         completion: @escaping (SelectionResult) -> Void) {
        self.displays = displays
        self.windowsInfo = windows
        self.options = options
        self.windowMode = options.windowMode
        self.completion = completion
    }

    func show() {
        for d in displays {
            let w = OverlayWindow(contentRect: d.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = d.image != nil
            w.backgroundColor = .clear
            w.hasShadow = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.setFrame(d.screen.frame, display: false)
            let view = SelectionView(frame: NSRect(origin: .zero, size: d.screen.frame.size),
                                     display: d, windows: windowsInfo, options: options, windowMode: windowMode)
            view.controller = self
            w.contentView = view
            w.orderFrontRegardless()
            overlayWindows.append(w)
        }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        let key = overlayWindows.first { NSMouseInRect(mouse, $0.frame, false) } ?? overlayWindows.first
        key?.makeKey()
        key?.makeFirstResponder(key?.contentView)
    }

    func toggleWindowMode() {
        windowMode.toggle()
        for w in overlayWindows { (w.contentView as? SelectionView)?.windowMode = windowMode }
    }

    func finish(_ result: SelectionResult) {
        guard !finished else { return }
        finished = true
        for w in overlayWindows { w.orderOut(nil) }
        overlayWindows.removeAll()
        // Give the window server a moment to remove the overlay before anything is captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [completion] in
            MainActor.assumeIsolated { completion(result) }
        }
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    weak var controller: SelectionOverlayController?
    private let display: OverlayDisplay
    private let options: SelectionOptions
    private let localWindows: [(id: CGWindowID, rect: NSRect)]
    private let showCrosshair = Prefs.int("shot.crosshair") != 0
    private let showMagnifier = Prefs.bool("shot.magnifier")

    var windowMode: Bool { didSet { hovered = mouse.flatMap(window(at:)); needsDisplay = true } }

    private var mouse: NSPoint?
    private var dragStart: NSPoint?
    private var selection: NSRect?
    private var hovered: (id: CGWindowID, rect: NSRect)?

    init(frame: NSRect, display: OverlayDisplay, windows: [WindowInfo], options: SelectionOptions, windowMode: Bool) {
        self.display = display
        self.options = options
        let origin = display.screen.frame.origin
        let bounds = NSRect(origin: .zero, size: frame.size)
        self.localWindows = windows.compactMap { w in
            let r = w.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            return r.intersects(bounds) ? (w.id, r) : nil
        }
        self.windowMode = windowMode
        super.init(frame: frame)
        let p = NSEvent.mouseLocation
        if NSMouseInRect(p, display.screen.frame, false) {
            mouse = NSPoint(x: p.x - origin.x, y: p.y - origin.y)
            hovered = windowMode ? mouse.flatMap(window(at:)) : nil
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    private func window(at p: NSPoint) -> (id: CGWindowID, rect: NSRect)? {
        localWindows.first { $0.rect.contains(p) }
    }

    private func global(_ r: NSRect) -> NSRect {
        r.offsetBy(dx: display.screen.frame.minX, dy: display.screen.frame.minY)
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        hovered = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        if windowMode { hovered = window(at: p) }
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        dragStart = p
        selection = nil
        mouse = p
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        var p = clamp(convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift) {
            let d = max(abs(p.x - start.x), abs(p.y - start.y))
            p = clamp(NSPoint(x: start.x + (p.x < start.x ? -d : d), y: start.y + (p.y < start.y ? -d : d)))
        }
        mouse = p
        selection = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                           width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        defer { dragStart = nil }
        if let sel = selection, sel.width >= 3, sel.height >= 3 {
            controller?.finish(.area(global(sel), display))
        } else if windowMode, let w = window(at: p) {
            controller?.finish(.window(w.id, global(w.rect.intersection(bounds)), display))
        } else if options.allowsScreen {
            controller?.finish(.screen(display))
        } else {
            selection = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) { controller?.finish(.cancelled) }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: controller?.finish(.cancelled)
        case 49: if dragStart == nil { controller?.toggleWindowMode() }
        case 36, 76:
            if let sel = selection, sel.width >= 3, sel.height >= 3 {
                controller?.finish(.area(global(sel), display))
            } else if options.allowsScreen {
                controller?.finish(.screen(display))
            }
        default: super.keyDown(with: event)
        }
    }

    private func clamp(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let img = display.image {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: bounds)
        } else {
            ctx.clear(bounds)
        }

        let dim = NSColor.black.withAlphaComponent(0.4)
        let highlight = selection ?? (windowMode ? hovered?.rect : nil)

        if let h = highlight {
            let path = NSBezierPath(rect: bounds)
            path.appendRect(h)
            path.windingRule = .evenOdd
            dim.setFill()
            path.fill()

            if windowMode && selection == nil {
                NSColor.systemBlue.withAlphaComponent(0.18).setFill()
                NSBezierPath(rect: h).fill()
                NSColor.systemBlue.setStroke()
                let b = NSBezierPath(rect: h.insetBy(dx: 1, dy: 1))
                b.lineWidth = 2
                b.stroke()
            } else {
                NSColor.white.setStroke()
                let b = NSBezierPath(rect: h.insetBy(dx: -0.5, dy: -0.5))
                b.lineWidth = 1
                b.stroke()
            }
            drawSizeLabel(for: h)
        } else if windowMode || display.image == nil {
            (display.image == nil ? NSColor.black.withAlphaComponent(0.15) : dim).setFill()
            NSBezierPath(rect: bounds).fill()
        }

        if selection == nil, !windowMode, let m = mouse {
            if showCrosshair { drawCrosshair(at: m) }
            if showMagnifier { drawMagnifier(at: m, in: ctx) }
        }
        if selection == nil, mouse != nil { drawHint() }
    }

    private func drawCrosshair(at m: NSPoint) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: m.y.rounded() + 0.5))
        path.line(to: NSPoint(x: bounds.maxX, y: m.y.rounded() + 0.5))
        path.move(to: NSPoint(x: m.x.rounded() + 0.5, y: bounds.minY))
        path.line(to: NSPoint(x: m.x.rounded() + 0.5, y: bounds.maxY))
        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 3
        path.stroke()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawMagnifier(at m: NSPoint, in ctx: CGContext) {
        guard let image = display.image else { return }
        let s = display.scale
        let samples = 21
        let cx = Int(m.x * s), cy = Int((bounds.height - m.y) * s)
        let src = CGRect(x: cx - samples / 2, y: cy - samples / 2, width: samples, height: samples)
        guard let crop = image.cropping(to: src), crop.width == samples, crop.height == samples else { return }

        let size: CGFloat = 126
        var origin = NSPoint(x: m.x + 24, y: m.y - 24 - size)
        if origin.x + size > bounds.maxX { origin.x = m.x - 24 - size }
        if origin.y < bounds.minY + 24 { origin.y = m.y + 24 }
        let dest = NSRect(origin: origin, size: NSSize(width: size, height: size))

        ctx.saveGState()
        NSBezierPath(roundedRect: dest, xRadius: 10, yRadius: 10).addClip()
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: dest)
        let cell = size / CGFloat(samples)
        let center = NSRect(x: dest.midX - cell / 2, y: dest.midY - cell / 2, width: cell, height: cell)
        NSColor.white.setStroke()
        let c = NSBezierPath(rect: center)
        c.lineWidth = 1.5
        c.stroke()
        ctx.restoreGState()

        NSColor.white.setStroke()
        let border = NSBezierPath(roundedRect: dest, xRadius: 10, yRadius: 10)
        border.lineWidth = 2
        border.stroke()

        drawLabel("\(Int(m.x * s)), \(Int((bounds.height - m.y) * s))", at: NSPoint(x: dest.midX, y: dest.minY - 6))
    }

    private func drawSizeLabel(for r: NSRect) {
        let s = display.scale
        let text = "\(Int((r.width * s).rounded())) × \(Int((r.height * s).rounded()))"
        var p = NSPoint(x: r.midX, y: r.minY - 8)
        if p.y < 30 { p.y = r.minY + 34 }
        drawLabel(text, at: p)
    }

    private func drawHint() {
        let text = windowMode ? "Click a window · Space: area mode · Esc: cancel" : options.hint
        drawLabel(text, at: NSPoint(x: bounds.midX, y: bounds.maxY - 40))
    }

    private func drawLabel(_ text: String, at p: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let box = NSRect(x: p.x - size.width / 2 - 7, y: p.y - size.height - 6, width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        str.draw(at: NSPoint(x: box.minX + 7, y: box.minY + 3))
    }
}
