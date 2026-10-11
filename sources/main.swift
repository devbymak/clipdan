import AppKit
import Combine
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

/// Keys as the current keyboard layout sees them.
enum Keyboard {
    /// What a key types in the layout used for shortcuts. With a layout like Persian, macOS matches shortcuts against
    /// the ASCII-capable layout (such as US or Dvorak) instead, so that's the one asked here.
    static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0, length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            guard UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                 OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count, &length, &characters) == noErr,
                  length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length)
            return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty ? nil : text
        }
    }
    /// The key that types `character`. On Dvorak, for one, V is not where it is on a US keyboard.
    static func keyCode(typing character: String) -> UInt32? {
        (0..<128).map(UInt32.init).first { self.character(for: $0)?.lowercased() == character }
    }
    static func title(_ shortcut: Shortcut) -> String { shortcut.title(character: character(for: shortcut.keyCode)) }
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Shortcut.Modifiers {
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
    static func eventFlags(_ modifiers: Shortcut.Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
    /// Presses ⌘V in the front app. Needs Accessibility permission; without it, macOS drops the keys.
    static func pressPaste() {
        let key = CGKeyCode(keyCode(typing: "v") ?? UInt32(kVK_ANSI_V))
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keys the person is still holding, such as the bezel shortcut's ⇧, must not turn ⌘V into another command.
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                           state: .eventSuppressionStateSuppressionInterval)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = [.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))]
            event?.post(tap: .cgSessionEventTap)
        }
    }
}

/// One global shortcut, through Carbon's hot keys, which need no permission.
final class HotKey {
    var onPress: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().onPress?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    /// False when another app already uses the shortcut.
    func register(_ shortcut: Shortcut?) -> Bool {
        unregister()
        guard let shortcut else { return true }
        let id = EventHotKeyID(signature: OSType(0x436C_7064), id: 1)  // "Clpd"
        return RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr
    }
    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }
}

/// Hands out TIFF only when an app asks for it. PNG goes on the pasteboard at once; TIFF, for older apps, is ten times larger.
final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    let png: Data
    init(png: Data) { self.png = png }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .tiff, let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
    }
}

final class ClipModel: ObservableObject {
    /// Inside the sandbox container: ~/Library/Containers/local.clipdan/Data/Library/Application Support/Clipdan.
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clipdan", isDirectory: true)
    static let menuCountChoices = [5, 10, 15, 20, 30, 40]

