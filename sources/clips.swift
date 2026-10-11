import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

enum ClipKind: String, Codable { case text, image }

/// One copied item. Text is kept here; an image's PNG data lives in the store, under the clipping's ID.
struct Clip: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: ClipKind
    /// The text, for a text clipping. Empty for an image.
    var text = ""
    /// Size in pixels and PNG size in bytes, for an image clipping.
    var width = 0, height = 0, bytes = 0
    /// SHA-256 of the PNG data, so the same image copied twice is kept once.
    var digest = ""
    /// The app that was in front when it was copied, if known.
    var source: String?
    var date: Date
    /// Pinned clippings are never dropped to make room, and survive Clear History.
    var pinned = false

    static func text(_ text: String, source: String? = nil, date: Date = Date()) -> Clip {
        Clip(id: UUID(), kind: .text, text: text, source: source, date: date)
    }
    static func image(_ image: CapturedImage, source: String? = nil, date: Date = Date()) -> Clip {
        Clip(id: UUID(), kind: .image, width: image.width, height: image.height, bytes: image.png.count, digest: image.digest,
             source: source, date: date)
    }
    /// The same content, whatever its ID, date, or source.
    func matches(_ other: Clip) -> Bool {
        kind == other.kind && (kind == .text ? text == other.text : digest == other.digest)
    }
    /// "Image · 1920 × 1080"
    var imageTitle: String { "Image · \(width) × \(height)" }
    /// Bytes it takes to keep: the PNG for an image, the UTF-8 text otherwise.
    var size: Int { kind == .image ? bytes : text.utf8.count }
}

/// Clippings, newest first.
struct ClipHistory: Equatable {
    static let limitChoices = [10, 20, 40, 80, 100, 200]
    static let sizeLimitChoices = [100, 250, 500, 1000, 2000, 5000].map { $0 * 1_000_000 }
    static let standardSizeLimit = 500_000_000
    private(set) var clips: [Clip] = []
    /// How many unpinned clippings to keep. Pinned ones don't count.
    var limit: Int
    /// How many bytes all clippings may take together. Pinned ones count, but only unpinned ones are dropped to make room.
    var sizeLimit: Int
    /// Bytes all clippings take together.
    var size: Int { clips.reduce(0) { $0 + $1.size } }

    init(limit: Int = 40, sizeLimit: Int = standardSizeLimit, clips: [Clip] = []) {
        self.limit = max(limit, 1)
        self.sizeLimit = max(sizeLimit, 0)
        self.clips = clips
        _ = trim()
    }
    /// Puts a clipping on top. The same text or image copied again moves its earlier copy up instead of adding a second
    /// one, so the earlier copy's pin and stored data are kept. Returns the clipping now on top, and those dropped to stay
    /// within the limit, whose stored data can be deleted.
    @discardableResult mutating func add(_ clip: Clip) -> (top: Clip, dropped: [Clip]) {
        var top = clip
        if let index = clips.firstIndex(where: { $0.matches(clip) }) {
            top = clips.remove(at: index)
            top.date = clip.date
            top.source = clip.source ?? top.source
        }
        clips.insert(top, at: 0)
        return (top, trim())
    }
    func contains(_ id: UUID) -> Bool { clips.contains { $0.id == id } }
    func clip(_ id: UUID) -> Clip? { clips.first { $0.id == id } }
    mutating func moveToTop(_ id: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == id }), index > 0 else { return }
        clips.insert(clips.remove(at: index), at: 0)
    }
    @discardableResult mutating func remove(_ id: UUID) -> Clip? {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
        return clips.remove(at: index)
    }
    mutating func togglePin(_ id: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].pinned.toggle()
        // Unpinning can put one more clipping over the limit than there is room for.
        if !clips[index].pinned { _ = trim() }
    }
    /// Removes every unpinned clipping and returns them.
    mutating func clear() -> [Clip] {
        let removed = clips.filter { !$0.pinned }
        clips.removeAll { !$0.pinned }
        return removed
    }
    /// Drops the oldest unpinned clippings beyond the limit, then more until all fit in the size limit, and returns them.
    /// The newest is always kept, so what was just copied is never lost.
    mutating func trim() -> [Clip] {
        var unpinned = 0
        var dropped: [Clip] = []
        clips.removeAll { clip in
            guard !clip.pinned else { return false }
            unpinned += 1
            if unpinned > limit { dropped.append(clip); return true }
            return false
        }
        var total = size
        while total > sizeLimit, let index = clips.indices.dropFirst().last(where: { !clips[$0].pinned }) {
            total -= clips[index].size
            dropped.append(clips.remove(at: index))
        }
        return dropped
    }
    /// Clippings whose text, or for an image its title or source app, contains every word of the query, in any case.
    func search(_ query: String) -> [Clip] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return clips }
        return clips.filter { clip in
            let haystack = clip.kind == .text ? clip.text : "\(clip.imageTitle) \(clip.source ?? "")"
            return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
        }
    }
}

