import AppKit
import ServiceManagement
import Vision

// MARK: - Form builder (label column right-aligned, controls left, bound to UserDefaults)

@MainActor
final class Form {
    let grid = NSGridView(numberOfColumns: 2, rows: 0)
    static let controller = NSUserDefaultsController.shared

    init() {
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
    }

    @discardableResult
    func row(_ label: String?, _ views: NSView...) -> NSGridRow {
        let l: NSView = label.map { NSTextField(labelWithString: $0) } ?? NSGridCell.emptyContentView
        let content: NSView
        if views.count == 1 {
            content = views[0]
        } else {
            let s = NSStackView(views: views)
            s.spacing = 8
            s.alignment = .firstBaseline
            content = s
        }
        return grid.addRow(with: [l, content])
    }

    func note(_ text: String) {
        let t = NSTextField(wrappingLabelWithString: text)
        t.textColor = .secondaryLabelColor
        t.font = .systemFont(ofSize: 11)
        t.preferredMaxLayoutWidth = 340
        let r = row(nil, t)
        r.topPadding = -4
    }

    func separator() {
        let box = NSBox()
        box.boxType = .separator
        let r = grid.addRow(with: [box, NSGridCell.emptyContentView])
        r.mergeCells(in: NSRange(location: 0, length: 2))
        r.topPadding = 8
        r.bottomPadding = 8
        r.cell(at: 0).xPlacement = .fill
    }

    func view(width: CGFloat = 740) -> NSView {
        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor, constant: -30),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
        ])
        return container
    }

    // Bound controls

    static func check(_ title: String, _ key: String) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.bind(.value, to: controller, withKeyPath: "values.\(key)", options: nil)
        return b
    }

    static func popup(_ items: [String], _ key: String) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items)
        p.bind(.selectedIndex, to: controller, withKeyPath: "values.\(key)", options: nil)
        return p
    }

    static func slider(_ key: String, min: Double, max: Double, ticks: Int = 0, width: CGFloat = 240) -> NSSlider {
        let s = NSSlider(value: min, minValue: min, maxValue: max, target: nil, action: nil)
        s.numberOfTickMarks = ticks
        s.allowsTickMarkValuesOnly = ticks > 0
        s.bind(.value, to: controller, withKeyPath: "values.\(key)", options: nil)
        s.widthAnchor.constraint(equalToConstant: width).isActive = true
        return s
    }

    static func radio(_ title: String, _ key: String, value: Int, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(radioButtonWithTitle: title, target: target, action: action)
        b.tag = value
        b.identifier = NSUserInterfaceItemIdentifier(key)
        b.state = Prefs.int(key) == value ? .on : .off
        return b
    }

    static func secondary(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = .secondaryLabelColor
        return l
    }
}

// MARK: - Window

@MainActor
final class PreferencesWindow: NSObject, NSWindowDelegate {
    private static var shared: PreferencesWindow?
    private let window: NSWindow
    static let cloudTab = 7
    private let tabs = PrefsTabController()
    let panes = PrefPanes()

    static func show(tab: Int? = nil) {
        let first = shared == nil
        if first { shared = PreferencesWindow() }
        guard let s = shared else { return }
        if let tab, tab < s.tabs.tabViewItems.count { s.tabs.selectedTabViewItemIndex = tab }
        if first { s.window.center() }
        // Menu-bar (accessory) apps are often refused by cooperative activation; force it.
        NSApp.activate(ignoringOtherApps: true)
        if s.window.isMiniaturized { s.window.deminiaturize(nil) }
        s.window.orderFrontRegardless()
        s.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentViewController: tabs)
        super.init()
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self