    @Published private(set) var history: ClipHistory
    @Published var limit = ClipHistory.limitChoices.first { $0 == UserDefaults.standard.integer(forKey: "limit") } ?? 40 {
        didSet {
            defaults.set(limit, forKey: "limit")
            history.limit = limit
            forget(history.trim())
        }
    }
    @Published var menuCount = ClipModel.menuCountChoices.first { $0 == UserDefaults.standard.integer(forKey: "menuCount") } ?? 10 {
        didSet { defaults.set(menuCount, forKey: "menuCount") }
    }
    @Published var keepsImages = UserDefaults.standard.object(forKey: "keepsImages") as? Bool ?? true {
        didSet {
            defaults.set(keepsImages, forKey: "keepsImages")
            if !keepsImages { for clip in history.clips where clip.kind == .image && !clip.pinned { remove(clip.id) } }
        }
    }
    /// With saving off, nothing is written to disk, and turning it off deletes what was saved.
    @Published var savesHistory = UserDefaults.standard.object(forKey: "savesHistory") as? Bool ?? true {
        didSet {
            defaults.set(savesHistory, forKey: "savesHistory")
            guard savesHistory != oldValue else { return }
            let images = history.clips.filter { $0.kind == .image }.compactMap { clip in store.image(for: clip.id).map { (clip.id, $0) } }
            if !savesHistory { store.erase() }
            store = ClipStore(folder: savesHistory ? Self.folder : nil)
            for (id, png) in images { store.putImage(png, for: id) }
            save()
        }
    }
    @Published var pastesAutomatically = UserDefaults.standard.object(forKey: "pastesAutomatically") as? Bool ?? true {
        didSet {
            defaults.set(pastesAutomatically, forKey: "pastesAutomatically")
            if pastesAutomatically { requestAccessibility() }
        }
    }
    @Published var movesPastedToTop = UserDefaults.standard.object(forKey: "movesPastedToTop") as? Bool ?? true {
        didSet { defaults.set(movesPastedToTop, forKey: "movesPastedToTop") }
    }
    /// Keeps the bezel open after the shortcut's keys are let go, until a clipping is chosen.
    @Published var sticky = UserDefaults.standard.bool(forKey: "sticky") {
        didSet { defaults.set(sticky, forKey: "sticky") }
    }
    /// While paused, copies are not kept.
    @Published var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet { defaults.set(paused, forKey: "paused"); onChange?() }
    }
    /// nil when turned off. Saved as "none" then.
    @Published var shortcut: Shortcut? = {
        guard let stored = UserDefaults.standard.string(forKey: "shortcut") else { return .standard }
        return stored == "none" ? nil : Shortcut(stored: stored) ?? .standard
    }() {
        didSet { defaults.set(shortcut?.stored ?? "none", forKey: "shortcut"); registerShortcut() }
    }
    @Published private(set) var shortcutError: String?
    @Published private(set) var accessibilityAllowed = AXIsProcessTrusted()

    var onChange: (() -> Void)?
    var onShortcut: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var store: ClipStore
    private let hotKey = HotKey()
    private var timer: Timer?
    private var lastChangeCount = -1
    /// The change count of Clipdan's own last write, which is not captured again.
    private var ownChangeCount = -1
    /// Captures go through one queue so they're added in the order they were copied, even when an image takes a moment.
    private let captureQueue = DispatchQueue(label: "local.clipdan.capture", qos: .userInitiated)
    private let thumbnails = NSCache<NSString, NSImage>()
    private var tiffProvider: TIFFProvider?

    init() {
        let saves = UserDefaults.standard.object(forKey: "savesHistory") as? Bool ?? true
        if !saves { ClipStore(folder: Self.folder).erase() }
        store = ClipStore(folder: saves ? Self.folder : nil)
        let saved = store.load()
        history = ClipHistory(limit: ClipHistory.limitChoices.first { $0 == UserDefaults.standard.integer(forKey: "limit") } ?? 40, clips: saved)
        if history.clips.count != saved.count { save() }
        thumbnails.countLimit = 80
        hotKey.onPress = { [weak self] in self?.onShortcut?() }
    }

    func start() {
        registerShortcut()
        // Twice a second, like other clipboard managers: macOS has no notification for pasteboard changes.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkPasteboard() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        checkPasteboard()
    }
    func registerShortcut() {
        shortcutError = hotKey.register(shortcut) ? nil
            : "\(shortcut.map(Keyboard.title) ?? "") is in use by another app. Choose another shortcut."
    }
    @Published private(set) var recordingShortcut = false
    private var recorder: Any?
    /// Takes the next key pressed in Settings as the new shortcut. The current one is off meanwhile, so it can be typed.
    func recordShortcut() {
        guard !recordingShortcut else { return }
        recordingShortcut = true
        hotKey.unregister()
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = Keyboard.modifiers(event.modifierFlags)
            switch Int(event.keyCode) {
            case kVK_Escape where modifiers.isEmpty: self.stopRecordingShortcut()
            case kVK_Delete where modifiers.isEmpty, kVK_ForwardDelete where modifiers.isEmpty:
                self.stopRecordingShortcut(); self.shortcut = nil
            default:
                let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
                guard shortcut.isValid else { NSSound.beep(); break }
                self.stopRecordingShortcut(); self.shortcut = shortcut
            }
            return nil
        }
    }
    func stopRecordingShortcut() {
        guard recordingShortcut else { return }
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recordingShortcut = false
        registerShortcut()
    }

    // MARK: Capturing

    private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        let first = lastChangeCount == -1
        lastChangeCount = count
        guard count != ownChangeCount, !paused else { return }
        // At launch, the app in front didn't necessarily copy what's there. While the screen is locked, the login window is.
        let front = NSWorkspace.shared.frontmostApplication
        capture(pasteboard, source: first || front?.bundleIdentifier == "com.apple.loginwindow" ? nil : front?.localizedName)
    }
    private func capture(_ pasteboard: NSPasteboard, source: String?) {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        // Checked before reading anything, so a password is never even read.
        guard !types.contains(where: Capture.skippedTypes.contains) else { return }
        let date = Date()
        switch Capture.decide(types: types, string: pasteboard.string(forType: .string), keepsImages: keepsImages) {
        case .skip: return
        case .text(let text):
            captureQueue.async { [weak self] in DispatchQueue.main.async { self?.add(.text(text, source: source, date: date), png: nil) } }
        case .image(let type):
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) else { return }
            captureQueue.async { [weak self] in
                guard let image = CapturedImage(data: data, type: type) else { return }
                DispatchQueue.main.async { self?.add(.image(image, source: source, date: date), png: image.png) }
            }
        }
    }
    private func add(_ clip: Clip, png: Data?) {
        if clip.kind == .image, !keepsImages { return }
        if let png, !history.clips.contains(where: { $0.matches(clip) }) { store.putImage(png, for: clip.id) }
        forget(history.add(clip).dropped)
    }
    /// Deletes the stored data of clippings no longer in the history, and saves.
    private func forget(_ dropped: [Clip]) {
        store.removeImages(of: dropped)
        save()
    }
    private func save() { store.save(history.clips) }
    func flush() { store.flush() }

    // MARK: Using clippings

    /// Puts the clipping on the pasteboard and, if turned on and allowed, pastes it into the front app.
    func choose(_ clip: Clip, paste: Bool = true) {
        guard put(clip) else { NSSound.beep(); return }
        if movesPastedToTop { history.moveToTop(clip.id); save() }
        guard paste, pastesAutomatically else { return }
        refreshPermissions()
        guard accessibilityAllowed else { return }
        // Let the bezel or menu close first, so the keys reach the app underneath.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Keyboard.pressPaste() }
    }
    private func put(_ clip: Clip) -> Bool {
        let item = NSPasteboardItem()
        switch clip.kind {
        case .text:
            item.setString(clip.text, forType: .string)
        case .image:
            guard let png = store.image(for: clip.id) else { return false }
            item.setData(png, forType: .png)
            let provider = TIFFProvider(png: png)
            tiffProvider = provider  // The pasteboard doesn't keep it.
            item.setDataProvider(provider, forTypes: [.tiff])
        }
        item.setData(Data(), forType: NSPasteboard.PasteboardType(Capture.ownType))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        ownChangeCount = pasteboard.changeCount
        return true
    }
    func remove(_ id: UUID) {
        guard let clip = history.remove(id) else { return }
        forget([clip])
    }
    func togglePin(_ id: UUID) {
        history.togglePin(id)
        forget(history.trim())
    }
    func clearHistory() { forget(history.clear()) }

    /// A scaled-down image to show, at most `maxPixels` on its longer side, in points for this screen.
    func thumbnail(for clip: Clip, maxPixels: Int) -> NSImage? {
        guard clip.kind == .image else { return nil }
        let key = "\(clip.id.uuidString)-\(maxPixels)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let png = store.image(for: clip.id), let image = CapturedImage.thumbnail(png, maxPixels: maxPixels) else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        thumbnails.setObject(thumbnail, forKey: key)
        return thumbnail
    }
    var imageCount: Int { history.clips.filter { $0.kind == .image }.count }
    var imageBytes: Int { store.imageBytes(of: history.clips) }

    // MARK: Permissions

    /// Asks once, at first launch, so automatic pasting works from the start.
    func requestAccessibilityOnce() {
        guard pastesAutomatically, !AXIsProcessTrusted(), !defaults.bool(forKey: "askedForAccessibility") else { return }
        defaults.set(true, forKey: "askedForAccessibility")
        requestAccessibility()
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityAllowed = AXIsProcessTrustedWithOptions(options)
    }
    /// macOS can ask before an app reads the clipboard. Clipdan needs "Always Allow" to keep clippings.
    @Published private(set) var clipboardAccess = ClipboardAccess.current
    func refreshPermissions() {
        accessibilityAllowed = AXIsProcessTrusted()
        clipboardAccess = .current
    }

    // MARK: Launch at login

    /// Mirrors the login item's registration; System Settings can change it behind our back.
    @Published private(set) var loginItemStatus = SMAppService.mainApp.status
    @Published private(set) var loginItemError: String?
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch { loginItemError = "Cannot change Launch at Login: \(error.localizedDescription)" }
        loginItemStatus = SMAppService.mainApp.status
    }
    func refreshLoginItemStatus() { loginItemStatus = SMAppService.mainApp.status }
}

