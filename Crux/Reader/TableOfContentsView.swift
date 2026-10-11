import SwiftUI

/// Headings extracted from the rendered page, indented by heading level.
struct TableOfContentsView: View {
    let tab: ReaderTab

    var body: some View {
        List(tab.tableOfContents) { item in
            Button {
                tab.scrollToAnchor(item.id)
            } label: {
                Text(item.title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, CGFloat(max(0, item.level - 1)) * 10)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.sidebar)
        .accessibilityLabel("reader.tableOfContents.accessibilityLabel")
    }
}
