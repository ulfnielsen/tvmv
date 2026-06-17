import SwiftUI

struct ViewerWindow: View {
    let document: MarkdownDocument
    let fileURL: URL?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model: ViewerModel

    @State private var columns: NavigationSplitViewVisibility = .automatic
    @State private var selection: OutlineItem.ID?
    @State private var showFind = false
    @State private var findText = ""
    @FocusState private var findFocused: Bool

    init(document: MarkdownDocument, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
        _model = StateObject(wrappedValue: ViewerModel(text: document.text, fileURL: fileURL))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(model.outline, selection: $selection) { item in
                Text(item.title)
                    .padding(.leading, CGFloat((item.level - 1) * 12))
                    .lineLimit(1)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            webView
                .overlay(alignment: .topTrailing) { if showFind { findBar } }
        }
        .navigationTitle(fileURL?.lastPathComponent ?? "Untitled")
        .onChange(of: selection) { _, new in
            if let new, let item = model.outline.first(where: { $0.id == new }) {
                model.scrollTo(item)
            }
        }
        // Live-apply typography/theme: styleJSON changes whenever any setting does.
        .onChange(of: settings.styleJSON) { Task { await model.applyStyle() } }
        // Re-resolve auto theme when the system appearance flips.
        .onChange(of: colorScheme) {
            if settings.theme == .auto { Task { await model.applyStyle() } }
        }
        .onChange(of: settings.showOutline) { _, show in
            columns = show ? .all : .detailOnly
        }
        .onAppear {
            columns = settings.showOutline ? .all : .detailOnly
            model.startWatching()
        }
        .onDisappear { model.stopWatching() }
        .onReceive(NotificationCenter.default.publisher(for: .tvmvFind)) { _ in
            showFind = true
            // Defer focus until after the bar is in the hierarchy this runloop turn.
            DispatchQueue.main.async { findFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvmvPrint)) { _ in
            model.printDoc()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvmvReload)) { _ in
            Task { await model.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvmvToggleOutline)) { _ in
            columns = (columns == .detailOnly) ? .all : .detailOnly
        }
    }

    private var webView: some View {
        MarkdownWebView(
            appWebDir: WebResources.baseURL,
            docDir: fileURL?.deletingLastPathComponent(),
            callbacks: MarkdownWebViewCallbacks(
                onOutline: { items in model.outline = items },
                onRenderComplete: { },
                onError: { msg in model.errorMessage = msg },
                onReady: { model.pageReady() }
            ),
            onMakeController: { controller in model.attach(controller: controller) }
        )
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $findText)
                .textFieldStyle(.plain)
                .frame(width: 200)
                .focused($findFocused)
                .onSubmit { model.findNext(forward: true) }
                .onChange(of: findText) { model.find(findText) }
            Text(matchLabel)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Divider().frame(height: 16)
            Button { model.findNext(forward: false) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(model.findCount == 0)
            Button { model.findNext(forward: true) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(model.findCount == 0)
            Button { closeFind() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(8)
        .onExitCommand { closeFind() }
    }

    private var matchLabel: String {
        if findText.isEmpty { return "" }
        return model.findCount == 0 ? "Not found" : "\(model.findIndex)/\(model.findCount)"
    }

    private func closeFind() {
        showFind = false
        findText = ""
        model.clearFind()
    }
}
