import AVFoundation
import AppKit

enum QAItem {
    case image(Capture, saved: URL?)
    case file(URL, thumbnail: CGImage?, type: String, saved: Bool)
}

/// Stack of floating thumbnails after each capture.
@MainActor
final class QuickAccessManager {
    static let shared = QuickAccessManager()
    private var panels: [QuickAccessPanel] = []
    private let maxPanels = 6
    private var screen: NSScreen?

    func show(_ item: QAItem) {
        let panel = QuickAccessPanel(item: item)
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.panels.removeAll { $0 === panel }
            self.relayout()
        }
        if hidden { hidden = false; panels.forEach { $0.orderFrontRegardless() } }
        panels.insert(panel, at: 0)
        while panels.count > maxPanels { panels.removeLast().dismiss() }

        if Prefs.bool("qa.activeScreen") || screen == nil { screen = NSScreen.underMouse }
        let vf = (screen ?? NSScreen.screens[0]).visibleFrame
        let right = Prefs.int("qa.position") == 1
        panel.setFrameOrigin(NSPoint(x: right ? vf.maxX : vf.minX - panel.frame.width, y: vf.minY + 20))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        relayout()
    }

    private var hidden = false
    var count: Int { panels.count }

    func toggleVisibility() {
        guard !panels.isEmpty else { return }
        hidden.toggle()
        panels.forEach { hidden ? $0.orderOut(nil) : $0.orderFrontRegardless() }
    }

    func saveAll() {
        guard !panels.isEmpty else { return }
        panels.forEach { $0.save(ask: false) }
    }

    func closeAll() {
        panels.forEach { $0.dismiss() }
    }

    private func relayout() {
        let vf = (screen ?? NSScreen.screens[0]).visibleFrame
        let right = Prefs.int("qa.position") == 1
        var y = vf.minY + 20
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for p in panels {
                let x = right ? vf.maxX - 20 - p.frame.width : vf.minX + 20
                p.animator().setFrame(NSRect(x: x, y: y, width: p.frame.width, height: p.frame.height), display: true)
                p.animator().alphaValue = 1
                y += p.frame.height + 12
            }
        }
    }
}

final class QuickAccessPanel: NSPanel {
    var item: QAItem
    var onClose: (() -> Void)?
    private var autoCloseTimer: Timer?
    private var dismissed = false

    init(item: QAItem) {
        self.item = item
        let size = Self.thumbSize(for: item)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = QuickAccessView(panel: self)
        scheduleAutoClose()
    }

    var thumbnail: CGImage? {
        switch item {
        case .image(let c, _): c.image
        case .file(_, let t, _, _): t
        }
    }

    var isImage: Bool { if case .image = item { true } else { false } }

    static func thumbSize(for item: QAItem) -> NSSize {
        let scale = CGFloat(Prefs.double("qa.size"))
        let maxW = 160 + scale * 220, maxH = 110 + scale * 170
        var s = NSSize(width: 16, height: 10)
        switch item {
        case .image(let c, _): s = c.pointSize
        case .file(_, let t, _, _): if let t { s = NSSize(width: t.width, height: t.height) }
        }
        let r = min(maxW / max(s.width, 1), maxH / max(s.height, 1))
        return NSSize(width: max(170, (s.width * r).rounded()), height: max(110, (s.height * r).rounded()))
    }

    override var canBecomeKey: Bool { true }

    // MARK: Auto-close

