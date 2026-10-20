import TVMVCore
import SwiftUI
import AppKit

struct ViewerWindow: View {
    // The document is consumed in init (seeds the model); storing it here would
    // keep a second copy of the full text alive for the window's lifetime.
    let fileURL: URL?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model: ViewerModel
    /// Imperative handle on the native view: outline jumps, bookmarks, find, markup commands.
    @State private var native = NativeDocumentController()

    @State private var columns: NavigationSplitViewVisibility = .automatic
    @State private var selection: OutlineItem.ID?

    init(document: MarkdownDocument, fileURL: URL?) {
        self.fileURL = fileURL
        _model = StateObject(wrappedValue: Self.makeModel(document, fileURL))
    }

    private static func makeModel(_ document: MarkdownDocument, _ fileURL: URL?) -> ViewerModel {
        let model = ViewerModel(
            text: document.text, fileURL: fileURL,
            encoding: document.encodingUsed, lineEnding: document.lineEndingUsed)
        model.rendersPreview = false   // the native view renders the text itself
        return model
    }

    /// Settings' light/dark, or the system appearance when set to auto.
    private var theme: NativeTheme {
        let dark = settings.theme == .auto ? colorScheme == .dark : settings.theme == .dark
        return NativeTheme(settings: settings, dark: dark)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(model.outline, selection: $selection) { item in
                Text(item.title)
                    .padding(.leading, CGFloat((item.level - 1) * 12))
                    .lineLimit(1)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 240)
            .scrollContentBackground(model.chromeColor == nil ? .automatic : .hidden)
            .background(model.chromeColor.map {
                Color(red: $0.red, green: $0.green, blue: $0.blue)
            } ?? .clear)
        } detail: {
            NativeDocumentView(model: model, controller: native, theme: theme, isEditable: model.isEditing)
                .overlay(alignment: .top) {
                    if model.externalChangePending { externalChangeBanner }
                }
                .overlay(alignment: .bottom) {
                    if model.errorMessage != nil { errorBanner }
                }
        }
        .background { WindowChrome(color: model.chromeColor) }
        .background { WindowCloseGuard(
            needsFlow: { model.isDirty || model.isEditing },
            flush: { await model.flushEditorText() },
            isDirty: { model.isDirty },
            save: { model.save(); return !model.isDirty }
        ) }
        .navigationTitle(fileURL?.lastPathComponent ?? "Untitled")
        // Dirty indicator. Deliberately NOT window.isDocumentEdited: marking a
        // DocumentGroup(viewing:) window "edited" drags in AppKit's autosave
        // machinery, which can't save this document and alerts about it.
        .navigationSubtitle(model.isDirty ? "Edited" : "")
        .toolbar {
            ToolbarItemGroup {
                Button { model.toggleEditing() } label: {
                    Image(systemName: model.isEditing ? "pencil.circle.fill" : "pencil.circle")
                        .foregroundStyle(model.isEditing ? Color(nsColor: theme.accent) : Color.secondary)
                }
                .disabled(fileURL == nil)
                .help(model.isEditing ? "Stop editing (⌘E)" : "Edit (⌘E)")
                Text("\(Int((model.readingProgress * 100).rounded()))%")
                    .monospacedDigit()
                    .help("Reading progress")
                Button { model.nativeSaveBookmark(offset: native.topVisibleOffset()) } label: {
                    Image(systemName: "bookmark")
                }
                .help("Bookmark current place")
                Button { native.restore(model.nativeBookmark) } label: {
                    Image(systemName: "bookmark.fill")
                }
                .disabled(!model.hasBookmark)
                .help("Go to bookmark")
            }
        }
        .onChange(of: selection) { _, new in
            if let new, let item = model.outline.first(where: { $0.id == new }) {
                native.scrollTo(anchor: item.anchor)
            }
        }
        .onChange(of: theme.paper, initial: true) { model.chromeColor = theme.chromeColor(editing: model.isEditing) }
        .onChange(of: model.isEditing) { model.chromeColor = theme.chromeColor(editing: model.isEditing) }
        .onAppear {
            columns = settings.showOutline ? .all : .detailOnly
            model.startWatching()
        }
        .onDisappear { model.stopWatching() }
        .alert("Save Failed", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.saveError ?? "")
        }
        // Publish this window's command actions to the menu only while it is the
        // focused scene — so Find/Print/Reload/Toggle-Outline hit just this window.
        .focusedSceneValue(\.viewerCommands, ViewerCommands(
            find: { native.showFind() },
            printDocument: {
                PrintRenderer.print(text: model.text,
                                    title: fileURL?.deletingPathExtension().lastPathComponent,
                                    documentDirectory: fileURL?.deletingLastPathComponent(),
                                    sheetWindow: native.window)
            },
            reload: { Task { await model.reload() } },
            toggleOutline: { columns = (columns == .detailOnly) ? .all : .detailOnly },
            toggleEditing: { model.toggleEditing() },
            save: { Task { await model.flushAndSave() } },
            revealMarkup: { native.toggleRevealMarkup() },
            showMarkdown: { native.toggleShowMarkdown() },
            bold: { native.bold() },
            italic: { native.italic() },
            canSave: (model.isDirty || model.isEditing) && fileURL != nil,
            canEdit: fileURL != nil,
            isEditing: model.isEditing
        ))
    }

    private var errorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            Text(model.errorMessage ?? "")
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(8)
    }

    private var externalChangeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("File changed on disk")
                .font(.caption)
            Spacer()
            Button("Reload (discards edits)") {
                Task { await model.discardAndReload() }
            }
            .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(8)
    }
}

/// Paints the host NSWindow's background so the theme color extends past the
/// content into the window chrome — including the title bar (made transparent so
/// it shows the window background) and the area behind the sidebar. Chrome text
/// (title, sidebar, traffic lights) is flipped light/dark for legibility.
private struct WindowChrome: NSViewRepresentable {
    var color: RGBAColor?
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        let color = color
        DispatchQueue.main.async {
            guard let w = nsView.window else { return }
            if let c = color {
                w.titlebarAppearsTransparent = true   // show the window bg in the title bar
                w.backgroundColor = NSColor(srgbRed: c.red, green: c.green,
                                            blue: c.blue, alpha: c.alpha)
                w.appearance = NSAppearance(named: c.luminance < 0.6 ? .darkAqua : .aqua)
            } else {
                w.titlebarAppearsTransparent = false
                w.backgroundColor = .windowBackgroundColor
                w.appearance = nil
            }
        }
    }
}
