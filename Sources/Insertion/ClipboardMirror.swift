import AppKit

/// Keeps the clipboard on the running transcript during live dictation.
///
/// Intermediate states carry `org.nspasteboard.TransientType`
/// (nspasteboard.org), so clipboard history apps (Raycast, Paste, Maccy)
/// skip them; only the final transcript is a normal entry. Esc restores
/// whatever was on the clipboard before the recording.
@MainActor
final class ClipboardMirror {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard
    /// The clipboard before our first write, type by type.
    private var saved: [[NSPasteboard.PasteboardType: Data]]?
    private var lastWrittenChangeCount: Int?
    private var lastText: String?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func writeTransient(_ text: String) {
        guard text != lastText else { return }
        if saved == nil {
            saved = (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
            }
        }
        write(text, transient: true)
    }

    func writeFinal(_ text: String) {
        write(text, transient: false)
    }

    /// Puts the pre-recording clipboard back, unless something else wrote
    /// to the clipboard since our last write.
    func restore() {
        guard let saved, lastWrittenChangeCount == pasteboard.changeCount else { return }
        pasteboard.clearContents()
        let items = saved.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        self.saved = nil
    }

    private func write(_ text: String, transient: Bool) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient { item.setData(Data(), forType: Self.transientType) }
        pasteboard.writeObjects([item])
        lastWrittenChangeCount = pasteboard.changeCount
        lastText = transient ? text : nil
    }
}