enum ClipboardAccess {
    case unknown, notAsked, asks, allowed, denied
    static var current: ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .unknown }
        switch NSPasteboard.general.accessBehavior {
        case .default: return .notAsked
        case .ask: return .asks
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        @unknown default: return .unknown
        }
    }
    var title: String {
        switch self {
        case .unknown, .notAsked: return "Allowed"
        case .asks: return "Asks each time"
        case .allowed: return "Always allowed"
        case .denied: return "Denied"
        }
    }
    var isLimited: Bool { self == .asks || self == .denied }
}

enum SystemSettings {
    static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
    static func openAccessibility() { open("Privacy_Accessibility") }
    static func openPrivacy() { open("Privacy") }
}

// MARK: - Bezel

/// What the bezel shows: the clippings matching the search, and which one is selected.
final class BezelModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var selection = 0
    @Published var query = ""
    @Published var sticky = false
    @Published var total = 0
    var current: Clip? { clips.indices.contains(selection) ? clips[selection] : nil }
}

struct BezelView: View {
    static let size = NSSize(width: 600, height: 360)
    @ObservedObject var bezel: BezelModel
    let shortcut: Shortcut?
    let thumbnail: (Clip) -> NSImage?
    let choose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(counter).monospacedDigit().foregroundStyle(.primary)
                if bezel.current?.pinned == true { Image(systemName: "pin.fill").accessibilityLabel("Pinned") }
                Spacer()
                Text(caption).lineLimit(1)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: choose)
            if bezel.sticky || !bezel.query.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text(bezel.query.isEmpty ? "Type to search" : bezel.query)
                        .foregroundStyle(bezel.query.isEmpty ? .tertiary : .primary)
                    Spacer()
                }
                .font(.body)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
            Text(hints).font(.caption).foregroundStyle(.tertiary).lineLimit(1).frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }
    @ViewBuilder private var content: some View {
        if let clip = bezel.current {
            if clip.kind == .image {
                if let image = thumbnail(clip) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .accessibilityLabel(clip.imageTitle)
                } else {
                    placeholder("photo", "Can't show this image")
                }
            } else {
                let rightToLeft = Format.isRightToLeft(clip.text)
                Text(Format.block(clip.text))
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(rightToLeft ? .trailing : .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: rightToLeft ? .topTrailing : .topLeading)
            }
        } else if bezel.total == 0 {
            placeholder("list.clipboard", "No clippings yet. Copy something, and it shows up here.")
        } else {
            placeholder("magnifyingglass", "No clippings match “\(bezel.query)”")
        }
    }
    private func placeholder(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light))
            Text(text).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }
    private var counter: String {
        guard !bezel.clips.isEmpty else { return bezel.query.isEmpty ? "Clipdan" : "0 of \(bezel.total)" }
        return "\(bezel.selection + 1) of \(bezel.clips.count)"
    }
    private var caption: String {
        guard let clip = bezel.current else { return "" }
        var parts: [String] = []
        if clip.kind == .image { parts.append("\(clip.width) × \(clip.height) · \(Format.bytes(clip.bytes))") }
        else if clip.text.count > 1 { parts.append(Format.count(clip.text.count, "character")) }
        if let source = clip.source { parts.append(source) }
        parts.append(Format.age(Date().timeIntervalSince(clip.date)))
        return parts.joined(separator: " · ")
    }
    private var hints: String {
        let key = shortcut.map { Shortcut.ansiKeys[$0.keyCode] ?? Keyboard.title($0) } ?? ""
        let start = bezel.sticky ? "↑↓ Browse   ↩ Paste" : "\(key) or ↑↓ Browse   Let go to paste"
        return "\(start)   ⌘C Copy only   ⌘P Pin   ⌘⌫ Delete   esc Cancel"
    }
}

