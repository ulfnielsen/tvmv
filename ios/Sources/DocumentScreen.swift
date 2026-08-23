import SwiftUI
import TVMVCore

struct DocumentScreen: View {
    @Binding var document: MarkdownEditableDocument
    let fileURL: URL?

    @StateObject private var model: ViewerModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: OutlineItem.ID?
    @State private var showFind = false
    @State private var findText = ""
    @FocusState private var findFocused: Bool

    init(document: Binding<MarkdownEditableDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        _model = StateObject(wrappedValue: ViewerModel(
            text: document.wrappedValue.text, fileURL: fileURL,
            encoding: document.wrappedValue.encodingUsed,
            lineEnding: document.wrappedValue.lineEndingUsed))
    }

    var body: some View {
        NavigationSplitView {
            List(model.outline, selection: $selection) { item in
                Text(item.title)
                    .padding(.leading, CGFloat((item.level - 1) * 12))
                    .lineLimit(1)
            }
            .navigationTitle(fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
        } detail: {
            panes
                .overlay(alignment: .topTrailing) { if showFind { findBar } }
                .overlay(alignment: .bottom) {
                    if let message = model.errorMessage { errorBanner(message) }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.toggleEditing() } label: {
                            Image(systemName: model.isEditing
                                  ? "pencil.circle.fill" : "pencil.circle")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showFind = true; findFocused = true } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
        }
        .onAppear {
            // Every settled edit flows into the document binding; the system
            // document machinery autosaves and handles conflicts from there.
            model.onTextChange = { document.text = $0 }
        }
        .onChange(of: settings.editorStyleJSON) { Task { await model.applyEditorStyle() } }
        .onChange(of: selection) { _, new in
            if let new, let item = model.outline.first(where: { $0.id == new }) {
                model.scrollTo(item)
            }
        }
        .onChange(of: settings.styleJSON) { Task { await model.applyPreviewStyle() } }
        .onChange(of: colorScheme) {
            if settings.theme == .auto { Task { await model.applyPreviewStyle() } }
        }
        .background(chromeColor ?? Color(.systemBackground))
    }

    private var chromeColor: Color? {
        model.chromeColor.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
    }

    private var panes: some View {
        HStack(spacing: 0) {
            if model.isEditing {
                editorPane.frame(minWidth: 280)
                Divider()
            }
            preview.frame(minWidth: 280)
        }
    }

    private var editorPane: some View {
        EditorPaneView(
            appWebDir: WebResources.baseURL,
            callbacks: EditorBridgeCallbacks(
                onReady: { model.editorReady(bridge: $0) },
                onTextPatch: { patches, length in
                    model.editorTextPatched(patches, expectedLength: length)
                },
                onCursorMoved: { line, offset in
                    model.editorCursorMoved(line: line, offset: offset)
                },
                onScrolled: { model.editorScrolled(topLine: $0) },
                onError: { model.errorMessage = $0 }
            ),
            onMakeBridge: { model.attach(editor: $0) }
        )
    }

    private var preview: some View {
        PreviewWebView(
            appWebDir: WebResources.baseURL,
            docDir: fileURL?.deletingLastPathComponent(),
            callbacks: MarkdownWebViewCallbacks(
                onOutline: { model.outline = $0 },
                onError: { message in
                    if !model.isEditing { model.errorMessage = message }
                },
                onReady: { model.pageReady() },
                onSourceClick: { model.previewClicked(line: $0) }
            ),
            onMakeController: { model.attach(controller: $0) }
        )
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: $findText)
                .textFieldStyle(.plain)
                .frame(width: 200)
                .focused($findFocused)
                .onSubmit { model.findNext(forward: true) }
                .onChange(of: findText) { model.find(findText) }
            Text(matchLabel).font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
            Button { model.findNext(forward: false) } label: {
                Image(systemName: "chevron.up")
            }.disabled(model.findCount == 0)
            Button { model.findNext(forward: true) } label: {
                Image(systemName: "chevron.down")
            }.disabled(model.findCount == 0)
            Button {
                showFind = false; findText = ""; model.clearFind()
            } label: { Image(systemName: "xmark") }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }

    private var matchLabel: String {
        if findText.isEmpty { return "" }
        return model.findCount == 0 ? "Not found"
            : "\(model.findIndex)/\(model.findCount)"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            Text(message).font(.caption).lineLimit(2)
            Spacer()
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }
}
