import AVFoundation
import AppKit

/// After selecting an area: adjustable area + config HUD, then Record GIF (⌥↩) or Record Video (↩).
@MainActor
final class RecordSetupController {
    private(set) var rect: NSRect // global Cocoa
    let screen: NSScreen
    private var overlays: [NSWindow] = []
    private var areaView: RecordAreaView!
    private var hud: RecordHUD!
    private var rectBeforeFullscreen: NSRect?
    private let completion: (RecordingController.Kind?, NSRect) -> Void
    private let reselect: () -> Void
    private var closed = false

    init(rect: NSRect, screen: NSScreen, reselect: @escaping () -> Void,
         completion: @escaping (RecordingController.Kind?, NSRect) -> Void) {
        self.rect = rect.intersection(screen.frame).integral
        self.screen = screen
        self.reselect = reselect
        self.completion = completion
    }

    func show() {
        for s in NSScreen.screens {
            let w = OverlayWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.setFrame(s.frame, display: false)
            if s == screen {
                areaView = RecordAreaView(frame: NSRect(origin: .zero, size: s.frame.size), controller: self)
                w.contentView = areaView
            } else {
                w.contentView = DimView(frame: NSRect(origin: .zero, size: s.frame.size), hole: nil)
            }
            w.orderFrontRegardless()
            overlays.append(w)
        }
        hud = RecordHUD(controller: self)
        hud.orderFrontRegardless()
        layoutHUD()
        CameraBubble.shared.refresh(in: rect)
        NSApp.activate()
        if let w = overlays.first(where: { $0.contentView === areaView }) {
            w.makeKey()
            w.makeFirstResponder(areaView)
        }
    }

    var localRect: NSRect { rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }

    func setLocalRect(_ r: NSRect) {
        setRect(r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
    }

    func setRect(_ r: NSRect) {
        rect = r.intersection(screen.frame).integral
        areaView?.needsDisplay = true
        hud?.updateSize()
        layoutHUD()
        CameraBubble.shared.follow(rect)
    }

    func setSize(width: CGFloat, height: CGFloat) {
        let w = max(20, min(width, screen.frame.width)), h = max(20, min(height, screen.frame.height))
        var r = NSRect(x: rect.minX, y: rect.maxY - h, width: w, height: h)
        if r.maxX > screen.frame.maxX { r.origin.x = screen.frame.maxX - w }
        if r.minY < screen.frame.minY { r.origin.y = screen.frame.minY }
        setRect(r)
    }

    func toggleFullscreen() {
        if let prev = rectBeforeFullscreen, rect == screen.frame {
            rectBeforeFullscreen = nil
            setRect(prev)
        } else {
            rectBeforeFullscreen = rect
            setRect(screen.frame)
        }
    }

    private func layoutHUD() {
        guard let hud else { return }
        let size = hud.frame.size
        let vf = screen.visibleFrame
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < vf.minY + 8 { origin.y = rect.minY + 12 }            // no room below → inside bottom
        if rect.height < size.height + 40 && origin.y >= rect.minY { origin.y = min(rect.maxY + 12, vf.maxY - size.height) }
        origin.x = max(vf.minX + 8, min(origin.x, vf.maxX - size.width - 8))
        hud.setFrameOrigin(origin)
    }

    func record(_ kind: RecordingController.Kind) {
        guard !closed else { return }
        close()
        completion(kind, rect)
    }

    func cancel() {
        guard !closed else { return }
        close()
        CameraBubble.shared.hide()
        completion(nil, rect)
    }

    func reselectArea() {
        guard !closed else { return }
        close()
        reselect()
    }

    private func close() {
        closed = true
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        hud?.orderOut(nil)
    }
}

// MARK: - Adjustable area

final class RecordAreaView: NSView {
    private unowned let controller: RecordSetupController
    private var handle: RectHandle?
    private var origin: NSPoint = .zero
    private var newStart: NSPoint?

