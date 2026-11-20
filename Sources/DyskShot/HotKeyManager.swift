import AppKit
import Carbon
import UniformTypeIdentifiers

enum HotAction: String, CaseIterable {
    // General
    case toggleDesktopIcons, history, restoreLastCapture, openPreferences
    // Screenshots
    case captureArea, capturePrevious, captureFullscreen, captureWindow, selfTimer
    case captureAreaCopy, captureAreaSave, captureAreaUpload, captureAreaAnnotate, captureAreaPin
    // Screen recording
    case recordScreen, recordGIF
    // OCR
    case captureText, captureTextLineBreaks, captureTextNoLineBreaks
    // Quick Access
    case toggleOverlays, saveAllOverlays, closeAllOverlays
    // Pin
    case choosePin, pinClipboard, togglePins, closeAllPins, pinLast
    // Annotate / edit
    case annotateFile, annotateClipboard, annotateLast, openVideoEditor

    struct Section {
        let title: String
        let symbol: String
        let actions: [HotAction]
        /// Fixed in-context shortcuts shown read-only (title, keys).
        var fixed: [(String, String)] = []
    }

    static let sections: [Section] = [
        Section(title: "General", symbol: "gearshape.fill", actions: [.toggleDesktopIcons, .history, .restoreLastCapture, .openPreferences]),
        Section(title: "Screenshots", symbol: "camera.fill", actions: [.captureArea, .capturePrevious, .captureFullscreen, .captureWindow, .selfTimer,
                                                                     .captureAreaCopy, .captureAreaSave, .captureAreaUpload, .captureAreaAnnotate, .captureAreaPin]),
        Section(title: "Screen Recording", symbol: "video.fill", actions: [.recordScreen, .recordGIF],
                fixed: [("Select Window", "Space"), ("Start Video Recording", "↩"), ("Start GIF Recording", "⌥↩"), ("Cancel", "⎋")]),
        Section(title: "OCR", symbol: "text.viewfinder", actions: [.captureText, .captureTextLineBreaks, .captureTextNoLineBreaks]),
        Section(title: "Quick Access Overlay", symbol: "rectangle.stack.fill", actions: [.toggleOverlays, .saveAllOverlays, .closeAllOverlays]),
        Section(title: "Pin", symbol: "pin.fill", actions: [.choosePin, .pinClipboard, .togglePins, .closeAllPins, .pinLast]),
        Section(title: "Annotate", symbol: "pencil.tip.crop.circle.fill", actions: [.annotateFile, .annotateClipboard, .annotateLast, .openVideoEditor],
                fixed: [("Done", "⌘↩"), ("Save", "⌘S"), ("Save as", "⇧⌘S"), ("Copy to Clipboard", "⌘C"), ("Upload to Cloud", "⌘U"),
                        ("Undo", "⌘Z"), ("Redo", "⇧⌘Z"), ("Delete Object", "⌫")]),
        Section(title: "Annotate Tools", symbol: "pencil", actions: [],
                fixed: [("Move Tool", "V"), ("Crop Tool", "C"), ("Rectangle Tool", "R"), ("Filled Rectangle Tool", "F"), ("Ellipse Tool", "O"),
                        ("Line Tool", "L"), ("Arrow Tool", "A"), ("Text Tool", "T"), ("Pixelate Tool", "B"), ("Spotlight Tool", "S"),
                        ("Counter Tool", "N"), ("Draw Tool", "P"), ("Highlighter Tool", "H")]),
    ]