    func scheduleAutoClose() {
        autoCloseTimer?.invalidate()
        guard Prefs.bool("qa.autoClose") else { return }
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(Prefs.qaAutoCloseSeconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Prefs.int("qa.autoCloseAction") == 1 { _ = self.save(ask: false) }
                self.dismiss()
            }
        }
    }

    func pauseAutoClose() { autoCloseTimer?.invalidate() }

    // MARK: Actions

    @MainActor
    func fileURL() -> URL? {
        switch item {
        case .image(let c, let saved): return saved ?? Output.tempFile(c)
        case .file(let url, _, _, _): return url
        }
    }

    @MainActor
    func copyItem() {
        switch item {
        case .image(let c, let saved): Output.copy(c, fileURL: saved)
        case .file(let url, _, _, _): Output.copyFile(url)
        }
        Toast.show("Copied to clipboard")
    }

    @MainActor
    @discardableResult
    func save(ask: Bool) -> URL? {
        switch item {
        case .image(let c, let saved):
            if let saved, !ask { return saved }
            guard let url = Output.save(c, ask: ask) else { return nil }
            item = .image(c, saved: url)
            Toast.show("Saved \(url.lastPathComponent)")
            return url
        case .file(let url, let t, let type, let saved):
            if saved && !ask { return url }
            guard let dest = Output.saveFile(url, type: type, ask: ask) else { return nil }
            item = .file(dest, thumbnail: t, type: type, saved: true)
            Toast.show("Saved \(dest.lastPathComponent)")
            return dest
        }
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        autoCloseTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; self.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                self.orderOut(nil)
                self.onClose?()
                self.onClose = nil
            }
        }
    }
}

