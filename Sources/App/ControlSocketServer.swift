import Foundation

/// Unix-domain socket server that exposes WhisperStorm's dictation flow to pickyNotes (and other local clients) over a newline-delimited JSON protocol.
/// The path follows Apple's per-user convention and matches the Rust command in pickyNotes:
///   ~/Library/Application Support/WhisperStorm/control.sock
/// Protocol:
///   one JSON request per line:  {"cmd":"start"} | {"cmd":"stop"} | {"cmd":"status"}
///   one JSON reply per line:    {"ok":true,"phase":"<idle|recording|transcribing|success|error>","text":"..."|null,"error":"..."|null}
/// Start/stop are routed through DictationCoordinator (so all the existing logic — model warmup, ESC handling, errors — runs unchanged);
/// when deliveryMode == .socket the coordinator skips TextInserter.insert and returns the transcript on the wire so it isn't pasted twice.
///
/// Permissions: the app is intentionally not sandboxed (CGEvent posting requires it). The directory is 0700 and the socket 0600
/// (umask 077 around bind(), so there is no window with wider permissions); the Tauri app runs as the same user.
/// Limits: every reply ends with "\n"; a request line above 64 KB is rejected ("request too large"); an idle client is dropped after 5 s.
@MainActor
final class ControlSocketServer {
    static let shared = ControlSocketServer()

    /// Resolved at launch — kept as a constant so logs and tests can reach it.
    static let socketURL: URL = {
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/WhisperStorm/control.sock")
    }()

    private var listenSource: DispatchSourceRead?
    private var socketFD: Int32 = -1