    var title: String {
        switch self {
        case .toggleDesktopIcons: "Toggle Desktop Icons"
        case .history: "Open Capture History"
        case .restoreLastCapture: "Restore Last Capture"
        case .openPreferences: "Open Settings"
        case .captureArea: "Capture Area"
        case .capturePrevious: "Capture Previous Area"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureWindow: "Capture Window"
        case .selfTimer: "Self-Timer"
        case .captureAreaCopy: "Capture Area & Copy to Clipboard"
        case .captureAreaSave: "Capture Area & Save"
        case .captureAreaUpload: "Capture Area & Upload to Cloud"
        case .captureAreaAnnotate: "Capture Area & Annotate"
        case .captureAreaPin: "Capture Area & Pin to the Screen"
        case .recordScreen: "Record Screen / Stop Recording"
        case .recordGIF: "Record GIF / Stop Recording"
        case .captureText: "Capture Text"
        case .captureTextLineBreaks: "Capture Text With Line Breaks"
        case .captureTextNoLineBreaks: "Capture Text Without Line Breaks"
        case .toggleOverlays: "Hide/Show Overlays"
        case .saveAllOverlays: "Save All Overlays"
        case .closeAllOverlays: "Close All Overlays"
        case .choosePin: "Choose and Pin an Image"
        case .pinClipboard: "Pin Image from Clipboard"
        case .togglePins: "Toggle Pins Visibility"
        case .closeAllPins: "Close All Pins"
        case .pinLast: "Pin Last Screenshot"
        case .annotateFile: "Annotate: Open File"
        case .annotateClipboard: "Annotate: Open From Clipboard"
        case .annotateLast: "Annotate Last Screenshot"
        case .openVideoEditor: "Open Video Editor"
        }
    }

    /// Short title for the menu bar.
    var menuTitle: String {
        switch self {
        case .captureText: "Capture Text (OCR)"
        case .recordScreen: "Record Screen"
        case .recordGIF: "Record GIF"
        case .history: "Capture History"
        default: title
        }
    }

    var defaultShortcut: Shortcut? {
        let m = UInt32(controlKey | shiftKey)
        switch self {
        case .captureArea: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: m)
        case .captureWindow: return Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: m)
        case .captureFullscreen: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: m)
        case .captureText: return Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: m)
        case .recordScreen: return Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: m)
        default: return nil
        }
    }

    var shortcut: Shortcut? {
        get { Shortcut(storage: Prefs.string("hotkey.\(rawValue)")) }
        nonmutating set { Prefs.d.set(newValue?.storage ?? "", forKey: "hotkey.\(rawValue)") }
    }

    @MainActor
    func perform() {
        let cc = CaptureController.shared
        switch self {
        case .captureArea: cc.start(.area)
        case .capturePrevious: cc.start(.previousArea)
        case .captureFullscreen: cc.start(.fullscreen)
        case .captureWindow: cc.start(.window)
        case .selfTimer: cc.start(.selfTimer)
        case .captureAreaCopy: cc.start(.area, after: .copy)
        case .captureAreaSave: cc.start(.area, after: .save)
        case .captureAreaUpload: cc.start(.area, after: .upload)
        case .captureAreaAnnotate: cc.start(.area, after: .annotate)
        case .captureAreaPin: cc.start(.area, after: .pin)
        case .captureText: OCR.lineBreakOverride = nil; cc.start(.ocr)
        case .captureTextLineBreaks: OCR.lineBreakOverride = true; cc.start(.ocr)
        case .captureTextNoLineBreaks: OCR.lineBreakOverride = false; cc.start(.ocr)
        case .recordScreen: RecordingController.shared.toggle(.video)
        case .recordGIF: RecordingController.shared.toggle(.gif)
        case .toggleDesktopIcons: DesktopCover.shared.togglePersistent()
        case .history: HistoryWindow.show()
        case .restoreLastCapture:
            guard let c = History.latest() else { Toast.show("No captures yet", symbol: "clock.arrow.circlepath"); return }
            QuickAccessManager.shared.show(.image(c, saved: nil))
        case .openPreferences: PreferencesWindow.show()
        case .toggleOverlays: QuickAccessManager.shared.toggleVisibility()
        case .saveAllOverlays: QuickAccessManager.shared.saveAll()
        case .closeAllOverlays: QuickAccessManager.shared.closeAll()
        case .choosePin:
            if let c = Self.chooseImage() { PinPanel.show(c) }
        case .pinClipboard:
            guard let c = Self.clipboardImage() else { Toast.show("No image on the clipboard", symbol: "exclamationmark.triangle.fill"); return }
            PinPanel.show(c)
        case .togglePins: PinPanel.toggleAll()
        case .closeAllPins: PinPanel.closeAll()
        case .pinLast:
            guard let c = History.latest() else { Toast.show("No captures yet", symbol: "clock.arrow.circlepath"); return }
            PinPanel.show(c)
        case .annotateFile:
            if let c = Self.chooseImage() { EditorWindowController.open(c) }
        case .annotateClipboard:
            guard let c = Self.clipboardImage() else { Toast.show("No image on the clipboard", symbol: "exclamationmark.triangle.fill"); return }
            EditorWindowController.open(c)
        case .annotateLast:
            guard let c = History.latest() else { Toast.show("No captures yet", symbol: "clock.arrow.circlepath"); return }
            EditorWindowController.open(c)
        case .openVideoEditor:
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.movie]
            if panel.runModal() == .OK, let url = panel.url { VideoEditorWindowController.edit(url) }
        }
    }

    @MainActor
    static func chooseImage() -> Capture? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Capture.load(from: url)
    }

    @MainActor
    static func clipboardImage() -> Capture? {
        guard let img = NSImage(pasteboard: .general),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return Capture(image: cg, scale: max(1, CGFloat(cg.width) / max(img.size.width, 1)))
    }
}

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(storage: String) {
        let parts = storage.split(separator: ":").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        self.init(keyCode: parts[0], modifiers: parts[1])
    }

    init(event: NSEvent) {
        var m: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    var storage: String { "\(keyCode):\(modifiers)" }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    private static let special: [UInt32: String] = [
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_Escape): "⎋", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    static func keyName(_ code: UInt32) -> String {
        if let s = special[code] { return s }
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "#\(code)"
    }
}