    init(frame: NSRect, controller: RecordSetupController) {
        self.controller = controller
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        (RectHandle.hit(p, rect: controller.localRect, tolerance: 8)?.cursor ?? .crosshair).set()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = controller.localRect
        let dim = NSBezierPath(rect: bounds)
        dim.appendRect(r)
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        NSColor.white.setStroke()
        let b = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        b.lineWidth = 1
        b.setLineDash([6, 4], count: 2, phase: 0)
        b.stroke()
        RectHandle.drawHandles(r, size: 9)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        origin = p
        handle = RectHandle.hit(p, rect: controller.localRect, tolerance: 8)
        newStart = handle == nil ? p : nil
        if handle == .move { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let s = newStart {
            let r = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            if r.width > 4 && r.height > 4 { controller.setLocalRect(r) }
        } else if let h = handle {
            controller.setLocalRect(h.apply(to: controller.localRect, dx: p.x - origin.x, dy: p.y - origin.y,
                                            within: bounds, minSize: 20))
        }
        origin = p
    }

    override func mouseUp(with event: NSEvent) {
        handle = nil
        newStart = nil
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: controller.cancel()
        case 36, 76: controller.record(event.modifierFlags.contains(.option) ? .gif : .video)
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - HUD

final class RecordHUD: NSPanel, NSTextFieldDelegate {
    private unowned let controller: RecordSetupController
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private var micButton: HUDButton!
    private var audioButton: HUDButton!
    private var cameraButton: HUDButton!
    private var clicksButton: HUDButton!
    private var keysButton: HUDButton!

    init(controller: RecordSetupController) {
        self.controller = controller
        let size = NSSize(width: 232, height: 146)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        build(size: size)
        updateSize()
        refreshToggles()
    }

    override var canBecomeKey: Bool { true }

    private func card(_ frame: NSRect) -> NSVisualEffectView {
        let v = NSVisualEffectView(frame: frame)
        v.material = .hudWindow
        v.state = .active
        v.blendingMode = .behindWindow
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        return v
    }

    private func build(size: NSSize) {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let top = card(NSRect(x: 0, y: 70, width: size.width, height: 76))
        let bottom = card(NSRect(x: 0, y: 0, width: size.width, height: 66))
        root.addSubview(top)
        root.addSubview(bottom)

        let settings = HUDButton(symbol: "slider.horizontal.3", tip: "Recording settings") { [weak self] in
            // The setup overlay sits above everything; close it so Settings is visible.
            self?.controller.cancel()
            PreferencesWindow.show(tab: 4)
        }
        for f in [widthField, heightField] {
            f.alignment = .center
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            f.controlSize = .small
            f.bezelStyle = .roundedBezel
            f.delegate = self
            f.target = self
            f.action = #selector(sizeEntered)
            f.widthAnchor.constraint(equalToConstant: 46).isActive = true
            f.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor
        times.setContentCompressionResistancePriority(.required, for: .horizontal)
        let sizeStack = NSStackView(views: [widthField, times, heightField])
        sizeStack.spacing = 3
        sizeStack.widthAnchor.constraint(equalToConstant: 104).isActive = true
        let full = HUDButton(symbol: "arrow.up.left.and.arrow.down.right", tip: "Fullscreen") { [weak self] in self?.controller.toggleFullscreen() }
        let crop = HUDButton(symbol: "crop", tip: "Select a new area") { [weak self] in self?.controller.reselectArea() }
        let row1 = NSStackView(views: [settings, sizeStack, full, crop])
        row1.distribution = .equalSpacing
        row1.spacing = 0

        micButton = HUDButton(symbol: "mic", tip: "Microphone") { [weak self] in self?.showMicMenu() }
        audioButton = HUDButton(symbol: "speaker.wave.2", tip: "System audio") { [weak self] in self?.toggle("rec.systemAudio") }
        cameraButton = HUDButton(symbol: "video", tip: "Camera") { [weak self] in self?.showCameraMenu() }
        clicksButton = HUDButton(symbol: "cursorarrow.click.2", tip: "Highlight clicks") { [weak self] in self?.toggle("rec.highlightClicks") }
        keysButton = HUDButton(symbol: "command", tip: "Show keystrokes") { [weak self] in self?.toggle("rec.showKeystrokes") }
        let row2 = NSStackView(views: [micButton, audioButton, cameraButton, clicksButton, keysButton])
        row2.distribution = .equalSpacing

        let rows = NSStackView(views: [row1, row2])
        rows.orientation = .vertical
        rows.spacing = 4
        rows.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        rows.frame = top.bounds
        rows.autoresizingMask = [.width, .height]
        row1.widthAnchor.constraint(equalToConstant: size.width - 16).isActive = true
        row2.widthAnchor.constraint(equalToConstant: size.width - 16).isActive = true
        top.addSubview(rows)

        let gif = HUDRow(badge: Self.gifBadge(), title: "Record GIF", shortcut: "⌥ ↩") { [weak self] in self?.controller.record(.gif) }
        let video = HUDRow(badge: NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil) ?? NSImage(),
                           title: "Record Video", shortcut: "↩") { [weak self] in self?.controller.record(.video) }
        gif.frame = NSRect(x: 4, y: 34, width: size.width - 8, height: 28)
        video.frame = NSRect(x: 4, y: 4, width: size.width - 8, height: 28)
        let sep = NSBox(frame: NSRect(x: 10, y: 32.5, width: size.width - 20, height: 1))
        sep.boxType = .separator
        [gif, sep, video].forEach(bottom.addSubview)

        contentView = root
    }

    static func gifBadge() -> NSImage {
        NSImage(size: NSSize(width: 24, height: 14), flipped: false) { r in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            let s = NSAttributedString(string: "GIF", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .heavy),
                                                                   .foregroundColor: NSColor.black])
            let sz = s.size()
            s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
            return true
        }
    }

    @MainActor
    func updateSize() {
        widthField.stringValue = "\(Int(controller.rect.width))"
        heightField.stringValue = "\(Int(controller.rect.height))"
    }

    @objc private func sizeEntered() {
        MainActor.assumeIsolated {
            guard let w = Double(widthField.stringValue), let h = Double(heightField.stringValue) else { updateSize(); return }
            controller.setSize(width: w, height: h)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { sizeEntered() }

    private func toggle(_ key: String) {
        Prefs.d.set(!Prefs.bool(key), forKey: key)
        if key == "rec.showKeystrokes" && Prefs.bool(key) {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        refreshToggles()
    }

    private func refreshToggles() {
        micButton.set(on: Prefs.bool("rec.mic"), symbolOn: "mic.fill", symbolOff: "mic.slash")
        audioButton.set(on: Prefs.bool("rec.systemAudio"), symbolOn: "speaker.wave.2.fill", symbolOff: "speaker.slash")
        cameraButton.set(on: Prefs.bool("rec.camera"), symbolOn: "video.fill", symbolOff: "video.slash")
        clicksButton.set(on: Prefs.bool("rec.highlightClicks"), symbolOn: "cursorarrow.click.2", symbolOff: "cursorarrow.click.2")
        keysButton.set(on: Prefs.bool("rec.showKeystrokes"), symbolOn: "command", symbolOff: "command")
    }

    // MARK: Device menus

    private func showMicMenu() {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                       position: .unspecified).devices
        let current = Prefs.bool("rec.mic") ? Prefs.string("rec.micDevice") : nil
        let menu = NSMenu()
        let none = menu.addItem(withTitle: "No Microphone", action: #selector(micPicked(_:)), keyEquivalent: "")
        none.target = self
        none.state = current == nil ? .on : .off
        menu.addItem(.separator())
        for d in devices {
            let item = menu.addItem(withTitle: d.localizedName, action: #selector(micPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.uniqueID
            let isDefault = (current?.isEmpty ?? false) && d == AVCaptureDevice.default(for: .audio)
            item.state = (current == d.uniqueID || isDefault) ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: micButton.bounds.height + 4), in: micButton)
    }

    @objc private func micPicked(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if !granted { Toast.show("Microphone access denied", symbol: "mic.slash") }
                    }
                }
            }
            Prefs.d.set(id, forKey: "rec.micDevice")
            Prefs.d.set(true, forKey: "rec.mic")
        } else {
            Prefs.d.set(false, forKey: "rec.mic")
        }
        refreshToggles()
    }