/// A borderless panel that takes the keyboard without making Clipdan the active app, so the app underneath stays in front
/// and receives the paste.
final class BezelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class BezelController {
    private let model: ClipModel
    private let bezel = BezelModel()
    private lazy var panel = makePanel()
    private var monitor: Any?
    private var releaseTimer: Timer?
    private var resignObserver: NSObjectProtocol?
    private var scrolled: CGFloat = 0
    var isShown: Bool { panel.isVisible }

    init(model: ClipModel) { self.model = model }

    /// The first press shows the newest clipping; each press after that, an older one.
    func shortcutPressed() {
        if isShown { move(1) } else { show(sticky: false) }
    }
    func show(sticky: Bool) {
        if isShown { hide() }
        bezel.query = ""
        bezel.sticky = sticky || model.sticky || (model.shortcut?.modifiers.isEmpty ?? true)
        reload()
        bezel.selection = 0
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - BezelView.size.width / 2, y: frame.midY - BezelView.size.height / 2 + frame.height / 12))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self, self.isShown else { return event }
            event.type == .scrollWheel ? self.scroll(event) : self.key(event)
            return nil
        }
        // Clicking elsewhere closes it without pasting.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
            [weak self] _ in self?.hide()
        }
        if !bezel.sticky, let modifiers = model.shortcut?.modifiers {
            let held = Keyboard.eventFlags(modifiers)
            let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
                if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { self?.finish() }
            }
            RunLoop.main.add(timer, forMode: .common)
            releaseTimer = timer
        }
    }
    func hide() {
        releaseTimer?.invalidate(); releaseTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        scrolled = 0
        panel.orderOut(nil)
    }
    /// Closes the bezel and uses the selected clipping.
    private func finish(paste: Bool = true) {
        let clip = bezel.current
        hide()
        if let clip { model.choose(clip, paste: paste) }
    }
    private func reload() {
        bezel.total = model.history.clips.count
        bezel.clips = model.history.search(bezel.query)
        bezel.selection = step(bezel.selection, by: 0, count: bezel.clips.count)
    }
    private func move(_ offset: Int) { bezel.selection = step(bezel.selection, by: offset, count: bezel.clips.count) }

    private func key(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Holding the shortcut's keys, every key is a command. Once they're let go in a sticky bezel, typing searches.
        let command = flags.contains(.command) || !bezel.sticky
        switch Int(event.keyCode) {
        case kVK_Escape: hide()
        case kVK_Return, kVK_ANSI_KeypadEnter: finish()
        case kVK_UpArrow, kVK_LeftArrow: move(-1)
        case kVK_DownArrow, kVK_RightArrow: move(1)
        case kVK_PageUp: move(-10)
        case kVK_PageDown: move(10)
        case kVK_Home: bezel.selection = 0
        case kVK_End: bezel.selection = max(bezel.clips.count - 1, 0)
        case kVK_Delete, kVK_ForwardDelete:
            if !command, !bezel.query.isEmpty { bezel.query.removeLast(); reload() }
            else if let clip = bezel.current { model.remove(clip.id); reload() }
        default:
            if let digit = Self.digits[Int(event.keyCode)], command {
                bezel.selection = step(digit == 0 ? 9 : digit - 1, by: 0, count: bezel.clips.count)
            } else if command {
                switch Keyboard.character(for: UInt32(event.keyCode))?.lowercased() {
                case "p": if let clip = bezel.current { model.togglePin(clip.id); reload() }
                case "c": finish(paste: false)
                default: if UInt32(event.keyCode) == model.shortcut?.keyCode { move(1) }
                }
            } else if !flags.contains(.control), let typed = event.characters, !typed.isEmpty,
                      typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                bezel.query += typed
                bezel.selection = 0
                reload()
            }
        }
    }
    /// Scrolling browses: one wheel notch, or about two lines on a trackpad, per clipping.
    private func scroll(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else {
            if event.scrollingDeltaY != 0 { move(event.scrollingDeltaY > 0 ? -1 : 1) }
            return
        }
        scrolled += event.scrollingDeltaY
        while abs(scrolled) >= 24 {
            move(scrolled > 0 ? -1 : 1)
            scrolled -= scrolled > 0 ? 24 : -24
        }
    }
    /// Number keys by key code, so they work in any keyboard layout.
    private static let digits = [kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5, kVK_ANSI_6: 6,
                                 kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9, kVK_ANSI_0: 0]

    private func makePanel() -> BezelPanel {
        let panel = BezelPanel(contentRect: NSRect(origin: .zero, size: BezelView.size), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: BezelView.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = .roundedMask(radius: 20)
        let host = NSHostingView(rootView: BezelView(bezel: bezel, shortcut: model.shortcut,
                                                     thumbnail: { [weak model] in model?.thumbnail(for: $0, maxPixels: 1120) },
                                                     choose: { [weak self] in self?.finish() }))
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        panel.contentView = background
        panel.setAccessibilityLabel("Clipdan clippings")
        return panel
    }
    /// The shortcut shown in the hints can change in Settings.
    func shortcutChanged() {
        guard let host = panel.contentView?.subviews.first as? NSHostingView<BezelView> else { return }
        host.rootView = BezelView(bezel: bezel, shortcut: model.shortcut, thumbnail: host.rootView.thumbnail, choose: host.rootView.choose)
    }
}

