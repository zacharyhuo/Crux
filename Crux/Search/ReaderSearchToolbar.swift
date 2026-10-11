import AppKit
import CruxCore
import SwiftUI

/// The native search control and its structured result popover.
///
/// SwiftUI's `searchSuggestions` menu only supports completion-style rows on
/// macOS. Crux needs buttons that navigate a hierarchy, enable indexing, open
/// nested groups, and return to a parent route. The smallest reliable bridge is
/// therefore an `NSSearchField` for system search behavior, while SwiftUI keeps
/// ownership of all state and renders the popover content.
struct ReaderSearchToolbar: View {
    @Bindable var model: AppModel
    @Bindable var tab: ReaderTab
    let isActive: Bool
    let focusRequest: Int
    @Binding var isPanelPresented: Bool
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if scopedDescriptor != nil {
                scopeMenu
            }

            NativeSearchField(
                text: queryBinding,
                prompt: searchPrompt,
                isActive: isActive,
                focusRequest: focusRequest &+ tab.search.scopeFocusRequest,
                isPanelPresented: $isPanelPresented,
                onSubmit: onSubmit,
                onDeleteWhenEmpty: { tab.search.clearScopeIfQueryIsEmpty() },
                onCancel: { isPanelPresented = false }
            )
            .frame(maxWidth: .infinity)
        }
        // Keep horizontal focus-ring clearance; the workspace bar supplies
        // vertical clearance outside the 36-point visible control.
        .padding(.horizontal, 4)
        .frame(minWidth: 220, idealWidth: 460, maxWidth: 520)
        .popover(
            isPresented: $isPanelPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    SearchSuggestionsView(
                        model: model,
                        tab: tab,
                        dismiss: { isPanelPresented = false }
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 700, height: panelHeight)
            // Search-field clicks belong to the ongoing search interaction.
            // The native field monitor handles outside clicks explicitly.
            .interactiveDismissDisabled()
            .onExitCommand { isPanelPresented = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isPanelPresented = false
        }
    }

    @ViewBuilder
    private var scopeMenu: some View {
        Menu {
            Button("library.scope.all") {
                tab.search.selectScope(nil)
                isPanelPresented = true
            }

            if !model.docsets.isEmpty {
                Divider()
                ForEach(model.docsets, id: \.identifier) { descriptor in
                    Button {
                        tab.search.showDocset(descriptor.identifier)
                        isPanelPresented = true
                    } label: {
                        DocsetLabel(
                            descriptor: descriptor,
                            catalogData: model.catalogIconData(forDocset: descriptor.identifier),
                            iconSize: DocsetIconMetrics.compact,
                            displayName: model.docsetDisplayName(for: descriptor)
                        )
                    }
                }
            }
        } label: {
            if let descriptor = scopedDescriptor {
                DocsetLabel(
                    descriptor: descriptor,
                    catalogData: model.catalogIconData(forDocset: descriptor.identifier),
                    iconSize: DocsetIconMetrics.compact,
                    displayName: model.docsetDisplayName(for: descriptor)
                )
                .frame(maxWidth: 180, alignment: .leading)
            } else {
                Image(systemName: "magnifyingglass")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityIdentifier("reader-docset-scope")
        .help("library.scope.all.help")
        .accessibilityLabel("library.scope.all.help")
    }

    private var scopedDescriptor: DocsetDescriptor? {
        guard let identifier = tab.search.scopedDocsetIdentifier else { return nil }
        return model.docsets.first { $0.identifier == identifier }
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { tab.search.query },
            set: {
                tab.search.updateQuery($0)
                isPanelPresented = true
            }
        )
    }

    private var searchPrompt: String {
        if let descriptor = scopedDescriptor {
            return String.localizedStringWithFormat(
                String(localized: "search.field.scopedPlaceholder"),
                model.docsetDisplayName(for: descriptor)
            )
        }
        return String(localized: "search.field.placeholder")
    }

    private var panelHeight: CGFloat {
        let rowCount: Int
        switch tab.search.currentRoute {
        case .docsets:
            rowCount = max(model.docsets.count, 1)
        case .docset:
            rowCount = max(tab.search.symbolTypeSummaries.count + 2, 2)
        case .symbolType:
            rowCount = max(min(tab.search.browsedSymbols.count, 250), 1)
        case .results:
            rowCount = max(
                min(tab.search.groupedResults.count, 100)
                    + min(tab.search.fullTextResults.count, 40),
                1
            )
        case let .nested(key):
            rowCount = max(tab.search.nestedGroup(for: key)?.results.count ?? 0, 1)
        }
        return min(560, max(150, CGFloat(rowCount) * 36 + 58))
    }
}

