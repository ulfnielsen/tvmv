import SwiftUI
import TVMVCore

struct DocumentScreen: View {
    @Binding var document: MarkdownEditableDocument
    let fileURL: URL?

    var body: some View {
        Text(document.text)
            .padding()
            .navigationTitle(fileURL?.lastPathComponent ?? "Untitled")
    }
}