extension NSImage {
    /// A stretchable rounded rectangle, to round a visual effect view's corners.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Settings

/// A page of the Settings window, shown as a toolbar tab.
enum SettingsPage: String, CaseIterable {
    case general, history
    var title: String { self == .general ? "General" : "History" }
    var symbol: String { self == .general ? "gearshape" : "clock.arrow.circlepath" }
}

/// Click, then type the new shortcut. Esc cancels; ⌫ turns the shortcut off.
struct ShortcutRecorder: View {
    @ObservedObject var model: ClipModel
    var body: some View {
        HStack {
            Button(action: { model.recordingShortcut ? model.stopRecordingShortcut() : model.recordShortcut() }) {
                Text(model.recordingShortcut ? "Type a shortcut…" : model.shortcut.map(Keyboard.title) ?? "None").frame(minWidth: 110)
            }
            if !model.recordingShortcut, model.shortcut != .standard {
                Button("Use \(Keyboard.title(.standard))") { model.shortcut = .standard }
            }
        }
        .onDisappear(perform: model.stopRecordingShortcut)
    }
}

struct SettingsView: View {
    @ObservedObject var model: ClipModel
    let page: SettingsPage
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        Form {
            switch page {
            case .general: general
            case .history: history
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshLoginItemStatus(); model.refreshPermissions() }
        // Permissions change in System Settings, behind Clipdan's back.
        .onReceive(refresh) { _ in model.refreshPermissions() }
    }