/// Decides what, if anything, to keep from the pasteboard.
enum Capture {
    /// Markers that password managers and other apps add to say a copy is confidential or temporary
    /// (see nspasteboard.org). Such copies are never kept.
    static let skippedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
        "Pasteboard generator type", ownType
    ]
    /// Clipdan marks what it puts on the pasteboard, so pasting a clipping doesn't add it again.
    static let ownType = "local.clipdan.clipping"
    /// Image types Clipdan can keep, best first.
    static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif", "com.microsoft.bmp"]
    static let fileURLType = "public.file-url"
    /// Longer text is not kept, so the saved history stays small enough to load at once.
    static let textLimit = 2_000_000
    /// Larger images are not kept.
    static let imageLimit = 50_000_000
    /// Nor are images with more pixels: a small compressed file can hold a huge picture, and converting it decodes every
    /// pixel at once, at 4 bytes each.
    static let pixelLimit = 100_000_000

    enum Decision: Equatable {
        case text(String)
        /// Read the first type in `imageTypes` that's on the pasteboard.
        case image(type: String)
        case skip
    }
    /// Copying from a spreadsheet or a web page can add a picture of the selection beside its text; the text is what's
    /// wanted then. An image wins only when the text is nothing but a link or path to it, as with Copy Image in a browser.
    /// Copied files are kept as their names, never as their icons.
    static func decide(types: [String], string: String?, keepsImages: Bool) -> Decision {
        if types.contains(where: skippedTypes.contains) { return .skip }
        let text = string.flatMap { $0.isEmpty || $0.utf16.count > textLimit ? nil : $0 }
        if keepsImages, !types.contains(fileURLType), let image = imageTypes.first(where: types.contains) {
            if text == nil || isLink(text!) { return .image(type: image) }
        }
        return text.map(Decision.text) ?? .skip
    }
    /// A single URL or file path, with no other words.
    static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") { return true }
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "data", "blob"].contains(scheme)
    }
}

/// An image ready to keep: PNG data, its size, and its digest.
struct CapturedImage: Equatable {
    let png: Data
    let width: Int
    let height: Int
    let digest: String

    /// Converts any image ImageIO reads, such as TIFF from a screenshot, to PNG, which is several times smaller.
    /// PNG data is kept as it is. Returns nil for data that isn't an image or is too large.
    init?(data: Data, type: String) {
        guard data.count <= Capture.imageLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= Capture.pixelLimit / height else { return nil }
        var png = data
        if type != UTType.png.identifier {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), output.length <= Capture.imageLimit else { return nil }
            png = output as Data
        }
        self.png = png
        self.width = width
        self.height = height
        digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    }

    /// A scaled-down copy for display, at most `maxPixels` on its longer side.
    static func thumbnail(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Saves clippings in one folder: the list in `history.json`, and each image as a PNG beside it.
/// With saving off, image data stays in memory and nothing is written.
final class ClipStore {
    private let folder: URL?
    private var memory: [UUID: Data] = [:]
    private let queue = DispatchQueue(label: "local.clipdan.store")
    var saves: Bool { folder != nil }
    private var index: URL? { folder?.appendingPathComponent("history.json") }
    private var images: URL? { folder?.appendingPathComponent("images", isDirectory: true) }

    init(folder: URL?) { self.folder = folder }

    private struct Saved: Codable {
        var version = 1
        var clips: [Clip]
    }
    /// The saved clippings, without any image whose file is gone. Image files no clipping uses are deleted.
    func load() -> [Clip] {
        guard let index, let images, let data = try? Data(contentsOf: index),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return [] }
        let clips = saved.clips.filter { $0.kind == .text || FileManager.default.fileExists(atPath: imageURL($0.id, in: images).path) }
        let used = Set(clips.filter { $0.kind == .image }.map { "\($0.id.uuidString).png" })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? [] where !used.contains(name) {
            try? FileManager.default.removeItem(at: images.appendingPathComponent(name))
        }
        return clips
    }
    /// Writes the list in the background. Calls are written in order, so the last one wins.
    func save(_ clips: [Clip]) {
        guard let folder, let index else { return }
        guard let data = try? JSONEncoder().encode(Saved(clips: clips)) else { return }
        queue.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? data.write(to: index, options: [.atomic])
        }
    }
    /// Waits for writes still in progress, as at quit.
    func flush() { queue.sync {} }

    func putImage(_ png: Data, for id: UUID) {
        guard let images else { memory[id] = png; return }
        queue.sync {
            try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? png.write(to: imageURL(id, in: images), options: [.atomic])
        }
    }
    func image(for id: UUID) -> Data? {
        guard let images else { return memory[id] }
        return queue.sync { try? Data(contentsOf: imageURL(id, in: images)) }
    }
    func removeImages(of clips: [Clip]) {
        for clip in clips where clip.kind == .image {
            if let images { queue.async { try? FileManager.default.removeItem(at: self.imageURL(clip.id, in: images)) } }
            else { memory[clip.id] = nil }
        }
    }
    /// Deletes everything saved on disk.
    func erase() {
        guard let folder else { memory.removeAll(); return }
        queue.sync { try? FileManager.default.removeItem(at: folder) }
    }
    private func imageURL(_ id: UUID, in images: URL) -> URL { images.appendingPathComponent("\(id.uuidString).png") }
}