final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class QuickAccessView: NSView, NSDraggingSource {
    private unowned let panel: QuickAccessPanel
    private let imageLayer = CALayer()
    private let hover = NSView()
    private var downEvent: NSEvent?
    private var optionDrag = false

    init(panel: QuickAccessPanel) {
        self.panel = panel
        super.init(frame: NSRect(origin: .zero, size: panel.frame.size))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor

        imageLayer.contents = panel.thumbnail
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.frame = bounds
        layer?.addSublayer(imageLayer)

        hover.frame = bounds
        hover.autoresizingMask = [.width, .height]
        hover.wantsLayer = true
        hover.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        hover.alphaValue = 0
        addSubview(hover)

        let stack = NSStackView(views: [pill("Copy", #selector(copyAction)), pill("Save", #selector(saveAction))])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        hover.addSubview(stack)

        let close = icon("xmark", "Close", #selector(closeAction))
        let upload = icon("icloud.and.arrow.up", "Upload to Google Drive", #selector(uploadAction))
        hover.addSubview(close)
        hover.addSubview(upload)
        var constraints = [
            stack.centerXAnchor.constraint(equalTo: hover.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: hover.centerYAnchor),
            close.topAnchor.constraint(equalTo: hover.topAnchor, constant: 6),
            close.leadingAnchor.constraint(equalTo: hover.leadingAnchor, constant: 6),
            upload.topAnchor.constraint(equalTo: hover.topAnchor, constant: 6),
            upload.centerXAnchor.constraint(equalTo: hover.centerXAnchor),
        ]

        if panel.isImage {
            let edit = icon("pencil.tip.crop.circle", "Annotate", #selector(annotateAction))
            let pin = icon("pin", "Pin to screen", #selector(pinAction))
            let ocr = icon("text.viewfinder", "Copy text (OCR)", #selector(ocrAction))
            [edit, pin, ocr].forEach(hover.addSubview)
            constraints += [
                edit.topAnchor.constraint(equalTo: hover.topAnchor, constant: 6),
                edit.trailingAnchor.constraint(equalTo: hover.trailingAnchor, constant: -6),
                pin.bottomAnchor.constraint(equalTo: hover.bottomAnchor, constant: -6),
                pin.leadingAnchor.constraint(equalTo: hover.leadingAnchor, constant: 6),
                ocr.bottomAnchor.constraint(equalTo: hover.bottomAnchor, constant: -6),
                ocr.trailingAnchor.constraint(equalTo: hover.trailingAnchor, constant: -6),
            ]
        } else {
            let open = icon("play.fill", "Open", #selector(openAction))
            let reveal = icon("folder", "Show in Finder", #selector(revealAction))
            [open, reveal].forEach(hover.addSubview)
            if panel.fileURL()?.pathExtension.lowercased() != "gif" {
                let edit = icon("scissors", "Edit video", #selector(editVideoAction))
                let compress = icon("arrow.down.right.and.arrow.up.left", "Compress (keep quality)", #selector(compressAction))
                hover.addSubview(edit)
                hover.addSubview(compress)
                constraints += [
                    compress.bottomAnchor.constraint(equalTo: hover.bottomAnchor, constant: -6),
                    compress.centerXAnchor.constraint(equalTo: hover.centerXAnchor),
                    edit.bottomAnchor.constraint(equalTo: hover.bottomAnchor, constant: -6),
                    edit.leadingAnchor.constraint(equalTo: hover.leadingAnchor, constant: 6),
                ]
            }
            constraints += [
                open.topAnchor.constraint(equalTo: hover.topAnchor, constant: 6),
                open.trailingAnchor.constraint(equalTo: hover.trailingAnchor, constant: -6),
                reveal.bottomAnchor.constraint(equalTo: hover.bottomAnchor, constant: -6),
                reveal.trailingAnchor.constraint(equalTo: hover.trailingAnchor, constant: -6),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func pill(_ title: String, _ action: Selector) -> NSButton {
        let b = FirstMouseButton(title: title, target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        b.layer?.cornerRadius = 13
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.black, .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 84).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    private func icon(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let b = FirstMouseButton(image: img, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        b.layer?.cornerRadius = 12
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) {
        panel.pauseAutoClose()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; hover.animator().alphaValue = 1 }
    }

    override func mouseExited(with event: NSEvent) {
        panel.scheduleAutoClose()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; hover.animator().alphaValue = 0 }
    }

    // MARK: Drag out

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        if event.clickCount == 2 { panel.isImage ? annotateAction() : openAction() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        downEvent = nil
        guard let url = panel.fileURL() else { return }
        optionDrag = event.modifierFlags.contains(.option)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let img = panel.thumbnail.map { NSImage(cgImage: $0, size: bounds.size) } ?? NSImage()
        item.setDraggingFrame(bounds, contents: img)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let keep = optionDrag || NSEvent.modifierFlags.contains(.option)
        if !operation.isEmpty && Prefs.bool("qa.closeAfterDrag") && !keep { panel.dismiss() }
    }

    // MARK: Actions

    @objc private func copyAction() { panel.copyItem(); panel.dismiss() }

    @objc private func saveAction() {
        let askPref = Prefs.int("qa.saveBehavior") == 1
        let ask = askPref != NSEvent.modifierFlags.contains(.option)
        if panel.save(ask: ask) != nil { panel.dismiss() }
    }

    @objc private func annotateAction() {
        if case .image(let c, _) = panel.item { EditorWindowController.open(c) }
        panel.dismiss()
    }

    @objc private func pinAction() {
        if case .image(let c, _) = panel.item { PinPanel.show(c) }
        panel.dismiss()
    }

    @objc private func ocrAction() {
        if case .image(let c, _) = panel.item { OCR.recognize(c) }
    }

    @objc private func openAction() {
        if let url = panel.fileURL() { NSWorkspace.shared.open(url) }
    }

    @objc private func uploadAction() {
        switch panel.item {
        case .image(let c, let saved): if let saved { Cloud.upload(file: saved) } else { Cloud.upload(c) }
        case .file(let url, _, _, _): Cloud.upload(file: url)
        }
    }

    @objc private func compressAction() {
        guard let url = panel.save(ask: false) ?? panel.fileURL() else { return }
        VideoCompressor.run(url)
    }

    @objc private func editVideoAction() {
        guard let url = panel.fileURL() else { return }
        panel.dismiss()
        VideoEditorWindowController.edit(url)
    }

    @objc private func revealAction() {
        if let url = panel.fileURL() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func closeAction() { panel.dismiss() }
}
