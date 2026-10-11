import SwiftUI
import WebKit

/// Hosts a tab's `WKWebView` inside SwiftUI.
///
/// The web view is owned by `ReaderTab` rather than created here, because
/// SwiftUI recreates view values freely and a rebuilt web view would lose the
/// rendered page and its scroll position.
struct DocumentWebView: NSViewRepresentable {
    let tab: ReaderTab

    func makeNSView(context: Context) -> WKWebView {
        tab.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