    @ViewBuilder private var general: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(
                get: { [.enabled, .requiresApproval].contains(model.loginItemStatus) },
                set: { model.setLaunchAtLogin($0) }))
            if model.loginItemStatus == .requiresApproval {
                HStack {
                    Text("Allow Clipdan in Login Items to finish.").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let error = model.loginItemError { warning(error) }
        }
        Section {
            LabeledContent("Shortcut") { ShortcutRecorder(model: model) }
            if let error = model.shortcutError { warning(error) }
            Toggle(isOn: $model.sticky) {
                Text("Keep open until you choose")
                Text("Then type to search, and press Return to paste. Otherwise, letting go of the keys pastes.")
            }
        } header: {
            Text("Bezel")
        } footer: {
            footer(bezelFooter)
        }
        Section {
            Toggle(isOn: $model.pastesAutomatically) {
                Text("Paste automatically")
                Text("Pastes into the app in front after you choose a clipping. Otherwise it's copied, ready for ⌘V.")
            }
            if model.pastesAutomatically {
                LabeledContent("Accessibility") {
                    HStack {
                        Text(model.accessibilityAllowed ? "Allowed" : "Not allowed")
                            .foregroundStyle(model.accessibilityAllowed ? Color.secondary : .orange)
                        if !model.accessibilityAllowed { Button("Open Settings", action: SystemSettings.openAccessibility) }
                    }
                }
            }
            Toggle("Move a pasted clipping to the top", isOn: $model.movesPastedToTop)
        } header: {
            Text("Pasting")
        } footer: {
            if model.pastesAutomatically, !model.accessibilityAllowed {
                footer("Clipdan needs Accessibility permission to press ⌘V for you. Turn on Clipdan in System Settings → Privacy & Security → Accessibility. After you rebuild Clipdan, remove it from that list and add it again.")
            }
        }
        if model.clipboardAccess != .unknown {
            Section {
                LabeledContent("Reading what you copy") {
                    HStack {
                        Text(model.clipboardAccess.title).foregroundStyle(model.clipboardAccess.isLimited ? Color.orange : .secondary)
                        if model.clipboardAccess.isLimited { Button("Open Settings", action: SystemSettings.openPrivacy) }
                    }
                }
            } header: {
                Text("Clipboard Access")
            } footer: {
                if model.clipboardAccess.isLimited {
                    footer("macOS asks before Clipdan reads the clipboard. Allow Clipdan to paste from other apps in System Settings → Privacy & Security, or it can't keep your clippings.")
                }
            }
        }
    }

