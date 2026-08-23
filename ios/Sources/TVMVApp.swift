import SwiftUI
import TVMVCore

@main
struct TVMVApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownEditableDocument()) { configuration in
            DocumentScreen(document: configuration.$document,
                           fileURL: configuration.fileURL)
        }
    }
}