        let items: [(String, String, NSView)] = [
            ("General", "gearshape", panes.general()),
            ("Wallpaper", "photo.on.rectangle", panes.wallpaper()),
            ("Shortcuts", "command.square", panes.shortcuts()),
            ("Quick Access", "rectangle.stack", panes.quickAccess()),
            ("Recording", "video", panes.recording()),
            ("Screenshots", "camera", panes.screenshots()),
            ("Annotate", "pencil.tip", panes.annotate()),
            ("Cloud", "icloud", panes.cloud()),
            ("Advanced", "wrench.and.screwdriver", panes.advanced()),
            ("About", "info.circle", panes.about()),
        ]
        for (title, symbol, view) in items {
            let vc = NSViewController()
            vc.view = view
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        tabs.tabStyle = .toolbar
        tabs.onSelect = { [weak self] in self?.fitWindow(animated: true) }
        tabs.selectedTabViewItemIndex = 0
        fitWindow(animated: false)
        window.center()
        NotificationCenter.default.addObserver(forName: .prefsPaneResized, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitWindow(animated: true) }
        }
    }

    static func debugRender(to dir: String) {
        show()
        guard let s = shared else { return }
        for (i, item) in s.tabs.tabViewItems.enumerated() {
            s.tabs.selectedTabViewItemIndex = i
            s.fitWindow(animated: false)
            guard let v = s.window.contentView?.superview else { continue }
            v.layoutSubtreeIfNeeded()
            v.display()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(i)-\(item.label).png"))
        }
        // Recording sub-tabs
        s.tabs.selectedTabViewItemIndex = 4
        for sub in [1, 2] {
            s.panes.debugShowRecordingTab(sub)
            s.fitWindow(animated: false)
            guard let v = s.window.contentView?.superview else { continue }
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/4-Recording-\(sub).png"))
        }
        s.panes.debugShowRecordingTab(0)
    }

    private func fitWindow(animated: Bool) {
        guard let item = tabs.tabViewItems[safe: tabs.selectedTabViewItemIndex], let view = item.viewController?.view else { return }
        window.title = item.label
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let contentRect = window.contentRect(forFrameRect: window.frame)
        let newFrame = window.frameRect(forContentRect: NSRect(x: contentRect.minX, y: contentRect.maxY - size.height,
                                                               width: size.width, height: size.height))
        window.setFrame(newFrame, display: true, animate: animated && window.isVisible)
    }
}

final class PrefsTabController: NSTabViewController {
    var onSelect: (() -> Void)?
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?()
    }
}

extension Notification.Name {
    static let prefsPaneResized = Notification.Name("DyskShotPrefsPaneResized")
    static let prefsAppearanceChanged = Notification.Name("DyskShotPrefsAppearanceChanged")
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Panes

@MainActor
final class PrefPanes: NSObject {
    private var exportPopup: NSPopUpButton!
    private var videoPopup: NSPopUpButton!
    private var wallpaperPopup: NSPopUpButton!
    private var plainWell: NSColorWell!
    private var wallpaperRadios: [NSButton] = []
    private var windowStyleButtons: [NSButton] = []
    private var recordingContainer: NSView!
    private var recordingSubviews: [NSView] = []
    private var recordingConstraints: [NSLayoutConstraint] = []

    // General

    func general() -> NSView {
        let f = Form()
        let login = NSButton(checkboxWithTitle: "Start at login", target: self, action: #selector(toggleLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        f.row("Startup:", login)
        f.row("Sounds:", Form.check("Play sounds", "playSounds"))
        let sound = Form.popup(Prefs.shutterSounds, "shutterSound")
        sound.target = self
        sound.action = #selector(previewSound)
        f.row(nil, Form.secondary("Shutter sound:"), sound)
        f.row("Menu bar:", Form.check("Show icon", "showMenuBarIcon"))
        f.note("When hidden, open DyskShot again from Finder/Spotlight to show Settings.")
        f.separator()

        exportPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        exportPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        videoPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        videoPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        refreshExportPopups()
        let shotLabel = Form.secondary("Screenshots:"), videoLabel = Form.secondary("Recordings:")
        for l in [shotLabel, videoLabel] {
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 92).isActive = true
        }
        f.row("Export location:", shotLabel, exportPopup)
        f.row(nil, videoLabel, videoPopup)
        f.row("Desktop icons:", Form.check("Hide while capturing", "hideDesktopIcons"))
        f.separator()

        f.row("After capture:", NSTextField(wrappingLabelWithString: "Choose what happens after taking a screenshot or recording a video.").secondaryStyled())
        f.row(nil, afterCaptureTable())
        return f.view()
    }