    @ViewBuilder private var history: some View {
        Section {
            Picker("Remember", selection: $model.limit) {
                ForEach(ClipHistory.limitChoices, id: \.self) { Text("\($0) clippings").tag($0) }
            }
            Picker("Show in menu", selection: $model.menuCount) {
                ForEach(ClipModel.menuCountChoices, id: \.self) { Text("\($0) clippings").tag($0) }
            }
            Toggle(isOn: $model.keepsImages) {
                Text("Keep images")
                Text("Screenshots and copied pictures, up to 50 MB each. Turning this off removes images you haven't pinned.")
            }
        } footer: {
            footer("Pinned clippings are kept on top of this number. Pin one with ⌘P in the bezel.")
        }
        Section {
            Toggle(isOn: $model.savesHistory) {
                Text("Save history")
                Text("Keep clippings when Clipdan quits or your Mac restarts. Turning this off deletes the saved copy.")
            }
            LabeledContent("Kept") {
                HStack {
                    Text(keptSummary).monospacedDigit()
                    Button("Clear History…", action: confirmClear).disabled(model.history.clips.allSatisfy(\.pinned))
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            footer("Saved only on this Mac, in Clipdan's sandbox container. Passwords and other copies that apps mark as confidential are never kept. Clipdan has no network access and writes no logs.")
        }
    }

    private var bezelFooter: String {
        guard let shortcut = model.shortcut else { return "The bezel is off. Choose clippings from the menu bar." }
        let key = Shortcut.ansiKeys[shortcut.keyCode] ?? Keyboard.title(shortcut)
        guard !model.sticky, !shortcut.modifiers.isEmpty else {
            return "Press \(Keyboard.title(shortcut)) to show your clippings, newest first. Press it again or use the arrow keys for older ones."
        }
        return "Press \(Keyboard.title(shortcut)) to show your clippings, newest first. Keep holding \(shortcut.modifierSymbols) and press \(key) again for older ones, then let go to paste."
    }
    private var keptSummary: String {
        let clips = model.history.clips.count, images = model.imageCount
        return images == 0 ? Format.count(clips, "clipping") : "\(Format.count(clips, "clipping")), \(Format.count(images, "image")) (\(Format.bytes(model.imageBytes)))"
    }
    private func confirmClear() { ClearConfirmation.run(model) }
    private func warning(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
    private func footer(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

enum ClearConfirmation {
    static func run(_ model: ClipModel) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear your clipboard history?"
        let pinned = model.history.clips.filter(\.pinned).count
        alert.informativeText = "This deletes every clipping" + (pinned > 0 ? " except the \(Format.count(pinned, "pinned one"))" : "") + ". It can't be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.clearHistory() }
    }
}

/// Settings as toolbar tabs, like the system's own settings windows. The window fits each page as it is selected.
final class SettingsTabs: NSTabViewController {
    private var sizeWatch: NSKeyValueObservation?
    init(model: ClipModel) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = []
        for page in SettingsPage.allCases {
            let host = NSHostingController(rootView: SettingsView(model: model, page: page))
            host.sizingOptions = .preferredContentSize
            host.title = page.title  // The window takes the selected page's title.
            let item = NSTabViewItem(viewController: host)
            item.identifier = page.rawValue
            item.label = page.title
            item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
            addTabViewItem(item)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        guard let page = item?.viewController else { return }
        // Follow the page as it grows or shrinks, such as when a warning appears.
        sizeWatch = page.observe(\.preferredContentSize, options: [.initial, .new]) { [weak self] page, _ in
            DispatchQueue.main.async { self?.fit(page.preferredContentSize) }
        }
    }
    /// Keeps the title bar in place, the way system settings windows resize.
    private func fit(_ size: NSSize) {
        guard let window = view.window, size.width > 0, size.height > 0 else { return }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard frame.size != window.frame.size else { return }
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height),
                        display: true, animate: window.isVisible)
    }
}

// MARK: - Menu bar

final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let model = ClipModel()
    lazy var bezel = BezelController(model: model)
    /// Clippings shown in the menu are cut to this many characters.
    static let titleLength = 48

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Clipdan")
        item.button?.setAccessibilityLabel("Clipdan clipboard history")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        model.onShortcut = { [weak self] in self?.bezel.shortcutPressed() }
        model.onChange = { [weak self] in self?.refreshStatusItem() }
        model.start()
        model.requestAccessibilityOnce()
        refreshStatusItem()
        shortcutObservation = model.$shortcut.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.bezel.shortcutChanged() } }
    }
    private var shortcutObservation: Any?
    private func refreshStatusItem() {
        item.button?.appearsDisabled = model.paused
        item.button?.toolTip = model.paused ? "Clipdan is paused" : "Clipdan · \(model.shortcut.map(Keyboard.title) ?? "no shortcut")"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshPermissions()
        menu.removeAllItems()
        func note(_ title: String, _ action: Selector? = nil) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.isEnabled = action != nil
            menu.addItem(entry)
        }
        if model.paused { note("Paused: new copies aren't kept") }
        if model.clipboardAccess == .denied { note("Allow Clipdan to read the clipboard…", #selector(openPrivacy)) }
        if let error = model.shortcutError { note(error) }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }

        let clips = model.history.clips.prefix(model.menuCount)
        if clips.isEmpty { note("No clippings yet") }
        for (index, clip) in clips.enumerated() {
            let key = index < 10 ? "\((index + 1) % 10)" : ""
            let entry = NSMenuItem(title: title(clip), action: #selector(choose), keyEquivalent: key)
            entry.keyEquivalentModifierMask = []
            entry.representedObject = clip.id
            entry.target = self
            entry.image = menuImage(clip)
            entry.toolTip = tooltip(clip)
            menu.addItem(entry)
            // Holding ⌥ turns each clipping into a way to delete it.
            let remove = NSMenuItem(title: "Delete “\(Format.line(clip.kind == .image ? clip.imageTitle : clip.text, length: 36))”",
                                    action: #selector(remove), keyEquivalent: key)
            remove.keyEquivalentModifierMask = [.option]
            remove.isAlternate = true
            remove.representedObject = clip.id
            remove.target = self
            menu.addItem(remove)
        }
        if model.history.clips.count > clips.count {
            note("\(model.history.clips.count - clips.count) more in the bezel")
        }
        menu.addItem(.separator())
        let search = NSMenuItem(title: "Search Clippings…", action: #selector(search), keyEquivalent: "f")
        search.target = self
        menu.addItem(search)
        let pause = NSMenuItem(title: "Pause Clipdan", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = model.paused ? .on : .off
        menu.addItem(pause)
        let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !model.history.clips.allSatisfy(\.pinned)
        menu.addItem(clear)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Clipdan", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.autoenablesItems = false
    }
    private func title(_ clip: Clip) -> String {
        let text = clip.kind == .image ? "\(clip.imageTitle)\(clip.source.map { " · \($0)" } ?? "")" : Format.line(clip.text, length: Self.titleLength)
        return clip.pinned ? "📌 \(text)" : text
    }
    private func tooltip(_ clip: Clip) -> String {
        let details = ([clip.source].compactMap { $0 } + [Format.age(Date().timeIntervalSince(clip.date))]).joined(separator: " · ")
        let content = clip.kind == .image ? "\(clip.width) × \(clip.height) · \(Format.bytes(clip.bytes))" : Format.block(clip.text, length: 600)
        return "\(content)\n\(details)"
    }
    /// A thumbnail at most 64 × 32 points.
    private func menuImage(_ clip: Clip) -> NSImage? {
        guard let image = model.thumbnail(for: clip, maxPixels: 128) else { return nil }
        let scale = min(64 / image.size.width, 32 / image.size.height, 1)
        let sized = image.copy() as? NSImage
        sized?.size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return sized
    }
    private func clipID(_ sender: Any) -> UUID? { (sender as? NSMenuItem)?.representedObject as? UUID }
    @objc private func choose(_ sender: Any) {
        guard let id = clipID(sender), let clip = model.history.clip(id) else { return }
        model.choose(clip)
    }
    @objc private func remove(_ sender: Any) { if let id = clipID(sender) { model.remove(id) } }
    @objc private func search() { bezel.show(sticky: true) }
    @objc private func togglePause() { model.paused.toggle() }
    @objc private func clearHistory() { ClearConfirmation.run(model) }
    @objc private func openPrivacy() { SystemSettings.openPrivacy() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    private var settingsWindow: NSWindow?
    @objc func openSettings() {
        bezel.hide()
        if settingsWindow == nil {
            let tabs = SettingsTabs(model: model)
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            // Size to the first page before centering; centering the default-sized window leaves it off-center once it grows.
            if let page = tabs.tabViewItems.first?.viewController { window.setContentSize(page.view.fittingSize) }
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { model.flush() }
}

// MARK: - Start

let arguments = CommandLine.arguments
if arguments.contains("--list") {
    // Prints the saved history to the terminal. Nothing is logged.
    let clips = ClipStore(folder: ClipModel.folder).load()
    if clips.isEmpty { print("No saved clippings in \(ClipModel.folder.path)") }
    for (index, clip) in clips.enumerated() {
        let content = clip.kind == .image ? "\(clip.imageTitle) · \(Format.bytes(clip.bytes))" : Format.line(clip.text, length: 60)
        let details = ([clip.source].compactMap { $0 } + [Format.age(Date().timeIntervalSince(clip.date))]).joined(separator: " · ")
        print("\(String(format: "%3d", index + 1)). \(clip.pinned ? "📌 " : "")\(content)  (\(details))")
    }
} else if arguments.contains("--probe") {
    // Describes what's on the clipboard now, and what Clipdan would keep, without printing the content itself.
    let pasteboard = NSPasteboard.general
    let types = pasteboard.types?.map(\.rawValue) ?? []
    print("Types: \(types.joined(separator: ", "))")
    print("Clipboard access: \(ClipboardAccess.current.title)")
    switch Capture.decide(types: types, string: pasteboard.string(forType: .string), keepsImages: true) {
    case .skip: print("Clipdan would skip this.")
    case .text(let text): print("Clipdan would keep text: \(Format.count(text.count, "character")).")
    case .image(let type):
        let image = pasteboard.data(forType: NSPasteboard.PasteboardType(type)).flatMap { CapturedImage(data: $0, type: type) }
        print(image.map { "Clipdan would keep an image: \($0.width) × \($0.height), \(Format.bytes($0.png.count)) as PNG." }
              ?? "Clipdan can't read this \(type) image.")
    }
} else if NSRunningApplication.runningApplications(withBundleIdentifier: "local.clipdan")
            .contains(where: { $0.processIdentifier != getpid() }) {
    // Two copies would add every copy twice and overwrite each other's history.
    fputs("Clipdan is already running.\n", stderr)
} else {
    let app = NSApplication.shared
    let delegate = MenuApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