/// Global hotkeys via Carbon's RegisterEventHotKey (no Accessibility permission needed).
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var actions: [UInt32: HotAction] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func reload() {
        unregisterAll()
        installHandlerIfNeeded()
        var id: UInt32 = 1
        for action in HotAction.allCases {
            guard let sc = action.shortcut else { continue }
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x4459_4B53), id: id)
            if RegisterEventHotKey(sc.keyCode, sc.modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                actions[id] = action
            } else {
                NSLog("DyskShot: shortcut \(sc.display) for \(action.title) is unavailable")
            }
            id += 1
        }
    }

    var registeredActions: [HotAction] { Array(actions.values) }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?.perform() }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyManager.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Click, then press a key combination. Delete clears, Esc cancels.
final class ShortcutField: NSButton {
    let action_: HotAction
    private var recording = false { didSet { refresh() } }

    init(action: HotAction) {
        self.action_ = action
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(clicked)
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    private func refresh() {
        title = recording ? "Type shortcut…" : (action_.shortcut?.display ?? "Record Shortcut")
        contentTintColor = recording ? .controlAccentColor : nil
    }

    @objc private func clicked() {
        recording = true
        window?.makeFirstResponder(self)
        MainActor.assumeIsolated { HotKeyManager.shared.unregisterAll() }
    }

    override func resignFirstResponder() -> Bool {
        if recording { stop() }
        return super.resignFirstResponder()
    }

    private func stop() {
        recording = false
        MainActor.assumeIsolated { HotKeyManager.shared.reload() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let code = Int(event.keyCode)
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if code == kVK_Escape && mods.isEmpty { stop(); return }
        if (code == kVK_Delete || code == kVK_ForwardDelete) && mods.isEmpty {
            action_.shortcut = nil
            stop()
            return
        }
        let isFKey = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                      kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].contains(code)
        guard isFKey || !mods.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return }
        let sc = Shortcut(event: event)
        for other in HotAction.allCases where other != action_ && other.shortcut == sc { other.shortcut = nil }
        action_.shortcut = sc
        stop()
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }
}

extension Notification.Name {
    static let shortcutsChanged = Notification.Name("DyskShotShortcutsChanged")
}
