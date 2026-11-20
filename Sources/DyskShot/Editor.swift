import AppKit
import UniformTypeIdentifiers

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [EditorWindowController] = []

    let doc: AnnotationDocument
    let canvas: CanvasView
    private let container: CanvasContainer
    private let scrollView = NSScrollView()
    private let onDone: ((Capture) -> Void)?

    private var toolStrip: ToolStrip!
    private var colorPopup: NSPopUpButton!
    private var widthPopup: NSPopUpButton!
    private var arrowPopup: NSPopUpButton!
    private var zoomPopup: NSPopUpButton!
    private var cropButton: NSButton!
    private var backgroundButton: NSButton!
    private let backgroundPopover = NSPopover()

    static let palette: [(String, NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen),
        ("Blue", .systemBlue), ("Purple", .systemPurple), ("Pink", .systemPink), ("Black", .black), ("White", .white),
    ]
    static let widths: [(String, CGFloat)] = [("Thin", 2), ("Medium", 4), ("Thick", 7), ("Extra Thick", 10)]
    static let zooms: [(String, CGFloat?)] = [("Fit", nil), ("50%", 0.5), ("100%", 1), ("150%", 1.5), ("200%", 2), ("400%", 4)]

    static func open(_ capture: Capture, onDone: ((Capture) -> Void)? = nil) {
        let c = EditorWindowController(capture: capture, onDone: onDone)
        openEditors.append(c)
        updateDockIcon()
        c.window?.center()
        NSApp.activate()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.window?.makeFirstResponder(c.canvas)
    }

    static func updateDockIcon() {
        let regular = Prefs.bool("ann.dockIcon") && !openEditors.isEmpty
        NSApp.setActivationPolicy(regular ? .regular : .accessory)
        if regular { NSApp.activate() }
    }

    init(capture: Capture, onDone: ((Capture) -> Void)?) {
        let doc = AnnotationDocument(capture: capture)
        if Prefs.bool("ann.rememberBackground"), Prefs.int("ann.lastBackground") > 0 {
            doc.background = BackgroundStyle(rawValue: Prefs.int("ann.lastBackground") - 1)
        }
        doc.paddingFactor = CGFloat(Prefs.double("ann.bgPadding"))
        self.doc = doc
        self.onDone = onDone
        canvas = CanvasView(doc: doc)
        container = CanvasContainer(canvas: canvas)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "DyskShot — Annotate"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1040, height: 460)
        if Prefs.bool("ann.onTop") { window.level = .floating }
        super.init(window: window)
        window.delegate = self
        buildUI()
        sizeToFit()
        canvas.onToolChange = { [weak self] t in self?.toolStrip.selected = t.rawValue; self?.refreshControls() }
        canvas.onChange = { [weak self] in self?.documentChanged() }
        canvas.onCropModeChange = { [weak self] on in self?.cropButton.state = on ? .on : .off }
        canvas.copyHandler = { [weak self] in self?.copyAction() }
        canvas.saveHandler = { [weak self] in self?.quickSave() }
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.openEditors.removeAll { $0 === self }
        Self.updateDockIcon()
    }

    // MARK: Layout

    private func buildUI() {
        guard let window else { return }
        let root = NSView()
        let top = makeTopBar()
        let bottom = makeBottomBar()

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.13, alpha: 1)
        scrollView.documentView = container
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutCanvas() }
        }

        for v in [scrollView, top, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            top.heightAnchor.constraint(equalToConstant: 58),
            scrollView.topAnchor.constraint(equalTo: top.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 52),
        ])
        window.contentView = root
        window.appearance = NSAppearance(named: .darkAqua)
    }

    private func makeTopBar() -> NSView {
        cropButton = BarButton(symbol: "crop", tip: "Crop (C)", target: self, action: #selector(cropAction), toggle: true)
        backgroundButton = BarButton(symbol: "photo.on.rectangle.angled", tip: "Background", target: self, action: #selector(backgroundAction), toggle: true)
        let leftGroup = Pill([cropButton, backgroundButton])

        toolStrip = ToolStrip(tools: Tool.allCases.map { ($0.symbol, "\($0.name) (\($0.shortcut.uppercased()))") }) { [weak self] _ in
            self?.toolChanged()
        }
        toolStrip.selected = canvas.tool.rawValue

        colorPopup = pullDown(#selector(colorPicked(_:)), tip: "Color")
        for (name, c) in Self.palette {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.image = Self.swatch(c)
            item.representedObject = c
            colorPopup.menu?.addItem(item)
        }
        colorPopup.menu?.addItem(.separator())
        colorPopup.addItem(withTitle: "Custom…")

        widthPopup = pullDown(#selector(widthPicked(_:)), tip: "Line width")
        for (i, (name, w)) in Self.widths.enumerated() {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.image = Self.lineImage(w)
            item.tag = i
            widthPopup.menu?.addItem(item)
        }

        arrowPopup = pullDown(#selector(arrowPicked(_:)), tip: "Arrow style")
        for s in ArrowStyle.allCases {
            let item = NSMenuItem(title: s.name, action: nil, keyEquivalent: "")
            item.image = Self.arrowImage(s)
            item.tag = s.rawValue
            arrowPopup.menu?.addItem(item)
        }
        let styleGroup = Pill([colorPopup, widthPopup, arrowPopup])

        let saveAs = NSButton(title: "Save as…", target: self, action: #selector(saveAsAction))
        saveAs.keyEquivalent = "s"
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        let done = NSButton(title: "Done", target: self, action: #selector(doneAction))
        done.bezelColor = .controlAccentColor
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = .command
        for b in [saveAs, done] { b.controlSize = .regular; b.bezelStyle = .push }
        done.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true

        let center = NSStackView(views: [toolStrip, styleGroup])
        center.spacing = 10
        let right = NSStackView(views: [saveAs, done])
        right.spacing = 8

        let bar = DraggableBar()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        for v in [leftGroup, center, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        let centered = center.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
        centered.priority = .defaultLow
        NSLayoutConstraint.activate([
            leftGroup.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 84),
            leftGroup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            centered,
            center.leadingAnchor.constraint(greaterThanOrEqualTo: leftGroup.trailingAnchor, constant: 16),
            center.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -16),
            center.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func makeBottomBar() -> NSView {
        zoomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        zoomPopup.addItems(withTitles: Self.zooms.map(\.0))
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomChanged)
        zoomPopup.toolTip = "Zoom"
        zoomPopup.isBordered = false
        zoomPopup.font = .systemFont(ofSize: 12, weight: .medium)
        let zoomPill = Pill([zoomPopup])

        let drag = DragMeView { [weak self] in self?.doc.export() }

        let upload = BarButton(symbol: "icloud.and.arrow.up", tip: "Upload to Google Drive (⌘U)", target: self, action: #selector(uploadAction))
        upload.keyEquivalent = "u"
        upload.keyEquivalentModifierMask = .command
        let share = BarButton(symbol: "square.and.arrow.up", tip: "Share", target: self, action: #selector(shareAction(_:)))
        let pin = BarButton(symbol: "pin", tip: "Pin to screen", target: self, action: #selector(pinAction))
        let copy = BarButton(symbol: "doc.on.doc", tip: "Copy (⌘C)", target: self, action: #selector(copyAction))

        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        let right = Pill([upload, share, pin, copy])
        for v in [zoomPill, drag, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            zoomPill.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            zoomPill.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            drag.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            drag.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func pullDown(_ action: Selector, tip: String) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: true)
        p.addItem(withTitle: "")
        p.target = self
        p.action = action
        p.isBordered = false
        p.toolTip = tip
        p.imagePosition = .imageOnly
        (p.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        p.translatesAutoresizingMaskIntoConstraints = false
        p.widthAnchor.constraint(equalToConstant: 46).isActive = true
        p.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return p
    }

    private func sizeToFit() {
        guard let window, let screen = NSScreen.underMouse ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let c = doc.canvasSize
        let w = min(max(c.width + 80, 1040), vf.width * 0.92)
        let h = min(max(c.height + 58 + 52 + 64, 460), vf.height * 0.92)
        window.setContentSize(NSSize(width: w, height: h))
    }

    private func relayoutCanvas() {
        container.relayout(clip: scrollView.contentView.bounds.size)
        if container.zoom == nil {
            let pct = Int((canvas.frame.width / max(doc.canvasSize.width, 1) * 100).rounded())
            zoomPopup.item(at: 0)?.title = "Fit (\(pct)%)"
            zoomPopup.synchronizeTitleAndSelectedItem()
        }
    }

    // MARK: State

    private func documentChanged() {
        relayoutCanvas()
        refreshControls()
    }

    private func refreshControls() {
        let color = canvas.selectedAnnotation?.color ?? canvas.color
        colorPopup.item(at: 0)?.image = Self.swatch(color)
        let width = canvas.selectedAnnotation?.width ?? canvas.lineWidth
        widthPopup.item(at: 0)?.image = Self.lineImage(width)
        let style = canvas.selectedAnnotation?.arrowStyle ?? canvas.arrowStyle
        arrowPopup.item(at: 0)?.image = Self.arrowImage(style)
        arrowPopup.isEnabled = canvas.tool == .arrow || canvas.selectedAnnotation?.tool == .arrow
        backgroundButton.state = doc.background == nil ? .off : .on
    }

    // MARK: Actions

    @objc private func toolChanged() {
        if let t = Tool(rawValue: toolStrip.selected) { canvas.setTool(t) }
        refreshControls()
    }

    @objc private func colorPicked(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        if let c = item.representedObject as? NSColor {
            canvas.applyColor(c)
        } else if item.title == "Custom…" {
            let panel = NSColorPanel.shared
            panel.setTarget(self)
            panel.setAction(#selector(customColor(_:)))
            panel.color = canvas.color
            panel.orderFront(nil)
        }
        refreshControls()
    }

    @objc private func customColor(_ sender: NSColorPanel) {
        canvas.applyColor(sender.color)
        refreshControls()
    }

    @objc private func widthPicked(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, item.tag >= 0, item.tag < Self.widths.count, sender.indexOfSelectedItem > 0 else { return }
        canvas.applyWidth(Self.widths[item.tag].1)
        refreshControls()
    }

    @objc private func arrowPicked(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0, let style = ArrowStyle(rawValue: sender.selectedItem?.tag ?? 0) else { return }
        canvas.applyArrowStyle(style)
        refreshControls()
    }

    @objc private func cropAction() { canvas.toggleCrop() }

    @objc private func backgroundAction() {
        backgroundButton.state = doc.background == nil ? .off : .on
        if backgroundPopover.isShown { backgroundPopover.close(); return }
        let vc = BackgroundPicker(doc: doc) { [weak self] in
            self?.canvas.documentGeometryChanged()
            self?.documentChanged()
        }
        backgroundPopover.contentViewController = vc
        backgroundPopover.behavior = .transient
        backgroundPopover.show(relativeTo: backgroundButton.bounds, of: backgroundButton, preferredEdge: .maxY)
    }

    @objc private func zoomChanged() {
        container.zoom = Self.zooms[zoomPopup.indexOfSelectedItem].1
        relayoutCanvas()
    }

    @objc private func shareAction(_ sender: NSButton) {
        canvas.commitText()
        guard let c = doc.export(), let url = Output.tempFile(c) else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func uploadAction() {
        canvas.commitText()
        if let c = doc.export() { Cloud.upload(c) }
    }

    @objc private func pinAction() {
        canvas.commitText()
        if let c = doc.export() { PinPanel.show(c) }
    }

    @objc private func copyAction() {
        canvas.commitText()
        guard let c = doc.export() else { return }
        Output.copy(c)
        Toast.show("Copied to clipboard")
    }

    private func quickSave() {
        canvas.commitText()
        guard let c = doc.export(), let url = Output.save(c) else { return }
        Toast.show("Saved \(url.lastPathComponent)")
    }

    @objc private func saveAsAction() {
        canvas.commitText()
        guard let c = doc.export(), let url = Output.save(c, ask: true) else { return }
        Toast.show("Saved \(url.lastPathComponent)")
    }

    @objc private func doneAction() {
        canvas.commitText()
        if canvas.cropMode { canvas.toggleCrop() }
        guard let c = doc.export() else { return }
        window?.close()
        if let onDone { onDone(c) } else { QuickAccessManager.shared.show(.image(c, saved: nil)) }
    }

    // MARK: Icons

    static func swatch(_ c: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill()
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
            p.lineWidth = 1
            p.stroke()
            return true
        }
        return img
    }

    static func lineImage(_ w: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { r in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 3, y: 3))
            p.line(to: NSPoint(x: r.width - 3, y: r.height - 3))
            p.lineWidth = max(1, w * 0.6)
            p.lineCapStyle = .round
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    static func arrowImage(_ s: ArrowStyle) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { r in
            NSColor.black.set()
            Renderer.drawArrow(from: NSPoint(x: r.width - 3, y: r.height - 3), to: NSPoint(x: 3, y: 3), width: 2.2, style: s)
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Titlebar-area bar that still lets the user drag the window.
/// Rounded translucent container grouping toolbar controls.
class Pill: NSView {
    init(_ views: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        let stack = NSStackView(views: views)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Borderless icon button with hover + selected highlight.
final class BarButton: NSButton {
    private let isToggle: Bool
    private var hovering = false { didSet { refresh() } }
    var isSelected = false { didSet { refresh() } }

    init(symbol: String, tip: String, target: AnyObject?, action: Selector?, toggle: Bool = false) {
        isToggle = toggle
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 28))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        imagePosition = .imageOnly
        isBordered = false
        toolTip = tip
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var state: NSControl.StateValue {
        get { isSelected ? .on : .off }
        set { if isToggle { isSelected = newValue == .on } }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func refresh() {
        let bg: NSColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.9)
            : (hovering ? NSColor(white: 1, alpha: 0.10) : .clear)
        layer?.backgroundColor = bg.cgColor
        contentTintColor = isSelected ? .white : NSColor(white: 1, alpha: 0.82)
    }
}

/// Single-selection row of tool buttons.
@MainActor
final class ToolStrip: Pill {
    private var buttons: [BarButton] = []
    private let onChange: (Int) -> Void
    var selected: Int = 0 { didSet { buttons.enumerated().forEach { $0.element.isSelected = $0.offset == selected } } }

    init(tools: [(symbol: String, tip: String)], onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        let proxy = Proxy()
        let bs = tools.enumerated().map { i, t -> BarButton in
            let b = BarButton(symbol: t.symbol, tip: t.tip, target: proxy, action: #selector(Proxy.fire(_:)))
            b.tag = i
            return b
        }
        buttons = bs
        super.init(bs)
        proxy.owner = self
        self.proxy = proxy
    }

    required init?(coder: NSCoder) { fatalError() }

    private var proxy: Proxy?

    fileprivate func pick(_ i: Int) {
        selected = i
        onChange(i)
    }

    private final class Proxy: NSObject {
        weak var owner: ToolStrip?
        @objc func fire(_ sender: NSButton) { MainActor.assumeIsolated { owner?.pick(sender.tag) } }
    }
}

final class DraggableBar: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - Background popover

@MainActor
final class BackgroundPicker: NSViewController {
    private let doc: AnnotationDocument
    private let onChange: () -> Void
    private var buttons: [NSButton] = []

    init(doc: AnnotationDocument, onChange: @escaping () -> Void) {
        self.doc = doc
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let none = NSButton(title: "None", target: self, action: #selector(pick(_:)))
        none.tag = -1
        buttons = [none]
        for s in BackgroundStyle.allCases {
            let b = NSButton(image: s.swatch(size: NSSize(width: 40, height: 28)), target: self, action: #selector(pick(_:)))
            b.isBordered = false
            b.tag = s.rawValue
            b.toolTip = s.name
            b.wantsLayer = true
            b.layer?.cornerRadius = 7
            b.layer?.borderWidth = 2
            buttons.append(b)
        }
        let row1 = NSStackView(views: Array(buttons.prefix(4)))
        let row2 = NSStackView(views: Array(buttons.dropFirst(4)))
        let slider = NSSlider(value: Double(doc.paddingFactor), minValue: 0, maxValue: 1, target: self, action: #selector(paddingChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let padRow = NSStackView(views: [NSTextField(labelWithString: "Padding"), slider])
        let stack = NSStackView(views: [row1, row2, padRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view = stack
        refresh()
    }

    private func refresh() {
        for b in buttons where b.tag >= 0 {
            b.layer?.borderColor = (doc.background?.rawValue == b.tag ? NSColor.controlAccentColor : NSColor.clear).cgColor
        }
    }

    @objc private func pick(_ sender: NSButton) {
        let bg = sender.tag < 0 ? nil : BackgroundStyle(rawValue: sender.tag)
        doc.setBackground(bg)
        Prefs.d.set(bg.map { $0.rawValue + 1 } ?? 0, forKey: "ann.lastBackground")
        refresh()
        onChange()
    }

    @objc private func paddingChanged(_ sender: NSSlider) {
        doc.paddingFactor = CGFloat(sender.doubleValue)
        Prefs.d.set(sender.doubleValue, forKey: "ann.bgPadding")
        onChange()
    }
}

// MARK: - "Drag Me" handle

final class DragMeView: NSView, NSDraggingSource {
    private let provider: () -> Capture?

    init(provider: @escaping () -> Capture?) {
        self.provider = provider
        super.init(frame: NSRect(x: 0, y: 0, width: 170, height: 32))
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.2).cgColor
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        let grip1 = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil) ?? NSImage())
        let grip2 = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil) ?? NSImage())
        [grip1, grip2].forEach { $0.contentTintColor = .tertiaryLabelColor }
        let label = NSTextField(labelWithString: "Drag Me")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let stack = NSStackView(views: [grip1, label, grip2])
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 170), heightAnchor.constraint(equalToConstant: 32),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "Drag the annotated image into any app"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let result: (URL, NSImage)? = MainActor.assumeIsolated {
            guard let c = provider(), let url = Output.tempFile(c) else { return nil }
            return (url, c.nsImage)
        }
        guard let (url, img) = result else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let size = img.size
        let r = min(160 / max(size.width, 1), 120 / max(size.height, 1), 1)
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: size.width * r, height: size.height * r), contents: img)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

// MARK: - Canvas container (zoom / fit, centered)

final class CanvasContainer: NSView {
    let canvas: CanvasView
    var zoom: CGFloat?

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        addSubview(canvas)
        canvas.wantsLayer = true
        canvas.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 16
            s.shadowColor = NSColor.black.withAlphaComponent(0.5)
            s.shadowOffset = NSSize(width: 0, height: -4)
            return s
        }()
    }

    required init?(coder: NSCoder) { fatalError() }

    func relayout(clip: NSSize) {
        let margin: CGFloat = 40
        let s = canvas.doc.canvasSize
        guard s.width > 0, s.height > 0, clip.width > 0, clip.height > 0 else { return }
        let scale = zoom ?? max(0.05, min((clip.width - margin * 2) / s.width, (clip.height - margin * 2) / s.height, 1))
        let size = NSSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
        let docSize = NSSize(width: max(clip.width, size.width + margin * 2), height: max(clip.height, size.height + margin * 2))
        setFrameSize(docSize)
        canvas.frame = NSRect(x: ((docSize.width - size.width) / 2).rounded(), y: ((docSize.height - size.height) / 2).rounded(),
                              width: size.width, height: size.height)
    }
}

// MARK: - Canvas

/// Drawing surface. Bounds are always the canvas size in points, so the view scales automatically.
final class CanvasView: NSView, NSTextFieldDelegate {
    let doc: AnnotationDocument
    private(set) var tool: Tool = .arrow
    var color: NSColor = .systemRed { didSet { textField?.textColor = color } }
    var lineWidth: CGFloat = 4
    var arrowStyle: ArrowStyle = .tapered

    var onToolChange: ((Tool) -> Void)?
    var onChange: (() -> Void)?
    var onCropModeChange: ((Bool) -> Void)?
    var copyHandler: (() -> Void)?
    var saveHandler: (() -> Void)?

    private var current: Annotation?
    private var textField: NSTextField?
    private var textAnchor: CGPoint = .zero
    private var textWidth: CGFloat = 4

    private(set) var selected: Int? { didSet { needsDisplay = true } }
    private var dragOrigin: CGPoint?
    private var movedSinceDown = false

    private(set) var cropMode = false
    private var cropRect: CGRect = .zero
    private var cropHandle: RectHandle?
    private var cropStart: CGPoint = .zero
    private var newCrop = false

    var selectedAnnotation: Annotation? { selected.flatMap { doc.annotations[safe: $0] } }

    init(doc: AnnotationDocument) {
        self.doc = doc
        super.init(frame: NSRect(origin: .zero, size: doc.canvasSize))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 0, newSize.height > 0 { setBoundsSize(doc.canvasSize) }
        needsDisplay = true
    }

    private var viewScale: CGFloat { frame.width / max(bounds.width, 1) }

    func documentGeometryChanged() {
        commitText()
        if frame.width > 0 { setBoundsSize(doc.canvasSize) }
        needsDisplay = true
    }

    func setTool(_ t: Tool) {
        commitText()
        if cropMode { toggleCrop() }
        tool = t
        if t != .select { selected = nil }
        onToolChange?(t)
        window?.invalidateCursorRects(for: self)
    }

    func applyColor(_ c: NSColor) {
        color = c
        mutateSelected { $0.color = c }
    }

    func applyWidth(_ w: CGFloat) {
        lineWidth = w
        mutateSelected { $0.width = w }
    }

    func applyArrowStyle(_ s: ArrowStyle) {
        arrowStyle = s
        mutateSelected { if $0.tool == .arrow { $0.arrowStyle = s } }
    }

    private func mutateSelected(_ f: (inout Annotation) -> Void) {
        guard let i = selected, var a = doc.annotations[safe: i] else { return }
        doc.checkpoint()
        f(&a)
        doc.replace(at: i, with: a)
        changed()
    }

    override func resetCursorRects() {
        let cursor: NSCursor = cropMode ? .crosshair : (tool == .text ? .iBeam : (tool == .select ? .arrow : .crosshair))
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        Renderer.draw(doc, in: ctx, inProgress: current)
        let pad = doc.padding
        ctx.saveGState()
        ctx.translateBy(x: pad, y: pad)
        if let a = selectedAnnotation {
            let r = a.bounds.insetBy(dx: -4, dy: -4)
            let p = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            p.lineWidth = 1.5 / viewScale
            p.setLineDash([5 / viewScale, 3 / viewScale], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            p.stroke()
        }
        if cropMode {
            let img = CGRect(origin: .zero, size: doc.imageSize)
            let dim = NSBezierPath(rect: img)
            dim.appendRect(cropRect)
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            dim.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: cropRect)
            border.lineWidth = 1.5 / viewScale
            border.stroke()
            // rule of thirds
            let thirds = NSBezierPath()
            for i in 1...2 {
                let x = cropRect.minX + cropRect.width * CGFloat(i) / 3, y = cropRect.minY + cropRect.height * CGFloat(i) / 3
                thirds.move(to: CGPoint(x: x, y: cropRect.minY)); thirds.line(to: CGPoint(x: x, y: cropRect.maxY))
                thirds.move(to: CGPoint(x: cropRect.minX, y: y)); thirds.line(to: CGPoint(x: cropRect.maxX, y: y))
            }
            thirds.lineWidth = 0.75 / viewScale
            NSColor.white.withAlphaComponent(0.5).setStroke()
            thirds.stroke()
            RectHandle.drawHandles(cropRect, size: 10 / viewScale)
            let s = doc.capture.scale
            let label = NSAttributedString(string: "\(Int(cropRect.width * s)) × \(Int(cropRect.height * s))  ·  ↩ apply  ·  ⎋ cancel",
                                           attributes: [.font: NSFont.systemFont(ofSize: 11 / viewScale, weight: .medium),
                                                        .foregroundColor: NSColor.white])
            let ls = label.size()
            let lr = CGRect(x: cropRect.midX - ls.width / 2 - 6 / viewScale, y: cropRect.minY + 8 / viewScale,
                            width: ls.width + 12 / viewScale, height: ls.height + 4 / viewScale)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: lr, xRadius: 4 / viewScale, yRadius: 4 / viewScale).fill()
            label.draw(at: CGPoint(x: lr.minX + 6 / viewScale, y: lr.minY + 2 / viewScale))
        }
        ctx.restoreGState()
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x - doc.padding, y: p.y - doc.padding)
    }

    // MARK: Crop

    func toggleCrop() {
        commitText()
        if cropMode {
            cropMode = false
        } else {
            cropMode = true
            selected = nil
            cropRect = CGRect(origin: .zero, size: doc.imageSize)
        }
        onCropModeChange?(cropMode)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func applyCrop() {
        doc.crop(to: cropRect)
        cropMode = false
        onCropModeChange?(false)
        documentGeometryChanged()
        changed()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let hadText = textField != nil
        commitText()
        window?.makeFirstResponder(self)
        let p = imagePoint(event)

        if cropMode {
            cropHandle = RectHandle.hit(p, rect: cropRect, tolerance: 10 / viewScale)
            newCrop = cropHandle == nil
            cropStart = p
            dragOrigin = p
            return
        }

        switch tool {
        case .select:
            selected = doc.hitTest(p)
            dragOrigin = selected == nil ? nil : p
            movedSinceDown = false
            if event.clickCount == 2, let a = selectedAnnotation {
                color = a.color
                lineWidth = a.width
            }
            onChange?()
        case .text:
            if !hadText { beginText(at: p) }
        case .counter:
            var a = Annotation(tool: .counter, color: color, width: lineWidth, start: p, end: p)
            a.number = doc.nextCounter
            doc.add(a)
            changed()
        default:
            selected = nil
            current = Annotation(tool: tool, color: color, width: lineWidth, start: p, end: p, points: [p], arrowStyle: arrowStyle)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        if cropMode, let o = dragOrigin {
            let img = CGRect(origin: .zero, size: doc.imageSize)
            if newCrop {
                cropRect = CGRect(x: min(cropStart.x, p.x), y: min(cropStart.y, p.y),
                                  width: abs(p.x - cropStart.x), height: abs(p.y - cropStart.y)).intersection(img)
            } else if let h = cropHandle {
                cropRect = h.apply(to: cropRect, dx: p.x - o.x, dy: p.y - o.y, within: img, minSize: 8)
            }
            dragOrigin = p
            needsDisplay = true
            return
        }
        if tool == .select, let i = selected, let o = dragOrigin, var a = doc.annotations[safe: i] {
            if !movedSinceDown { doc.checkpoint(); movedSinceDown = true }
            a.translate(dx: p.x - o.x, dy: p.y - o.y)
            doc.replace(at: i, with: a)
            dragOrigin = p
            needsDisplay = true
            return
        }
        guard var a = current else { return }
        var q = p
        if event.modifierFlags.contains(.shift) { q = constrain(a.start, q, tool: a.tool) }
        a.end = q
        if a.tool == .pen || a.tool == .highlighter { a.points.append(q) }
        if a.tool == .arrow { a.reversed = Prefs.bool("ann.invertArrow") != event.modifierFlags.contains(.option) }
        current = a
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if cropMode {
            cropHandle = nil
            newCrop = false
            dragOrigin = nil
            if cropRect.width < 4 || cropRect.height < 4 { cropRect = CGRect(origin: .zero, size: doc.imageSize) }
            needsDisplay = true
            return
        }
        if tool == .select {
            dragOrigin = nil
            if movedSinceDown { changed() }
            return
        }
        if let a = current, a.isMeaningful { doc.add(a); changed() }
        current = nil
        needsDisplay = true
    }

    private func constrain(_ s: CGPoint, _ p: CGPoint, tool: Tool) -> CGPoint {
        let dx = p.x - s.x, dy = p.y - s.y
        switch tool {
        case .rect, .filledRect, .ellipse, .pixelate, .spotlight:
            let d = max(abs(dx), abs(dy))
            return CGPoint(x: s.x + (dx < 0 ? -d : d), y: s.y + (dy < 0 ? -d : d))
        case .line, .arrow:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let len = hypot(dx, dy)
            return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
        default:
            return p
        }
    }

    // MARK: Text

    private func beginText(at p: CGPoint) {
        textAnchor = p
        textWidth = lineWidth
        let font = NSFont.systemFont(ofSize: Renderer.fontSize(for: lineWidth), weight: .bold)
        let lineH = ceil(font.ascender - font.descender + font.leading)
        let f = NSTextField(frame: NSRect(x: p.x + doc.padding - 2, y: p.y + doc.padding - lineH / 2 - 1,
                                          width: max(120, doc.canvasSize.width - p.x - doc.padding), height: lineH + 2))
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = font
        f.textColor = color
        f.placeholderString = "Type…"
        f.delegate = self
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        addSubview(f)
        textField = f
        window?.makeFirstResponder(f)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func commitText() {
        guard let f = textField else { return }
        textField = nil
        let s = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.removeFromSuperview()
        if !s.isEmpty {
            var a = Annotation(tool: .text, color: f.textColor ?? color, width: textWidth, start: textAnchor, end: textAnchor)
            a.text = s
            doc.add(a)
            changed()
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Keyboard & menu actions

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 51, 117: // delete
            if let i = selected { doc.remove(at: i); selected = nil; changed() }
            return
        case 53: // esc
            if cropMode { toggleCrop() } else { selected = nil }
            return
        case 36, 76: // return
            if cropMode { applyCrop() }
            return
        default: break
        }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if chars == "c" { toggleCrop(); return }
            if let t = Tool.allCases.first(where: { $0.shortcut == chars }) { setTool(t); return }
        }
        super.keyDown(with: event)
    }

    @objc func undo(_ sender: Any?) { commitText(); selected = nil; doc.undo(); documentGeometryChanged(); changed() }
    @objc func redo(_ sender: Any?) { selected = nil; doc.redo(); documentGeometryChanged(); changed() }
    @objc func copy(_ sender: Any?) { copyHandler?() }
    @objc func saveDocument(_ sender: Any?) { saveHandler?() }
    @objc func delete(_ sender: Any?) { if let i = selected { doc.remove(at: i); selected = nil; changed() } }

    private func changed() {
        needsDisplay = true
        onChange?()
    }
}