    /// Starts the listener. Safe to call multiple times — old sources/fds are torn down first.
    /// Unlinks any stale socket file (a previous crashed instance may have left one behind).
    func start() {
        stop()
        let url = Self.socketURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // createDirectory leaves an existing directory's mode alone, so set 0700 explicitly.
        _ = dir.withUnsafeFileSystemRepresentation { path in path.map { chmod($0, S_IRWXU) } }
        // Stale socket from a previous launch — unlink so bind() succeeds.
        try? FileManager.default.removeItem(at: url)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { FileLog.write("SOCKET: socket() failed: \(String(cString: strerror(errno)))"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = url.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { FileLog.write("SOCKET: path too long"); close(fd); return }
        _ = pathBytes.withUnsafeBufferPointer { ptr in
            memcpy(&addr.sun_path, ptr.baseAddress!, ptr.count)
        }
        // umask is process-wide; the window is the bind() call at launch only.
        let oldMask = umask(0o077)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        if bindResult != 0 {
            FileLog.write("SOCKET: bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        // 0600 — same user only (pickyNotes runs as the same uid).
        _ = url.withUnsafeFileSystemRepresentation { path in
            path.map { chmod($0, S_IRUSR | S_IWUSR) }
        }
        if listen(fd, 8) != 0 {
            FileLog.write("SOCKET: listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        socketFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInitiated))
        src.setEventHandler { [weak self] in self?.acceptClients() }
        src.resume()
        listenSource = src
        FileLog.write("SOCKET: listening at \(url.path)")
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        try? FileManager.default.removeItem(at: Self.socketURL)
        FileLog.write("SOCKET: stopped")
    }

    private func acceptClients() {
        while true {
            let client = accept(socketFD, nil, nil)
            if client < 0 { return }
            // Each connection is one short exchange; handle it on a background queue so the main actor stays free.
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleConnection(fd: client)
            }
        }
    }

    private static let maxRequestBytes = 65536

    /// Reads up to one JSON line (at most 64 KB, 5 s per read), parses the command, asks the coordinator,
    /// writes a newline-terminated JSON reply, closes.
    private nonisolated func handleConnection(fd: Int32) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while !buf.contains(UInt8(ascii: "\n")) {
            let n = read(fd, &tmp, tmp.count)  // 0 = EOF, -1 = error or SO_RCVTIMEO
            if n <= 0 { break }
            buf.append(contentsOf: tmp.prefix(n))
            if buf.count > Self.maxRequestBytes { break }
        }
        let reply: [String: Any]
        if buf.count > Self.maxRequestBytes {
            reply = ["ok": false, "phase": "error", "error": "request too large"]
        } else {
            let line = String(decoding: buf, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
            reply = parseAndRun(line: line)
        }
        var data = (try? JSONSerialization.data(withJSONObject: reply, options: [.fragmentsAllowed])) ?? Data()
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, data.count)
        }
    }

    /// Decodes the request line and runs it. Runs on a background queue: stop waits for the transcript there,
    /// because the transcription itself is scheduled on the main actor and must not be blocked.
    private nonisolated func parseAndRun(line: String) -> [String: Any] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            return ["ok": false, "phase": "error", "error": "invalid request"]
        }
        switch cmd {
        case "status":
            return DispatchQueue.main.sync { ControlSocketServer.statusReply(coord: DictationCoordinator.shared) }
        case "start":
            return startReply()
        case "stop":
            return stopReply()
        default:
            return ["ok": false, "phase": "error", "error": "unknown cmd"]
        }
    }

    private static func statusReply(coord: DictationCoordinator) -> [String: Any] {
        ["ok": true, "phase": phaseString(coord.state.phase), "text": NSNull()]
    }

    /// Socket delivery stays on from here until stopReply sees success or error, so the transcript is returned instead of pasted.
    /// Awaits `startDictation()` itself (microphone prompt included, bounded at 30 s) on the socket worker thread, then reads the phase:
    /// ok only on .recording, otherwise the error text. If the wait gives up, the start is abandoned: a recording that begins
    /// afterwards is cancelled, so no late recording is left behind.
    /// shortcut: a client that starts and never stops leaves socket delivery on (hotkey dictation then does not paste) until its next stop; upgrade with a watchdog if clients get flaky.
    private nonisolated func startReply() -> [String: Any] {
        let done = DispatchSemaphore(value: 0)
        let abandoned = AbandonFlag()
        DispatchQueue.main.sync {
            let coord = DictationCoordinator.shared
            if coord.state.phase != .recording && coord.state.phase != .transcribing { coord.deliveryMode = .socket }
            Task { @MainActor in
                await coord.startDictation()
                if abandoned.isSet, coord.state.phase == .recording { coord.cancelDictation() }
                done.signal()
            }
        }
        if done.wait(timeout: .now() + 30) == .timedOut {
            abandoned.set()
            // Covers a start that finished between the timeout and set(); a later one is cancelled by the Task above.
            DispatchQueue.main.sync { DictationCoordinator.shared.cancelDictation() }
        }
        let phase = DispatchQueue.main.sync { DictationCoordinator.shared.state.phase }
        if phase == .recording, !abandoned.isSet { return ["ok": true, "phase": "recording"] }
        if case .error(let msg) = phase { return endDelivery(["ok": false, "phase": "error", "error": msg]) }
        return endDelivery(["ok": false, "phase": DispatchQueue.main.sync { ControlSocketServer.phaseString(phase) }, "error": "dictation did not start"])
    }

    /// Stops the recording and waits for the transcript. Hops to the main actor only to call stopDictation and to read the
    /// state; the waiting happens on the socket worker thread so the main-actor transcription task can run.
    private nonisolated func stopReply() -> [String: Any] {
        let stopped: Bool = DispatchQueue.main.sync {
            let coord = DictationCoordinator.shared
            guard coord.state.phase == .recording else { return false }
            coord.stopDictation()
            return true
        }
        guard stopped else { return endDelivery(["ok": false, "phase": "idle", "error": "nothing to stop"]) }
        // Shorter than the 120 s read timeout of the pickyNotes client, so it gets this error instead of timing out itself.
        let deadline = Date().addingTimeInterval(110)
        while Date() < deadline {
            let settled: [String: Any]? = DispatchQueue.main.sync {
                let state = DictationCoordinator.shared.state
                switch state.phase {
                case .success: return ["ok": true, "phase": "success", "text": state.lastTranscript]
                case .error(let msg): return ["ok": false, "phase": "error", "error": msg]
                case .idle: return ["ok": false, "phase": "idle", "error": "no speech recorded"]
                default: return nil
                }
            }
            if let settled { return endDelivery(settled) }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return endDelivery(["ok": false, "phase": "error", "error": "transcription timeout"])
    }

    /// Back to hotkey delivery once the transcription reached success or error (or the wait gave up).
    private nonisolated func endDelivery(_ reply: [String: Any]) -> [String: Any] {
        DispatchQueue.main.sync { DictationCoordinator.shared.deliveryMode = .hotkey }
        return reply
    }

    private static func phaseString(_ phase: AppState.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .success: "success"
        case .error: "error"
        }
    }
}

/// Set from the socket worker when it stops waiting for a start; read on the main actor.
private final class AbandonFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
