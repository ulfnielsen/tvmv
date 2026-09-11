import SwiftUI
import TVMVCore

// .sheet(item:) needs Identifiable; a temp-file share URL identifies itself.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct DocumentScreen: View {
    @Binding var document: MarkdownEditableDocument
    let fileURL: URL?

    @StateObject private var model: ViewerModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showFind = false
    @State private var findText = ""
    @FocusState private var findFocused: Bool
    @State private var showOutlineSheet = false
    @State private var showSettings = false
    @State private var pdfURL: URL?
    /// The editor web view is created on first use and then kept alive.
    @State private var editorCreated = false
    /// Kept so re-entering edit mode can re-attach: the model releases its
    /// bridge on close, and a kept-alive page fires `ready` only once.
    @State private var editorBridge: EditorBridge?

    init(document: Binding<MarkdownEditableDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        _model = StateObject(wrappedValue: ViewerModel(
            text: document.wrappedValue.text, fileURL: fileURL,
            encoding: document.wrappedValue.encodingUsed,
            lineEnding: document.wrappedValue.lineEndingUsed))
    }

    var body: some View {
        // No NavigationSplitView / navigationTitle here: DocumentGroup already
        // wraps the document in its own navigation bar (back-to-browser,
        // renameable filename, overflow menu). Nesting our own bar doubled
        // every piece of chrome. Our controls attach to the provided bar; the
        // outline is a sheet at every size.
        panes
            .overlay(alignment: .topTrailing) { if showFind { findBar } }
            .overlay(alignment: .bottom) {
                if let message = model.errorMessage { errorBanner(message) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showOutlineSheet = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .disabled(model.outline.isEmpty)
                }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sharePDF() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "textformat.size")
                    }
                }
            }
        .sheet(isPresented: $showOutlineSheet) {
            NavigationStack {
                List(model.outline) { item in
                    Button {
                        model.scrollTo(item)
                        showOutlineSheet = false
                    } label: {
                        Text(item.title)
                            .padding(.leading, CGFloat((item.level - 1) * 12))
                    }
                }
                .navigationTitle("Outline")
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) { IOSSettingsView() }
        .sheet(item: $pdfURL) { url in
            ShareLink(item: url) { Label("Share PDF", systemImage: "doc.richtext") }
                .padding(40)
                .presentationDetents([.medium])
        }
        .onAppear {
            // Every settled edit flows into the document binding; the system
            // document machinery autosaves and handles conflicts from there.
            model.onTextChange = { document.text = $0 }
        }
        .onChange(of: settings.editorStyleJSON) { Task { await model.applyEditorStyle() } }
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
        // Both web views stay ALIVE across edit toggles: tearing down a
        // WKWebView while it is still first responder (keyboard up) is a
        // crash-prone UIKit path, and destroying the hidden preview would
        // disconnect the live re-render pipeline while editing.
        Group {
            if hSizeClass == .compact {
                // One pane visible at a time; the toolbar pencil toggles.
                ZStack {
                    preview
                        .opacity(model.isEditing ? 0 : 1)
                        .allowsHitTesting(!model.isEditing)
                    if editorCreated {
                        editorPane
                            .opacity(model.isEditing ? 1 : 0)
                            .allowsHitTesting(model.isEditing)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    if editorCreated {
                        editorPane
                            .frame(minWidth: model.isEditing ? 280 : 0,
                                   maxWidth: model.isEditing ? .infinity : 0)
                            .opacity(model.isEditing ? 1 : 0)
                            .allowsHitTesting(model.isEditing)
                        if model.isEditing { Divider() }
                    }
                    preview.frame(minWidth: 280)
                }
            }
        }
        .onChange(of: model.isEditing) { _, editing in
            if editing {
                if let bridge = editorBridge {
                    // Re-entering with the kept-alive editor: the page's
                    // `ready` fired long ago, so re-attach and re-seed here.
                    model.attach(editor: bridge)
                    model.editorReady(bridge: bridge)
                } else {
                    editorCreated = true   // first time: `ready` drives setup
                }
            } else {
                // Hidden, not torn down — so hand the keyboard back explicitly.
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil)
            }
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
            onMakeBridge: { bridge in
                editorBridge = bridge
                model.attach(editor: bridge)
            }
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
                onSourceClick: { model.previewClicked($0) }
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

    private func sharePDF() {
        Task {
            guard let data = await model.controllerPDFData() else { return }
            let name = (fileURL?.deletingPathExtension().lastPathComponent ?? "document")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(name + ".pdf")
            do {
                try data.write(to: url)
                pdfURL = url
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
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