    private func afterCaptureTable() -> NSView {
        let g = NSGridView(numberOfColumns: 3, rows: 0)
        g.rowSpacing = 8
        g.columnSpacing = 18
        g.column(at: 0).xPlacement = .center
        g.column(at: 1).xPlacement = .center
        let h1 = NSTextField(labelWithString: "Screenshot"), h2 = NSTextField(labelWithString: "Recording"), h3 = NSTextField(labelWithString: "Action")
        [h1, h2, h3].forEach { $0.font = .systemFont(ofSize: 12, weight: .semibold) }
        g.addRow(with: [h1, h2, h3])
        let rows: [(String, String?, String?)] = [
            ("Show Quick Access Overlay", "after.shot.quick", "after.rec.quick"),
            ("Copy file to clipboard", "after.shot.copy", "after.rec.copy"),
            ("Save", "after.shot.save", "after.rec.save"),
            ("Open Annotate tool", "after.shot.annotate", nil),
            ("Pin to the screen", "after.shot.pin", nil),
            ("Upload to Cloud", "after.shot.upload", "after.rec.upload"),
            ("Open video", nil, "after.rec.open"),
            ("Open Video Editor", nil, "after.rec.edit"),
        ]
        for (title, shot, rec) in rows {
            g.addRow(with: [shot.map { Form.check("", $0) } ?? Form.secondary("–"),
                            rec.map { Form.check("", $0) } ?? Form.secondary("–"),
                            NSTextField(labelWithString: title)])
        }
        return g
    }

    private func refreshExportPopups() {
        fill(exportPopup, dir: Prefs.exportDirectory, sameOption: false)
        fill(videoPopup, dir: Prefs.videoDirectory, sameOption: true)
    }

    private func fill(_ popup: NSPopUpButton, dir: URL, sameOption: Bool) {
        popup.removeAllItems()
        let same = sameOption && Prefs.videoUsesScreenshotFolder
        popup.addItem(withTitle: same ? "Same as screenshots" : dir.path)
        popup.item(at: 0)?.image = {
            let i = NSWorkspace.shared.icon(forFile: dir.path)
            i.size = NSSize(width: 16, height: 16)
            return i
        }()
        popup.item(at: 0)?.toolTip = dir.path
        popup.menu?.addItem(.separator())
        if sameOption && !same { popup.addItem(withTitle: "Same as screenshots") }
        popup.addItem(withTitle: "Show in Finder")
        popup.addItem(withTitle: "Choose…")
        popup.target = self
        popup.action = #selector(exportChanged(_:))
        popup.selectItem(at: 0)
    }

    @objc private func exportChanged(_ sender: NSPopUpButton) {
        let isVideo = sender === videoPopup
        let title = sender.titleOfSelectedItem
        let current = isVideo ? Prefs.videoDirectory : Prefs.exportDirectory
        sender.selectItem(at: 0)
        switch title {
        case "Show in Finder":
            try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            NSWorkspace.shared.open(current)
        case "Same as screenshots":
            Prefs.d.set("", forKey: "videoExportPath")
            refreshExportPopups()
        case "Choose…":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = current
            if panel.runModal() == .OK, let url = panel.url {
                if isVideo { Prefs.videoDirectory = url } else { Prefs.exportDirectory = url }
            }
            refreshExportPopups()
        default:
            break
        }
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            Toast.show("Start at login failed", symbol: "xmark.octagon.fill")
        }
    }

    @objc private func previewSound() {
        DispatchQueue.main.async { MainActor.assumeIsolated { CaptureController.playShutter() } }
    }

    // Wallpaper

