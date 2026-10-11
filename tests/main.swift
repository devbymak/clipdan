import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ description: String) rethrows {
    guard try condition() else { fatalError("FAILED: \(description)") }
    checks += 1
}
func texts(_ history: ClipHistory) -> [String] { history.clips.map(\.text) }
/// A small solid image encoded as `type`.
func encodedImage(width: Int, height: Int, type: UTType, gray: CGFloat = 0.5) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

// What gets kept
check(Capture.decide(types: ["public.utf8-plain-text"], string: "hello", keepsImages: true) == .text("hello"), "Plain text is kept")
check(Capture.decide(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], string: "hunter2", keepsImages: true) == .skip,
      "Passwords marked confidential are never kept")
check(Capture.decide(types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"], string: "x", keepsImages: true) == .skip,
      "Temporary copies are skipped")
check(Capture.decide(types: ["public.utf8-plain-text", Capture.ownType], string: "x", keepsImages: true) == .skip,
      "Clipdan's own pastes are not added again")
check(Capture.decide(types: ["public.tiff"], string: nil, keepsImages: true) == .image(type: "public.tiff"), "A screenshot is kept as an image")
check(Capture.decide(types: ["public.tiff", "public.png"], string: nil, keepsImages: true) == .image(type: "public.png"), "PNG is preferred")
check(Capture.decide(types: ["public.tiff"], string: nil, keepsImages: false) == .skip, "Images can be turned off")
check(Capture.decide(types: ["public.utf8-plain-text", "public.png"], string: "Q3 revenue\t42", keepsImages: true) == .text("Q3 revenue\t42"),
      "Spreadsheet cells keep their text, not the picture of them")
check(Capture.decide(types: ["public.utf8-plain-text", "public.tiff"], string: "https://example.com/cat.jpg", keepsImages: true)
        == .image(type: "public.tiff"), "Copy Image in a browser keeps the image, not its link")
check(Capture.decide(types: ["public.file-url", "public.utf8-plain-text", "public.tiff"], string: "report.pdf", keepsImages: true)
        == .text("report.pdf"), "Copied files keep their names, not their icons")
check(Capture.decide(types: ["public.file-url", "public.tiff"], string: nil, keepsImages: true) == .skip, "File icons alone are skipped")
check(Capture.decide(types: ["public.utf8-plain-text"], string: "", keepsImages: true) == .skip, "Empty text is skipped")
check(Capture.decide(types: ["public.utf8-plain-text"], string: String(repeating: "a", count: Capture.textLimit + 1), keepsImages: true) == .skip,
      "Huge text is skipped")
check(Capture.decide(types: ["com.apple.something"], string: nil, keepsImages: true) == .skip, "Unknown content is skipped")
check(Capture.isLink(" /Users/me/a.png\n") && Capture.isLink("https://a.b/c") && !Capture.isLink("see https://a.b")
      && !Capture.isLink("hello") && !Capture.isLink("javascript:alert(1)"), "Links and paths are recognized")

// History
var history = ClipHistory(limit: 3)
for word in ["one", "two", "three"] { history.add(.text(word)) }
check(texts(history) == ["three", "two", "one"], "Newest first")
let firstTwo = history.clips[1].id
let (top, dropped) = history.add(.text("two", source: "Notes"))
check(texts(history) == ["two", "three", "one"] && dropped.isEmpty, "Copying the same text again moves it up instead of adding it twice")
check(top.id == firstTwo && top.source == "Notes", "The earlier copy is kept, with the new source")
let overflow = history.add(.text("four")).dropped
check(texts(history) == ["four", "two", "three"] && overflow.map(\.text) == ["one"], "The oldest is dropped beyond the limit")
history.togglePin(history.clips[2].id)
history.add(.text("five")); history.add(.text("six"))
check(texts(history) == ["six", "five", "four", "three"], "A pinned clipping stays and doesn't count toward the limit")
history.togglePin(history.clips[3].id)
check(texts(history) == ["six", "five", "four"], "Unpinning trims back to the limit")
history.moveToTop(history.clips[2].id)
check(texts(history) == ["four", "six", "five"], "Move to top")
history.togglePin(history.clips[1].id)
let cleared = history.clear()
check(texts(history) == ["six"] && cleared.count == 2, "Clear keeps pinned clippings")
check(history.remove(history.clips[0].id)?.text == "six" && history.clips.isEmpty, "Remove")
check(ClipHistory(limit: 2, clips: [.text("a"), .text("b"), .text("c")]).clips.count == 2, "Loaded history is trimmed to the limit")
check(ClipHistory(limit: 0).limit == 1, "The limit is at least one")

var searchable = ClipHistory(limit: 10)
searchable.add(.text("Hello World")); searchable.add(.text("hello there")); searchable.add(.text("سلام دنیا"))
check(searchable.search("HELLO").count == 2 && searchable.search("world hello").count == 1, "Search ignores case and word order")
check(searchable.search("دنیا").count == 1 && searchable.search("  ").count == 3, "Search finds Persian text; blank shows all")

// Images
let tiff = encodedImage(width: 30, height: 20, type: .tiff)
guard let captured = CapturedImage(data: tiff, type: UTType.tiff.identifier) else { fatalError("FAILED: TIFF converts") }
check(captured.width == 30 && captured.height == 20, "Image size is read")
check(captured.png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "TIFF is stored as PNG")
let png = encodedImage(width: 8, height: 8, type: .png)
check(CapturedImage(data: png, type: UTType.png.identifier)?.png == png, "PNG is kept as it is")
check(CapturedImage(data: Data("not an image".utf8), type: UTType.png.identifier) == nil, "Junk is rejected")
check(CapturedImage(data: tiff, type: UTType.tiff.identifier)?.digest == captured.digest, "The same image has the same digest")
let other = CapturedImage(data: encodedImage(width: 30, height: 20, type: .tiff, gray: 0.9), type: UTType.tiff.identifier)!
check(other.digest != captured.digest, "Different images differ")
check(CapturedImage.thumbnail(captured.png, maxPixels: 10).map { $0.width == 10 && $0.height == 7 } == true, "Thumbnails keep the shape")
var mixed = ClipHistory(limit: 5)
mixed.add(.image(captured)); mixed.add(.text("between")); mixed.add(.image(other))
let again = mixed.add(.image(captured))
check(mixed.clips.count == 3 && again.top.kind == .image && mixed.clips[0].digest == captured.digest, "The same image copied again moves up")
check(mixed.search("image 30").count == 2, "Images are found by their title")
check(Clip.image(captured).imageTitle == "Image · 30 × 20", "Image title")

// Saving
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clipdan-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: folder) }
let store = ClipStore(folder: folder)
var saved = ClipHistory(limit: 10)
let imageClip = saved.add(.image(captured, source: "Preview")).top
store.putImage(captured.png, for: imageClip.id)
saved.add(.text("line one\nline two", source: "Terminal"))
saved.togglePin(saved.clips[0].id)
store.save(saved.clips); store.flush()
let stray = folder.appendingPathComponent("images/\(UUID().uuidString).png")
try captured.png.write(to: stray)
let reloaded = ClipStore(folder: folder).load()
check(reloaded == saved.clips, "Saved clippings round-trip, with pins and sources")
check(store.image(for: imageClip.id) == captured.png, "Image data round-trips")
check(!FileManager.default.fileExists(atPath: stray.path), "Image files no clipping uses are deleted")
store.removeImages(of: [imageClip]); store.flush()
check(ClipStore(folder: folder).load().map(\.kind) == [.text], "A clipping whose image is gone is dropped")
store.erase()
check(!FileManager.default.fileExists(atPath: folder.path) && ClipStore(folder: folder).load().isEmpty, "Erase removes everything")
let memoryStore = ClipStore(folder: nil)
memoryStore.putImage(png, for: imageClip.id); memoryStore.save(saved.clips)
check(memoryStore.image(for: imageClip.id) == png && memoryStore.load().isEmpty, "Without saving, images stay in memory only")
memoryStore.removeImages(of: [imageClip])
check(memoryStore.image(for: imageClip.id) == nil, "Removed images are released")
try Data("{broken".utf8).write(to: { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder.appendingPathComponent("history.json") }())
check(ClipStore(folder: folder).load().isEmpty, "A corrupt history loads as empty instead of crashing")

