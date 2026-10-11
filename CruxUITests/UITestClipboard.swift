import AppKit
import XCTest

/// Normal paste avoids dependence on the user's active input method. Preserve
/// opaque clipboard data without logging it or overwriting a newer selection.
@MainActor
enum UITestClipboard {
    static func withText(_ text: String, perform action: () -> Void) {
        let pasteboard = NSPasteboard.general
        let initialChange = pasteboard.changeCount
        var original: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else {
                    XCTFail("Cannot preserve the clipboard; leaving it unchanged.")
                    return
                }
            }
            original.append(copy)
        }
        guard pasteboard.changeCount == initialChange else {
            XCTFail("Clipboard changed during capture; leaving it unchanged.")
            return
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
        let injectedChange = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == injectedChange {
                pasteboard.clearContents()
                if !original.isEmpty { XCTAssertTrue(pasteboard.writeObjects(original), "Clipboard restoration failed.") }
            }
        }
        action()
    }
}