    func wallpaper() -> NSView {
        let f = Form()
        let header = NSTextField(wrappingLabelWithString: "Wallpaper shown when desktop icons are hidden, and behind window screenshots:")
        header.preferredMaxLayoutWidth = 360
        f.row(nil, header)
        let r0 = Form.radio("Desktop wallpaper", "wallpaperMode", value: 0, target: self, action: #selector(wallpaperModeChanged(_:)))
        let r1 = Form.radio("Custom wallpaper:", "wallpaperMode", value: 1, target: self, action: #selector(wallpaperModeChanged(_:)))
        let r2 = Form.radio("Plain color:", "wallpaperMode", value: 2, target: self, action: #selector(wallpaperModeChanged(_:)))
        wallpaperRadios = [r0, r1, r2]
        wallpaperPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        wallpaperPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        refreshWallpaperPopup()
        plainWell = NSColorWell(style: .default)
        plainWell.color = Prefs.plainColor
        plainWell.target = self
        plainWell.action = #selector(plainColorChanged)
        f.row(nil, r0)
        f.row(nil, r1, wallpaperPopup)
        f.row(nil, r2, plainWell)
        f.separator()

        let with = styleButton(title: "With wallpaper", transparent: false)
        let transparent = styleButton(title: "Transparent", transparent: true)
        windowStyleButtons = [with, transparent]
        refreshWindowStyle()
        f.row("Window screenshots:", with, transparent)
        f.note("Hold ⇧ Shift while clicking a window to use the other style.")
        let padding = Form.slider("windowPadding", min: 0, max: 1, ticks: 7)
        f.row("Padding:", padding)
        f.row("Shadow:", Form.check("Capture window shadow", "windowShadow"))
        f.note("Hold ⌥ Option while clicking a window to disable the shadow.")
        return f.view()
    }

    private func styleButton(title: String, transparent: Bool) -> NSButton {
        let img = NSImage(size: NSSize(width: 120, height: 84), flipped: false) { r in
            let bg = NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
            if transparent {
                NSColor(white: 0.35, alpha: 1).setFill()
                bg.fill()
                NSGraphicsContext.saveGraphicsState()
                bg.addClip()
                NSColor(white: 0.5, alpha: 1).setFill()
                let s: CGFloat = 10
                for x in stride(from: 0, to: r.width, by: s) {
                    for y in stride(from: 0, to: r.height, by: s) where Int(x / s + y / s) % 2 == 0 {
                        NSRect(x: x, y: y, width: s, height: s).fill()
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSGradient(colors: [.systemOrange, .systemPink])?.draw(in: bg, angle: -45)
            }
            let win = NSRect(x: 22, y: 18, width: 76, height: 48)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: win, xRadius: 5, yRadius: 5).fill()
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: win.minX + 6 + CGFloat(i) * 8, y: win.maxY - 9, width: 5, height: 5)).fill()
            }
            return true
        }
        let b = NSButton(title: title, image: img, target: self, action: #selector(windowStyleChanged(_:)))
        b.imagePosition = .imageAbove
        b.isBordered = false
        b.tag = transparent ? 0 : 1
        b.wantsLayer = true
        b.layer?.cornerRadius = 10
        b.layer?.borderWidth = 3
        return b
    }

    private func refreshWindowStyle() {
        let withWallpaper = Prefs.bool("windowWithWallpaper")
        for b in windowStyleButtons {
            let selected = (b.tag == 1) == withWallpaper
            b.layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
    }

    @objc private func windowStyleChanged(_ sender: NSButton) {
        Prefs.d.set(sender.tag == 1, forKey: "windowWithWallpaper")
        refreshWindowStyle()
    }

    @objc private func wallpaperModeChanged(_ sender: NSButton) {
        Prefs.d.set(sender.tag, forKey: "wallpaperMode")
        wallpaperRadios.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
        if sender.tag == 1 && Prefs.string("customWallpaperPath").isEmpty { chooseWallpaper() }
    }

    private func refreshWallpaperPopup() {
        wallpaperPopup.removeAllItems()
        let p = Prefs.string("customWallpaperPath")
        wallpaperPopup.addItem(withTitle: p.isEmpty ? "Choose…" : (p as NSString).lastPathComponent)
        if !p.isEmpty { wallpaperPopup.addItem(withTitle: "Choose…") }
        wallpaperPopup.target = self
        wallpaperPopup.action = #selector(wallpaperPopupChanged)
    }

    @objc private func wallpaperPopupChanged() {
        if wallpaperPopup.titleOfSelectedItem == "Choose…" { chooseWallpaper() }
        wallpaperPopup.selectItem(at: 0)
    }

    private func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            Prefs.d.set(url.path, forKey: "customWallpaperPath")
            Prefs.d.set(1, forKey: "wallpaperMode")
            wallpaperRadios.forEach { $0.state = $0.tag == 1 ? .on : .off }
        }
        refreshWallpaperPopup()
    }

    @objc private func plainColorChanged() { Prefs.plainColor = plainWell.color }

    // Shortcuts

    func shortcuts() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 16, right: 0)
        let rowWidth: CGFloat = 700