// Shortcuts
check(Shortcut.standard.title() == "⇧⌘V" && Shortcut.standard.carbonModifiers == 768, "⌘⇧V, as macOS writes it")
check(Shortcut(keyCode: 9, modifiers: [.control, .option, .shift, .command]).modifierSymbols == "⌃⌥⇧⌘", "Modifier order")
check(Shortcut(keyCode: 9, modifiers: [.command]).title(character: "k") == "⌘K", "The current layout names the key")
check(Shortcut(keyCode: 49, modifiers: [.option]).title(character: " ") == "⌥Space", "Special keys have names")
check(!Shortcut(keyCode: 9, modifiers: [.shift]).isValid && !Shortcut(keyCode: 9, modifiers: []).isValid, "Plain typing can't be a shortcut")
check(Shortcut(keyCode: 105, modifiers: []).isValid, "A function key works alone")
check(Shortcut(stored: Shortcut.standard.stored) == .standard, "Shortcuts round-trip")
check(Shortcut(stored: "9:4") == nil && Shortcut(stored: "junk") == nil && Shortcut(stored: "999:8") == nil, "Bad saved shortcuts are rejected")

// Formatting
check(Format.line("  hello\n\n  world  ", length: 40) == "hello world", "Line breaks and runs of spaces collapse")
check(Format.line("abcdefghij", length: 5) == "abcd…", "Long lines are cut")
check(Format.line("", length: 5) == "(empty)" && Format.line(" \n", length: 5) == "(spaces only)", "Blank clippings are named")
check(Format.line(String(repeating: " ", count: 5000) + "tail", length: 10) == "…", "Huge clippings aren't scanned whole")
check(Format.block("\n\n\tcode\n\n") == "    code", "Bezel text trims blank lines and expands tabs")
check(Format.block(String(repeating: "a", count: 10), length: 4) == "aaaa…", "Bezel text is cut")
check(Format.isRightToLeft("  «سلام» hello") && Format.isRightToLeft("שלום") && !Format.isRightToLeft("hello سلام")
      && !Format.isRightToLeft("123"), "Right-to-left text is spotted by its first letter")
check(Format.age(5) == "just now" && Format.age(125) == "2 min ago" && Format.age(7200) == "2 h ago"
      && Format.age(90_000) == "yesterday" && Format.age(3 * 86_400) == "3 days ago", "Ages")
check(Format.count(1, "clipping") == "1 clipping" && Format.count(2, "image") == "2 images", "Counts")
check(step(0, by: -1, count: 3) == 0 && step(2, by: 1, count: 3) == 2 && step(1, by: 1, count: 3) == 2 && step(0, by: 1, count: 0) == 0,
      "Selection stops at the ends")

print("All \(checks) checks passed")