    private func showCameraMenu() {
        let devices = CameraBubble.devices()
        let current = Prefs.bool("rec.camera") ? Prefs.string("rec.cameraDevice") : nil
        let menu = NSMenu()
        let none = menu.addItem(withTitle: "No Camera", action: #selector(cameraPicked(_:)), keyEquivalent: "")
        none.target = self
        none.state = current == nil ? .on : .off
        menu.addItem(.separator())
        for d in devices {
            let item = menu.addItem(withTitle: d.localizedName, action: #selector(cameraPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.uniqueID
            let isDefault = (current?.isEmpty ?? false) && d == AVCaptureDevice.default(for: .video)
            item.state = (current == d.uniqueID || isDefault) ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: cameraButton.bounds.height + 4), in: cameraButton)
    }

    @objc private func cameraPicked(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            if let id = sender.representedObject as? String {
                Prefs.d.set(id, forKey: "rec.cameraDevice")
                Prefs.d.set(true, forKey: "rec.camera")
            } else {
                Prefs.d.set(false, forKey: "rec.camera")
            }
            refreshToggles()
            CameraBubble.shared.refresh(in: controller.rect, restart: true)
        }
    }
}

/// Square icon button for the HUD.
final class HUDButton: NSButton {
    private let handler: () -> Void