        func header(_ title: String, _ symbol: String) -> NSView {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            icon.contentTintColor = .controlAccentColor
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 15, weight: .bold)
            let h = NSStackView(views: [icon, label])
            h.spacing = 8
            h.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 8, right: 18)
            h.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            return h
        }
        var index = 0
        func row(_ title: String, _ control: NSView) -> NSView {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = (index % 2 == 0 ? NSColor.labelColor.withAlphaComponent(0.045) : NSColor.clear).cgColor
            v.layer?.cornerRadius = 6
            index += 1
            let label = NSTextField(labelWithString: "\(title):")
            [label, control].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; v.addSubview($0) }
            NSLayoutConstraint.activate([
                v.widthAnchor.constraint(equalToConstant: rowWidth),
                v.heightAnchor.constraint(equalToConstant: 34),
                label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 48),
                label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                control.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -18),
                control.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        }
        func fixedKey(_ keys: String) -> NSView {
            let l = NSTextField(labelWithString: keys)
            l.alignment = .center
            l.font = .systemFont(ofSize: 12, weight: .semibold)
            l.textColor = .secondaryLabelColor
            let box = NSView()
            box.wantsLayer = true
            box.layer?.cornerRadius = 5
            box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            box.toolTip = "Fixed shortcut"
            l.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(l)
            NSLayoutConstraint.activate([
                box.widthAnchor.constraint(equalToConstant: 150), box.heightAnchor.constraint(equalToConstant: 22),
                l.centerXAnchor.constraint(equalTo: box.centerXAnchor), l.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            ])
            return box
        }

        for section in HotAction.sections {
            stack.addArrangedSubview(header(section.title, section.symbol))
            index = 0
            for a in section.actions { stack.addArrangedSubview(row(a.title, ShortcutField(action: a))) }
            for (t, k) in section.fixed { stack.addArrangedSubview(row(t, fixedKey(k))) }
        }
        let note = NSTextField(wrappingLabelWithString: "Click a shortcut, then press the new key combination. Delete clears, Esc cancels. Grey shortcuts are fixed and only work inside that screen.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = rowWidth - 36
        let noteWrap = NSStackView(views: [note])
        noteWrap.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 0, right: 18)
        stack.addArrangedSubview(noteWrap)

        let doc = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        doc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 740),
            scroll.heightAnchor.constraint(equalToConstant: 560),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return scroll
    }

    // Quick Access

    func quickAccess() -> NSView {
        let f = Form()
        f.row("Position on screen:", Form.popup(["Left", "Right"], "qa.position"))
        f.row("Multi-display:", Form.check("Move to active screen", "qa.activeScreen"))
        f.note("The active screen is the one your cursor is on.")
        f.row("Overlay size:", Form.slider("qa.size", min: 0, max: 1, ticks: 5, width: 200))
        f.separator()
        f.row("Auto-close:", Form.check("Enable", "qa.autoClose"))
        f.row(nil, Form.secondary("Action:"), Form.popup(["Close", "Save and Close"], "qa.autoCloseAction"))
        f.row(nil, Form.secondary("Interval:"), Form.popup(Prefs.qaIntervals.map { "\($0) seconds" }, "qa.autoCloseInterval"))
        f.row("Drag & drop:", Form.check("Close after dragging", "qa.closeAfterDrag"))
        f.note("Hold ⌥ Option to keep the item on the overlay after dragging.")
        f.row("Save button behavior:", Form.popup(["Save to \"Export location\"", "Ask where to save"], "qa.saveBehavior"))
        f.note("Press with ⌥ Option to use the other behavior.")
        return f.view()
    }

    // Recording (General / Video / GIF)

    func recording() -> NSView {
        let general = Form()
        general.row("Controls:", Form.check("Show controls while recording", "rec.showControls"))
        general.row("Menu bar:", Form.check("Display recording time", "rec.menuBarTime"))
        general.row("Retina:", Form.check("Scale Retina videos to 1x", "rec.scale1x"))
        general.row("Cursor:", Form.check("Show cursor", "rec.showCursor"))
        general.row(nil, Form.check("Highlight clicks", "rec.highlightClicks"))
        general.row("Keyboard:", Form.check("Show keystrokes", "rec.showKeystrokes"))
        general.note("Showing keystrokes needs Accessibility permission.")
        general.row("Recording area:", Form.check("Remember last selection", "rec.rememberArea"))
        general.row(nil, Form.check("Dim screen while recording", "rec.dim"))
        general.row(nil, Form.check("Show countdown", "rec.countdown"))

        let video = Form()
        video.row("Max resolution:", Form.popup(["Original", "2160p (4K)", "1440p", "1080p", "720p", "480p"], "rec.maxRes"))
        video.note("Set maximum resolution to reduce file size and upload time.")
        video.row("Video FPS:", Form.popup(Prefs.recFPSValues.map { "\($0)" }, "rec.fps"))
        video.row("Quality:", Form.popup(["Low", "Medium", "High"], "rec.quality"))
        video.row("Codec:", Form.popup(["H.264 (compatible)", "HEVC (smaller files)"], "rec.codec"))
        video.row("Compression:", Form.check("Compress after recording (same quality)", "rec.autoCompress"))
        video.note("Re-encodes with HEVC at visually lossless quality; usually 40–80% smaller.")
        video.separator()
        video.row("Audio:", NSButton(title: "Computer Audio Settings…", target: self, action: #selector(openSoundSettings)))
        video.row(nil, Form.check("Record system audio", "rec.systemAudio"))
        video.row(nil, Form.check("Record microphone", "rec.mic"))
        video.row(nil, Form.check("Record audio in mono", "rec.mono"))
        video.separator()
        video.row("Video Encoder:", Form.check("Open Video Editor after recording", "after.rec.edit"))
        video.note("Use Video Editor to change the recording quality, resolution and adjust audio settings.")

        let gif = Form()
        let fpsField = NSTextField()
        fpsField.alignment = .center
        fpsField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        fpsField.formatter = { let n = NumberFormatter(); n.minimum = 5; n.maximum = 30; n.allowsFloats = false; return n }()
        fpsField.bind(.value, to: Form.controller, withKeyPath: "values.gif.fpsValue", options: nil)
        let fpsSlider = Form.slider("gif.fpsValue", min: 5, max: 30, width: 220)
        fpsSlider.isContinuous = true
        gif.row("GIF FPS:", fpsField, fpsSlider)
        let qSlider = Form.slider("gif.quality", min: 0, max: 10, ticks: 11, width: 200)
        let qLabels = NSStackView(views: [Form.secondary("Low"), NSView(), Form.secondary("High")])
        qLabels.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let qStack = NSStackView(views: [qSlider, qLabels])
        qStack.orientation = .vertical
        qStack.spacing = 2
        qStack.alignment = .leading
        let gq = gif.row("GIF quality:", qStack, Form.check("Optimize GIFs", "gif.optimize"))
        gq.yPlacement = .top
        gif.note("Lower quality uses fewer colours for smaller files. Optimize merges identical frames.")
        gif.row("GIF size:", Form.popup(["Original", "1280 × auto", "1024 × auto", "800 × auto (default)", "640 × auto", "480 × auto", "320 × auto"], "gif.size"))
        gif.note("Maximum width of your GIFs. DyskShot only downscales when needed.")
        gif.row("Loop:", Form.check("Loop forever", "gif.loop"))

        recordingSubviews = [general.view(width: 700), video.view(width: 700), gif.view(width: 700)]

        let seg = NSSegmentedControl(labels: ["General", "Video", "GIF"], trackingMode: .selectOne,
                                     target: self, action: #selector(recordingTabChanged(_:)))
        seg.selectedSegment = 0
        let box = NSBox()
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        recordingContainer = box.contentView

        let root = NSView()
        [seg, box].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 740),
            seg.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            seg.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            box.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 10),
            box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            box.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            box.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        showRecordingTab(0)
        return root
    }

    @objc private func recordingTabChanged(_ sender: NSSegmentedControl) {
        showRecordingTab(sender.selectedSegment)
        NotificationCenter.default.post(name: .prefsPaneResized, object: nil)
    }

    func debugShowRecordingTab(_ i: Int) { showRecordingTab(i) }

    private func showRecordingTab(_ i: Int) {
        NSLayoutConstraint.deactivate(recordingConstraints)
        recordingContainer.subviews.forEach { $0.removeFromSuperview() }
        let v = recordingSubviews[i]
        v.translatesAutoresizingMaskIntoConstraints = false
        recordingContainer.addSubview(v)
        recordingConstraints = [
            v.topAnchor.constraint(equalTo: recordingContainer.topAnchor),
            v.bottomAnchor.constraint(equalTo: recordingContainer.bottomAnchor),
            v.centerXAnchor.constraint(equalTo: recordingContainer.centerXAnchor),
        ]
        NSLayoutConstraint.activate(recordingConstraints)
    }

    // Screenshots

    func screenshots() -> NSView {
        let f = Form()
        f.row("File format:", Form.popup(Prefs.ImageFormat.allCases.map(\.title), "shot.format"))
        f.row("Retina:", Form.check("Scale Retina screenshots to 1x", "shot.scale1x"))
        f.row("Color management:", Form.check("Convert to sRGB profile", "shot.srgb"))
        f.row("Frame:", Form.check("Add 1px border to all screenshots", "shot.border"))
        f.row("Background:", Form.popup(["None"] + BackgroundStyle.allCases.map(\.name), "shot.background"))
        f.note("Apply a background preset to all screenshots. Hold ⇧ Shift while capturing to skip it.")
        f.separator()
        f.row("Self-Timer interval:", Form.popup(Prefs.selfTimerValues.map { "\($0) Seconds" }, "shot.selfTimer"))
        f.row("Cursor:", Form.check("Show on screenshots", "shot.showCursor"))
        f.note("Works in Fullscreen and Self-Timer modes only.")
        f.separator()
        f.row("Freeze screen:", Form.check("Freeze screen when taking a screenshot", "shot.freeze"))
        f.note("Captures hover states, menus, animations and fast-moving content.")
        f.row("Crosshair mode:", Form.popup(["Disabled", "Enabled"], "shot.crosshair"))
        f.row(nil, Form.check("Show magnifier", "shot.magnifier"))
        f.note("The magnifier is available when the screen is frozen.")
        return f.view()
    }

    // Annotate

    func annotate() -> NSView {
        let f = Form()
        f.row("Arrow tool:", Form.check("Inverse arrow direction", "ann.invertArrow"))
        f.note("Press ⌥ Option while drawing to invert the behavior.")
        f.row("Pencil tool:", Form.check("Smooth drawing", "ann.smooth"))
        f.row("Background tool:", Form.check("Remember last background", "ann.rememberBackground"))
        f.row("Shadow:", Form.check("Draw shadow on objects", "ann.shadow"))
        f.separator()
        f.row("Window:", Form.check("Always on top", "ann.onTop"))
        f.row(nil, Form.check("Show Dock icon", "ann.dockIcon"))
        return f.view()
    }

    @objc private func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    // Cloud (Google Drive)

    private var cloudStatus: NSTextField!
    private var cloudButton: NSButton!

    func cloud() -> NSView {
        let f = Form()
        let logo = NSImageView(image: NSImage(systemSymbolName: "externaldrive.fill.badge.icloud", accessibilityDescription: nil) ?? NSImage())
        logo.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        logo.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: "Google Drive")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        f.row(nil, logo, title)
        cloudStatus = Form.secondary("")
        cloudButton = NSButton(title: "", target: self, action: #selector(cloudSignInOut))
        cloudButton.bezelColor = .controlAccentColor
        f.row("Account:", cloudStatus)
        f.row(nil, cloudButton)
        f.separator()

        func field(_ key: String, secure: Bool = false, placeholder: String) -> NSTextField {
            let t = secure ? NSSecureTextField() : NSTextField()
            t.placeholderString = placeholder
            t.bind(.value, to: Form.controller, withKeyPath: "values.\(key)", options: [.continuouslyUpdatesValue: true])
            t.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return t
        }
        f.row("Client ID:", field("cloud.clientID", placeholder: "xxxx.apps.googleusercontent.com"))
        f.row("Client secret:", field("cloud.clientSecret", secure: true, placeholder: "GOCSPX-…"))
        let help = NSButton(title: "How to get a Client ID…", target: self, action: #selector(cloudHelp))
        help.bezelStyle = .inline
        f.row(nil, help)
        f.note("Google Cloud Console → enable Google Drive API → Credentials → Create OAuth client ID → type \"Desktop app\". DyskShot only gets access to files it creates.")
        f.separator()
        f.row("Folder:", field("cloud.folderName", placeholder: "DyskShot"))
        f.row("Sharing:", Form.check("Anyone with the link can view", "cloud.public"))
        f.row("After upload:", Form.check("Copy link to clipboard", "cloud.copyLink"))
        f.row(nil, Form.check("Open link in browser", "cloud.openLink"))
        f.note("Upload from Quick Access (cloud button), the editor (⌘U), the \"Capture Area & Upload\" shortcut, or automatically via General → After capture.")
        refreshCloud()
        return f.view()
    }

    private func refreshCloud() {
        let d = GoogleDrive.shared
        if d.isSignedIn {
            cloudStatus.stringValue = d.email.isEmpty ? "Connected" : "Connected as \(d.email)"
            cloudStatus.textColor = .systemGreen
            cloudButton.title = "Sign Out"
        } else {
            cloudStatus.stringValue = "Not connected"
            cloudStatus.textColor = .secondaryLabelColor
            cloudButton.title = "Sign in with Google…"
        }
    }

    @objc private func cloudSignInOut() {
        let d = GoogleDrive.shared
        if d.isSignedIn { d.signOut(); refreshCloud(); return }
        guard !d.clientID.isEmpty else {
            Toast.show("Enter your Google OAuth Client ID first", symbol: "key.fill")
            return
        }
        cloudButton.isEnabled = false
        cloudStatus.stringValue = "Waiting for the browser…"
        Task { @MainActor in
            do {
                try await d.signIn()
                Toast.show("Google Drive connected", symbol: "checkmark.icloud")
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.icloud")
            }
            cloudButton.isEnabled = true
            refreshCloud()
            PreferencesWindow.show()
        }
    }

    @objc private func cloudHelp() {
        if let url = URL(string: "https://console.cloud.google.com/apis/credentials") { NSWorkspace.shared.open(url) }
    }

    // Advanced

    func advanced() -> NSView {
        let f = Form()
        let name = NSTextField(string: Prefs.string("fileNameTemplate"))
        name.bind(.value, to: Form.controller, withKeyPath: "values.fileNameTemplate", options: [.continuouslyUpdatesValue: true])
        name.widthAnchor.constraint(equalToConstant: 280).isActive = true
        f.row("File name:", name)
        f.note("Tokens: %Y year, %m month, %d day, %H hour, %M minute, %S second, %t type.")
        f.row(nil, Form.check("Ask for name after every capture", "askName"))
        f.row(nil, Form.check("Add \"@2x\" suffix to Retina screenshots", "retinaSuffix"))
        f.note("Improves how Retina screenshots display in third-party apps.")
        f.separator()
        f.row("Copy to clipboard:", Form.popup(["File & Image (default)", "Image only", "File only"], "clipboardMode"))
        f.note("Change this if pasting misbehaves in some apps or clipboard managers.")
        f.separator()
        f.row("Pinned screenshots:", Form.check("Rounded corners", "pin.rounded"), Form.check("Shadow", "pin.shadow"), Form.check("Border", "pin.border"))
        f.separator()
        let history = Form.slider("historyIndex", min: 0, max: 4, ticks: 5, width: 260)
        f.row("Keep history:", history)
        f.row(nil, Form.secondary("Never · 1 day · 3 days · 1 week · 1 month"))
        f.note("Restore old screenshots from \"Capture History\" in the menu bar.")
        f.separator()
        f.row("Text recognition:", Form.popup(["Automatically Detect Language"] + OCR.languageNames, "ocr.language"))
        f.row(nil, Form.check("Keep line breaks", "ocr.lineBreaks"))
        f.separator()
        f.row("API:", Form.check("Allow applications to control DyskShot", "api.enabled"))
        f.note("URL scheme: dyskshot://capture-area, capture-window, capture-fullscreen, capture-previous, self-timer, capture-text, record-screen, record-gif, history, settings.")
        return f.view()
    }

    // About

    func about() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 128).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 128).isActive = true
        let name = NSTextField(labelWithString: "DyskShot")
        name.font = .systemFont(ofSize: 30, weight: .regular)
        let info = Bundle.main.infoDictionary
        let version = NSTextField(labelWithString: "Version \(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))")
        version.textColor = .secondaryLabelColor
        version.font = .systemFont(ofSize: 15)
        let folder = NSButton(title: "Open Screenshots Folder", target: self, action: #selector(openExport))
        let history = NSButton(title: "Capture History", target: self, action: #selector(openHistory))
        let buttons = NSStackView(views: [folder, history])
        let copyright = NSTextField(labelWithString: "© 2026 Dysklab. All rights reserved.")
        copyright.textColor = .tertiaryLabelColor
        let text = NSStackView(views: [name, version, buttons, copyright])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 10
        let row = NSStackView(views: [icon, text])
        row.spacing = 32
        row.edgeInsets = NSEdgeInsets(top: 36, left: 40, bottom: 36, right: 40)
        row.widthAnchor.constraint(equalToConstant: 740).isActive = true
        return row
    }

    @objc private func openExport() { NSWorkspace.shared.open(Prefs.exportDirectory) }
    @objc private func openHistory() { HistoryWindow.show() }
}

extension NSTextField {
    func secondaryStyled() -> NSTextField {
        textColor = .secondaryLabelColor
        preferredMaxLayoutWidth = 340
        return self
    }
}
