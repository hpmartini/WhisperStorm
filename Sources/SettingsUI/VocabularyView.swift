import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Edits `vocabulary.txt`: every change is saved at once and used by the next
/// dictation. Comment lines (`#`) in the file are kept as its header.
@MainActor
final class VocabularyEditor: ObservableObject {
    @Published var entries: [String] = [] {
        didSet { save() }
    }
    private var header: [String] = []
    private var loading = false
    private let url: URL

    init(url: URL = Vocabulary.fileURL) {
        self.url = url
    }

    /// Re-reads the file (it may have been edited in a text editor).
    func reload() {
        _ = Vocabulary.load(from: url)  // writes the default list on first use
        let lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: .newlines)
        loading = true
        header = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        entries = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        loading = false
    }

    /// Appends the entries of a text file, one per line, skipping ones already listed.
    func importLines(from file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let new = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !entries.contains($0) }
        entries.append(contentsOf: new)
    }

    var fileURL: URL { url }

    private func save() {
        guard !loading else { return }
        let body = entries.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try? (header + body + [""]).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

struct VocabularyView: View {
    @ObservedObject var editor: VocabularyEditor
    @State private var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terms help Whisper spell names and jargon (DATEV, ADDISON). Write `wrong → right` to always replace a word Whisper keeps getting wrong. Changes apply to the next dictation.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(editor.entries.indices, id: \.self) { index in
                    TextField("Term or wrong → right", text: Binding(
                        get: { editor.entries.indices.contains(index) ? editor.entries[index] : "" },
                        set: { if editor.entries.indices.contains(index) { editor.entries[index] = $0 } }
                    ))
                    .textFieldStyle(.plain)
                    .tag(index)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            HStack(spacing: 8) {
                Button {
                    editor.entries.append("")
                    selection = editor.entries.count - 1
                } label: { Image(systemName: "plus") }
                .help("Add a term")
                Button {
                    guard let selection, editor.entries.indices.contains(selection) else { return }
                    editor.entries.remove(at: selection)
                    self.selection = nil
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                .help("Remove the selected term")
                Spacer()
                Button("Import…") { importFile() }
                Button("Open as Text File") { NSWorkspace.shared.open(editor.fileURL) }
            }
        }
        .padding(16)
        .frame(width: 440, height: 460)
        .onAppear { editor.reload() }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            editor.importLines(from: url)
        }
    }
}

/// The Vocabulary window (the app has no regular windows otherwise).
@MainActor
final class VocabularyWindowController {
    private var window: NSWindow?
    private let editor = VocabularyEditor()

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: VocabularyView(editor: editor)))
            window.title = "Vocabulary"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        editor.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
