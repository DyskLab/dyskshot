import AppKit

/// Keeps a copy of every screenshot for "Keep history" days.
@MainActor
enum History {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DyskShot/History", isDirectory: true)
    }

    private static var last: Capture?

    /// Most recent screenshot (memory first, then the history folder).
    static func latest() -> Capture? {
        last ?? items().first.flatMap(capture(at:))
    }

    static func add(_ c: Capture) {
        last = c
        guard Prefs.historyKeepDays > 0, let data = Output.encode(c, format: .png) else { return }
        let dir = directory
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))@\(Int(c.scale))x.png"
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent(name))
        }
        prune()
    }

    static func prune() {
        let days = Prefs.historyKeepDays
        let dir = directory
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            for f in files {
                let created = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if days == 0 || created < cutoff { try? fm.removeItem(at: f) }
            }
        }
    }

    static func items() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return files.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func capture(at url: URL) -> Capture? {
        guard let c = Capture.load(from: url) else { return nil }
        let scale = url.deletingPathExtension().lastPathComponent.hasSuffix("@2x") ? 2.0 : (url.lastPathComponent.contains("@3x") ? 3 : 1)
        return Capture(image: c.image, scale: CGFloat(scale))
    }
}

@MainActor
final class HistoryWindow: NSObject {
    private static var shared: HistoryWindow?
    private let window: NSWindow
    private let grid = NSStackView()

    static func show() {
        if shared == nil { shared = HistoryWindow() }
        shared?.reload()
        NSApp.activate()
        shared?.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Capture History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        window.center()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let flipped = FlippedView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 12
        grid.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        grid.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(grid)
        flipped.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = flipped
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: flipped.topAnchor),
            grid.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        window.contentView = scroll
    }

    func reload() {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = Array(History.items().prefix(300))
        if urls.isEmpty {
            let l = NSTextField(labelWithString: Prefs.historyKeepDays == 0
                                ? "History is off. Enable it in Settings → Advanced → Keep history."
                                : "No captures yet.")
            l.textColor = .secondaryLabelColor
            grid.addArrangedSubview(l)
            return
        }
        let perRow = 4
        var row: NSStackView?
        for (i, url) in urls.enumerated() {
            if i % perRow == 0 {
                row = NSStackView()
                row?.spacing = 12
                grid.addArrangedSubview(row!)
            }
            row?.addArrangedSubview(HistoryTile(url: url) { [weak self] in self?.reload() })
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class HistoryTile: NSView {
    let url: URL
    let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 170, height: 120))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 170).isActive = true
        heightAnchor.constraint(equalToConstant: 120).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.15).cgColor
        let imgLayer = CALayer()
        imgLayer.frame = bounds.insetBy(dx: 4, dy: 4)
        imgLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(imgLayer)
        DispatchQueue.global(qos: .userInitiated).async {
            let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return }
            DispatchQueue.main.async { imgLayer.contents = thumb }
        }
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        toolTip = DateFormatter.localizedString(from: created, dateStyle: .medium, timeStyle: .short)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        MainActor.assumeIsolated { if let c = History.capture(at: url) { QuickAccessManager.shared.show(.image(c, saved: nil)) } }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        for (title, sel) in [("Show in Quick Access", #selector(restore)), ("Annotate", #selector(annotate)),
                             ("Copy", #selector(copyImage)), ("Save to Export Location", #selector(save)),
                             ("Show in Finder", #selector(reveal)), ("Delete", #selector(delete))] {
            m.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self
        }
        return m
    }

    private func capture() -> Capture? { MainActor.assumeIsolated { History.capture(at: url) } }

    @objc private func restore() { MainActor.assumeIsolated { if let c = capture() { QuickAccessManager.shared.show(.image(c, saved: nil)) } } }
    @objc private func annotate() { MainActor.assumeIsolated { if let c = capture() { EditorWindowController.open(c) } } }
    @objc private func copyImage() { MainActor.assumeIsolated { if let c = capture() { Output.copy(c); Toast.show("Copied to clipboard") } } }
    @objc private func save() { MainActor.assumeIsolated { if let c = capture(), let u = Output.save(c) { Toast.show("Saved \(u.lastPathComponent)") } } }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @objc private func delete() { try? FileManager.default.removeItem(at: url); onChange() }
}