/// A global keyboard shortcut: a key and its modifiers.
struct Shortcut: Equatable {
    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let shift = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }
    var keyCode: UInt32
    var modifiers: Modifiers
    /// ⌘⇧V, as in Flycut.
    static let standard = Shortcut(keyCode: 9, modifiers: [.command, .shift])

    /// Carbon's modifier bits, for RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= 1 << 8 }
        if modifiers.contains(.shift) { flags |= 1 << 9 }
        if modifiers.contains(.option) { flags |= 1 << 11 }
        if modifiers.contains(.control) { flags |= 1 << 12 }
        return flags
    }
    /// A function key works alone. Anything else needs ⌘, ⌃, or ⌥, so typing never triggers it.
    var isValid: Bool {
        Self.functionKeys.contains(keyCode) || !modifiers.intersection([.command, .control, .option]).isEmpty
    }
    /// "⌃⌥⇧⌘", in the order macOS menus use.
    var modifierSymbols: String {
        [(Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined()
    }
    /// "⌘⇧V". `character` names the key in the current keyboard layout; without it, the US layout is assumed.
    func title(character: String? = nil) -> String {
        modifierSymbols + (Self.specialKeys[keyCode] ?? character?.uppercased() ?? Self.ansiKeys[keyCode] ?? "Key \(keyCode)")
    }
    /// Saved as "keyCode:modifiers".
    var stored: String { "\(keyCode):\(modifiers.rawValue)" }
    init(keyCode: UInt32, modifiers: Modifiers) { self.keyCode = keyCode; self.modifiers = modifiers }
    init?(stored: String) {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let key = UInt32(parts[0]), key < 128, let flags = Int(parts[1]), (0..<16).contains(flags) else { return nil }
        self.init(keyCode: key, modifiers: Modifiers(rawValue: flags))
        guard isValid else { return nil }
    }

    static let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    static let specialKeys: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑", 76: "⌤", 114: "Help",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
    /// Key names on a US keyboard, by key code.
    static let ansiKeys: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-",
        28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`"
    ]
}

enum Format {
    /// One line for a menu: runs of spaces and line breaks become one space, cut to `length` characters.
    static func line(_ text: String, length: Int) -> String {
        // Only the start is shown, so a huge clipping is never scanned whole.
        let start = text.prefix(length * 4 + 256)
        let collapsed = start.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let more = start.endIndex < text.endIndex
        if collapsed.isEmpty { return more ? "…" : text.isEmpty ? "(empty)" : "(spaces only)" }
        if collapsed.count > length { return String(collapsed.prefix(max(length - 1, 1))) + "…" }
        return more ? collapsed + "…" : collapsed
    }
    /// The start of the text for the bezel, with tabs as spaces and no blank lines at either end.
    static func block(_ text: String, length: Int = 3000) -> String {
        var shown = String(text.prefix(length)).replacingOccurrences(of: "\t", with: "    ")
        while shown.hasSuffix("\n") || shown.hasSuffix("\r") { shown.removeLast() }
        while shown.hasPrefix("\n") || shown.hasPrefix("\r") { shown.removeFirst() }
        if text.count > length { shown += "…" }
        return shown
    }
    /// Whether the text starts in a right-to-left script, such as Persian, Arabic, or Hebrew, and so reads from the right.
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars.prefix(1000) {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
            default: if CharacterSet.letters.contains(scalar) { return false }
            }
        }
        return false
    }
    static func age(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        case ..<172_800: return "yesterday"
        default: return "\(Int(seconds / 86_400)) days ago"
        }
    }
    static func bytes(_ count: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) }
    static func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }
}

/// Moves a selection through `count` items without wrapping around.
func step(_ index: Int, by offset: Int, count: Int) -> Int {
    count == 0 ? 0 : min(max(index + offset, 0), count - 1)
}