/// A native AppKit search field with a small inset container for its focus ring.
private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let isActive: Bool
    let focusRequest: Int
    @Binding var isPanelPresented: Bool
    let onSubmit: () -> Void
    let onDeleteWhenEmpty: () -> Bool
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SearchFieldContainer {
        let container = SearchFieldContainer()
        let field = container.searchField
        field.delegate = context.coordinator
        container.onSearchFieldInteraction = { [weak coordinator = context.coordinator] in
            coordinator?.requestPanelPresentation()
        }
        container.onOutsideInteraction = { [weak coordinator = context.coordinator] in
            coordinator?.endSearchInteraction()
        }
        // Text changes update suggestions through the delegate. They must not
        // also send the control action, because that action used to open the
        // first result before the user explicitly submitted the search.
        field.target = nil
        field.action = nil
        field.sendsSearchStringImmediately = false
        field.isEnabled = isActive
        container.isInteractionActive = isActive
        field.setAccessibilityIdentifier("reader-search-field")
        return container
    }

    func updateNSView(_ container: SearchFieldContainer, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isUpdatingView = true
        defer { context.coordinator.isUpdatingView = false }
        let field = container.searchField
        container.onSearchFieldInteraction = { [weak coordinator = context.coordinator] in
            coordinator?.requestPanelPresentation()
        }
        container.onOutsideInteraction = { [weak coordinator = context.coordinator] in
            coordinator?.endSearchInteraction()
        }
        Self.synchronizeText(text, in: field)
        if field.placeholderString != prompt {
            field.placeholderString = prompt
        }
        if field.isEnabled != isActive {
            field.isEnabled = isActive
        }
        container.isInteractionActive = isActive

        if !isActive {
            if let window = container.window,
               window.firstResponder === field || window.firstResponder === field.currentEditor() {
                window.makeFirstResponder(nil)
            }
            return
        }

        guard focusRequest != context.coordinator.handledFocusRequest else { return }
        DispatchQueue.main.async { [weak container, weak coordinator = context.coordinator] in
            guard let container,
                  let coordinator,
                  coordinator.parent.isActive,
                  let window = container.window else { return }
            coordinator.handledFocusRequest = focusRequest
            window.makeFirstResponder(container.searchField)
            coordinator.requestPanelPresentation()
        }
    }

    private static func synchronizeText(_ text: String, in field: NSSearchField) {
        guard field.stringValue != text else { return }
        field.stringValue = text
        if let editor = field.currentEditor() {
            editor.string = text
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        var handledFocusRequest: Int
        var isUpdatingView = false

        init(parent: NativeSearchField) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            requestPanelPresentation()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard parent.isActive, !isUpdatingView else { return }
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
            // A recognized docset prefix becomes a scope immediately, before
            // the next keystroke reaches the still-focused field editor.
            NativeSearchField.synchronizeText(parent.text, in: field)
            requestPanelPresentation()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            endSearchInteraction()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.deleteBackward(_:))
                || commandSelector == #selector(NSResponder.deleteForward(_:)) {
                guard parent.isActive, control.stringValue.isEmpty,
                      parent.onDeleteWhenEmpty() else { return false }
                requestPanelPresentation()
                return true
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if control.stringValue.isEmpty {
                    requestPanelPresentation()
                } else {
                    parent.onSubmit()
                }
                return true
            }

            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
                return false
            }
            parent.onCancel()
            return true
        }

        func requestPanelPresentation() {
            guard parent.isActive, !parent.isPanelPresented else { return }
            // Presenting a SwiftUI popover synchronously from AppKit's
            // begin-editing callback is discarded during the same responder
            // transaction. Advancing one main-loop turn makes empty-focus and
            // typed-focus follow the same reliable path.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.isActive, !self.parent.isPanelPresented else { return }
                self.parent.isPanelPresented = true
            }
        }

        func endSearchInteraction() {
            // Updating the scope's placeholder can end native editing while
            // SwiftUI is laying out the control. That is not an outside click.
            guard parent.isActive, !isUpdatingView else { return }
            parent.onCancel()
        }
    }
}

private final class SearchFieldContainer: NSView {
    let searchField = NSSearchField()
    var onSearchFieldInteraction: (() -> Void)?
    var onOutsideInteraction: (() -> Void)?
    var isInteractionActive = false {
        didSet {
            guard isInteractionActive != oldValue else { return }
            updateLocalMouseMonitor()
        }
    }
    private var localMouseMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        searchField.controlSize = .extraLarge
        searchField.font = .systemFont(ofSize: NSFont.systemFontSize)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)
        // The native bezel extends two points beyond each vertical frame edge.
        // Keep that visible bezel aligned with the 36-point action capsules.
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            searchField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    isolated deinit {
        removeLocalMouseMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLocalMouseMonitor()
    }

    private func updateLocalMouseMonitor() {
        removeLocalMouseMonitor()
        guard isInteractionActive, window != nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleMouseDown(event)
        }
    }

    override var intrinsicContentSize: NSSize {
        // Width belongs to SwiftUI: the scope menu may consume part of the
        // composite control, and the search field must accept the remainder.
        NSSize(width: NSView.noIntrinsicMetric, height: 36)
    }

    private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            let fieldLocation = searchField.convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseDown,
               !searchField.stringValue.isEmpty,
               let cell = searchField.cell as? NSSearchFieldCell,
               cell.searchTextRect(forBounds: searchField.bounds).contains(fieldLocation) {
                // Finish native caret placement, selection and drag tracking
                // before deciding whether the panel needs to be presented.
                if searchField.currentEditor() == nil {
                    window.makeFirstResponder(searchField)
                }
                if let editor = searchField.currentEditor() {
                    editor.mouseDown(with: event)
                    onSearchFieldInteraction?()
                    return nil
                }
            }
            // The field editor receives clicks while editing, bypassing
            // NSSearchField.mouseDown. Observe at the container/window edge so
            // every explicit click can reopen a transient popover.
            DispatchQueue.main.async { [weak self] in
                self?.onSearchFieldInteraction?()
            }
        } else {
            window.makeFirstResponder(nil)
            onOutsideInteraction?()
        }
        return event
    }

    private func removeLocalMouseMonitor() {
        guard let localMouseMonitor else { return }
        NSEvent.removeMonitor(localMouseMonitor)
        self.localMouseMonitor = nil
    }
}
