import AppKit
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var lastShowIcon: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        MainMenu.install()
        HotKeyManager.shared.reload()
        History.prune()
        refreshStatusItem()
        RecordingController.shared.onStateChange = { [weak self] in self?.updateRecordingState() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatusItem() }
        }
        NotificationCenter.default.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildMenu() }
        }
        if let path = ProcessInfo.processInfo.environment["DYSKSHOT_PERMCHECK"] {
            Task { @MainActor in
                var line = "preflight=\(CGPreflightScreenCaptureAccess())"
                do {
                    let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    line += " sck=ok displays=\(c.displays.count)"
                } catch { line += " sck=error \(error.localizedDescription)" }
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        if let src = ProcessInfo.processInfo.environment["DYSKSHOT_CQ_SWEEP"] {
            DispatchQueue.main.async { MainActor.assumeIsolated { SelfTest.sweep(src) } }
        }
        if let report = ProcessInfo.processInfo.environment["DYSKSHOT_SELFTEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { SelfTest.run(report: report) } }
        }
        if let dir = ProcessInfo.processInfo.environment["DYSKSHOT_RENDER_PREFS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { DebugRender.run(to: dir) } }
        }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    /// Opening the app again (e.g. with the menu bar icon hidden) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PreferencesWindow.show()
        return true
    }

    // MARK: Status item

    private func refreshStatusItem() {
        let show = Prefs.bool("showMenuBarIcon")
        guard show != lastShowIcon else { return }
        lastShowIcon = show
        if show {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
            rebuildMenu()
            updateRecordingState()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func updateRecordingState() {
        guard let button = statusItem?.button else { return }
        let rc = RecordingController.shared
        if rc.isRecording {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
            button.contentTintColor = .systemRed
            if Prefs.bool("rec.menuBarTime") {
                let s = Int(rc.elapsed)
                button.attributedTitle = NSAttributedString(string: String(format: " %d:%02d", s / 60, s % 60), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                    .baselineOffset: 0.5,
                ])
                button.imagePosition = .imageLeading
            } else {
                button.title = ""
            }
            statusItem?.menu = nil
            button.target = self
            button.action = #selector(stopRecording)
        } else {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "DyskShot")
            button.contentTintColor = nil
            button.title = ""
            button.action = nil
            rebuildMenu()
        }
    }

    @objc private func stopRecording() { RecordingController.shared.stop() }

    private func rebuildMenu() {
        guard let statusItem, !RecordingController.shared.isRecording else { return }
        let menu = NSMenu()
        func add(_ action: HotAction, _ title: String? = nil) {
            let item = NSMenuItem(title: title ?? action.menuTitle, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            if let sc = action.shortcut, let key = Self.menuKey(sc) {
                item.keyEquivalent = key.0
                item.keyEquivalentModifierMask = key.1
            }
            menu.addItem(item)
        }
        add(.captureArea)
        add(.capturePrevious)
        add(.captureFullscreen)
        add(.captureWindow)
        add(.selfTimer)
        add(.captureText)
        menu.addItem(.separator())
        add(.recordScreen)
        add(.recordGIF)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Image to Annotate…", action: #selector(openImage), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let openVid = NSMenuItem(title: "Open Video to Edit…", action: #selector(openVideo), keyEquivalent: "")
        openVid.target = self
        menu.addItem(openVid)
        let compress = NSMenuItem(title: "Compress Video…", action: #selector(compressVideo), keyEquivalent: "")
        compress.target = self
        menu.addItem(compress)
        let pinClip = NSMenuItem(title: "Pin Image from Clipboard", action: #selector(pinClipboard), keyEquivalent: "")
        pinClip.target = self
        menu.addItem(pinClip)
        add(.history)
        add(.toggleDesktopIcons, DesktopCover.shared.isShown ? "Show Desktop Icons" : "Hide Desktop Icons")
        let folder = NSMenuItem(title: "Open Screenshots Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        let videoFolder = NSMenuItem(title: "Open Recordings Folder", action: #selector(openVideoFolder), keyEquivalent: "")
        videoFolder.target = self
        menu.addItem(videoFolder)
        menu.addItem(.separator())
        add(.openPreferences, "Settings…")
        menu.addItem(NSMenuItem(title: "Quit DyskShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Display-only key equivalent for menu items.
    private static func menuKey(_ sc: Shortcut) -> (String, NSEvent.ModifierFlags)? {
        let name = Shortcut.keyName(sc.keyCode)
        guard name.count == 1 else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if sc.modifiers & 0x100 != 0 { flags.insert(.command) }
        if sc.modifiers & 0x200 != 0 { flags.insert(.shift) }
        if sc.modifiers & 0x800 != 0 { flags.insert(.option) }
        if sc.modifiers & 0x1000 != 0 { flags.insert(.control) }
        return (name.lowercased(), flags)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotAction(rawValue: raw) else { return }
        if action == .openPreferences { PreferencesWindow.show(); return }
        // Let the menu disappear before freezing the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { action.perform() } }
    }

    @objc func openSettings(_ sender: Any? = nil) { PreferencesWindow.show() }

    @objc private func openFolder() { Self.open(Prefs.exportDirectory) }
    @objc private func openVideoFolder() { Self.open(Prefs.videoDirectory) }

    private static func open(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func openImage() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let capture = Capture.load(from: url) else { return }
        EditorWindowController.open(capture)
    }

    @objc private func compressVideo() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { VideoCompressor.run($0) }
    }

    @objc private func openVideo() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        VideoEditorWindowController.edit(url)
    }

    @objc private func pinClipboard() {
        guard let img = NSImage(pasteboard: .general),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Toast.show("No image on the clipboard", symbol: "exclamationmark.triangle.fill")
            return
        }
        PinPanel.show(Capture(image: cg, scale: max(1, CGFloat(cg.width) / max(img.size.width, 1))))
    }

    // MARK: URL scheme API  (dyskshot://capture-area …)

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s), let host = url.host else { return }
        if host == "settings" { PreferencesWindow.show(); return }
        guard Prefs.bool("api.enabled") else {
            Toast.show("URL API is disabled in Settings → Advanced", symbol: "lock.fill")
            return
        }
        let map: [String: HotAction] = [
            "capture-area": .captureArea, "capture-previous": .capturePrevious, "capture-fullscreen": .captureFullscreen,
            "capture-window": .captureWindow, "self-timer": .selfTimer, "capture-text": .captureText,
            "record-screen": .recordScreen, "record-gif": .recordGIF, "history": .history,
            "toggle-desktop-icons": .toggleDesktopIcons,
        ]
        map[host]?.perform()
    }
}

// MARK: - Main menu (enables ⌘C / ⌘Z / ⌘S key equivalents in windows)

@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DyskShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenuItem(appMenu))

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Save", action: #selector(CanvasView.saveDocument(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenuItem(file))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenuItem(edit))

        NSApp.mainMenu = main
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
