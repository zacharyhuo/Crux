import SwiftUI

/// The window-level tab strip.
///
/// A system `Tab` label is one selection target, so it cannot safely contain a
/// second, independently accessible close button. This strip keeps those two
/// actions as sibling SwiftUI buttons while presenting them as one visual tab.
struct WorkspaceTabStrip: View {
    @Bindable var model: AppModel

    private let minimumTabWidth: CGFloat = 180
    private let maximumTabWidth: CGFloat = 280
    private let maximumStripWidth: CGFloat = 720
    private let tabSpacing: CGFloat = 8

    var body: some View {
        GlassEffectContainer(spacing: tabSpacing) {
            ScrollViewReader { scrollProxy in
                GeometryReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: tabSpacing) {
                            ForEach(model.tabs) { tab in
                                tabItem(tab, width: tabWidth(for: proxy.size.width))
                                    .id(tab.id)
                            }
                        }
                        .frame(minHeight: proxy.size.height)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.selectedTabID, initial: true) { _, selectedID in
                        guard let selectedID else { return }
                        withAnimation(.snappy(duration: 0.2)) {
                            scrollProxy.scrollTo(selectedID, anchor: .trailing)
                        }
                    }
                }
            }
        }
        .frame(
            minWidth: minimumTabWidth,
            idealWidth: stripWidth,
            maxWidth: stripWidth,
            minHeight: 34,
            idealHeight: 34,
            maxHeight: 34
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-tab-strip")
    }

    private var stripWidth: CGFloat {
        let spacing = tabSpacing * CGFloat(max(model.tabs.count - 1, 0))
        let desiredWidth = maximumTabWidth * CGFloat(model.tabs.count) + spacing
        return min(maximumStripWidth, desiredWidth)
    }

    private func tabWidth(for availableWidth: CGFloat) -> CGFloat {
        guard !model.tabs.isEmpty else { return availableWidth }
        let spacing = tabSpacing * CGFloat(max(model.tabs.count - 1, 0))
        let fittedWidth = (availableWidth - spacing - 8) / CGFloat(model.tabs.count)
        return min(maximumTabWidth, max(minimumTabWidth, fittedWidth))
    }

    private func tabItem(_ tab: ReaderTab, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button {
                model.selectedTabID = tab.id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tab.isWelcome ? "sparkles" : "doc.text")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(tab.displayTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.displayTitle)
            .accessibilityAddTraits(model.selectedTabID == tab.id ? .isSelected : [])
            .accessibilityIdentifier("workspace-tab")

            Button {
                model.closeTab(tab.id)
            } label: {
                Label("reader.action.closeTab", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 30)
            .help("reader.action.closeTab")
            .accessibilityLabel(
                Text(verbatim: "\(String(localized: "reader.action.closeTab")) \(tab.displayTitle)")
            )
            .accessibilityIdentifier("workspace-tab-close")
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(width: width, height: 34)
        .glassEffect(
            model.selectedTabID == tab.id
                ? .regular.tint(.accentColor.opacity(0.12)).interactive()
                : .regular.interactive(),
            in: Capsule()
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-tab-item")
    }
}

/// The trailing titlebar action stays separate from the scrollable tab group,
/// so it remains reachable even when many tabs are open.
struct WorkspaceNewTabButton: View {
    @Bindable var model: AppModel

    var body: some View {
        newTabButton
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .help("reader.action.newTab")
            .accessibilityIdentifier("workspace-tab-new")
    }

    private var newTabButton: some View {
        Button {
            model.openTab()
        } label: {
            Label("reader.action.newTab", systemImage: "plus")
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
    }
}