    init(symbol: String, tip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 28))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        isBordered = false
        toolTip = tip
        target = self
        action = #selector(fire)
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func fire() { handler() }

    func set(on: Bool, symbolOn: String, symbolOff: String) {
        image = NSImage(systemSymbolName: on ? symbolOn : symbolOff, accessibilityDescription: toolTip)
        contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
    }
}

/// Full-width clickable row ("Record Video  ↩").
final class HUDRow: NSView {
    private let handler: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(badge: NSImage, title: String, shortcut: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        let icon = NSImageView(image: badge)
        icon.contentTintColor = .white
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let key = NSTextField(labelWithString: shortcut)
        key.textColor = .secondaryLabelColor
        key.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [icon, label, NSView(), key])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { handler() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor(white: 1, alpha: 0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}

// MARK: - Camera bubble (shown in the recording)

@MainActor
final class CameraBubble {
    static let shared = CameraBubble()
    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var userMoved = false
    private var moveObserver: Any?

    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    func refresh(in rect: NSRect, restart: Bool = false) {
        if !Prefs.bool("rec.camera") { hide(); return }
        if restart { hide() }
        if panel == nil {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if granted { CameraBubble.shared.show(in: rect) } else { Toast.show("Camera access denied", symbol: "video.slash") }
                    }
                }
            }
        }
    }

    private func show(in rect: NSRect) {
        guard panel == nil, Prefs.bool("rec.camera") else { return }
        let id = Prefs.string("rec.cameraDevice")
        guard let device = Self.devices().first(where: { $0.uniqueID == id }) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            Toast.show("No camera available", symbol: "video.slash")
            return
        }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let d: CGFloat = 180
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: d, height: d)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = BubbleView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        v.wantsLayer = true
        v.layer?.cornerRadius = d / 2
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 3
        v.layer?.borderColor = NSColor.white.cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = v.bounds
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        v.layer?.addSublayer(preview)
        p.contentView = v
        self.panel = p
        self.session = session
        userMoved = false
        place(in: rect)
        p.orderFrontRegardless()
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { CameraBubble.shared.userMoved = true }
        }
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    func follow(_ rect: NSRect) {
        guard panel != nil, !userMoved else { return }
        place(in: rect)
    }

    private func place(in rect: NSRect) {
        guard let p = panel else { return }
        let d = p.frame.width
        let origin = NSPoint(x: rect.maxX - d - 20, y: rect.minY + 20)
        if let obs = moveObserver { NotificationCenter.default.removeObserver(obs) }
        p.setFrameOrigin(origin)
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { CameraBubble.shared.userMoved = true }
        }
    }

    func hide() {
        if let obs = moveObserver { NotificationCenter.default.removeObserver(obs) }
        moveObserver = nil
        panel?.orderOut(nil)
        panel = nil
        if let s = session { DispatchQueue.global(qos: .utility).async { s.stopRunning() } }
        session = nil
    }
}

final class BubbleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
