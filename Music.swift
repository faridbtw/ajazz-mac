import AppKit

final class Music {
    private let journal: URL
    private let guardLock = NSLock()

    init(journal: URL) { self.journal = journal }
    private let outputQueue = DispatchQueue(label: "com.local.ajazz.music")
    private var child: Process?
    private var input: Pipe?
    private var generation = UUID()
    private var pending: [UInt8] = []
    private var sending = false
    private var lastFrame = 0.0
    private var activeMode: String?
    private var lastError = ""

    var mode: String? { guardLock.withLock { activeMode } }
    var error: String { guardLock.withLock { lastError } }

    func start(mode: String, keys: [KeyboardLayout.Key], binary: URL) {
        if self.mode == mode { return }
        stop()
        let token = UUID()
        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        let log = Pipe()
        process.executableURL = binary
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = log
        guardLock.withLock {
            child = process
            input = stdin
            generation = token
            activeMode = mode
            lastError = ""
            pending = []
            lastFrame = 0
        }
        process.terminationHandler = { [weak self] _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            let details = String(data: log.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self?.finish(token: token, error: details ?? "")
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] stream in
            let bytes = stream.availableData
            guard !bytes.isEmpty else { stream.readabilityHandler = nil; return }
            self?.consume(bytes, token: token, mode: mode, keys: keys)
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            finish(token: token, error: error.localizedDescription)
        }
    }

    func stop() {
        let process = guardLock.withLock {
            generation = UUID()
            activeMode = nil
            lastError = ""
            let previous = child
            child = nil
            if let input { try? input.fileHandleForWriting.close() }
            input = nil
            return previous
        }
        if process?.isRunning == true { process?.terminate() }
        if process != nil {
            outputQueue.sync { restore() }
        }
    }

    private func finish(token: UUID, error: String) {
        let process = guardLock.withLock { () -> Process? in
            guard generation == token else { return nil }
            activeMode = nil
            lastError = error
            let previous = child
            child = nil
            if let input { try? input.fileHandleForWriting.close() }
            input = nil
            generation = UUID()
            return previous
        }
        if let process {
            if process.isRunning { process.terminate() }
            outputQueue.async { self.restore() }
        }
    }

    private func consume(_ bytes: Data, token: UUID, mode: String, keys: [KeyboardLayout.Key]) {
        let levels: [UInt8]? = guardLock.withLock {
            guard generation == token else { return nil }
            pending.append(contentsOf: bytes)
            guard let end = pending.lastIndex(of: 10) else { return nil }
            let start = pending[..<end].lastIndex(of: 10).map { $0 + 1 } ?? 0
            let line = String(decoding: pending[start..<end], as: UTF8.self)
            pending.removeFirst(end + 1)
            let now = ProcessInfo.processInfo.systemUptime
            guard !sending, now - lastFrame >= 0.066 else { return nil }
            let levels = line.split(separator: " ").compactMap { UInt8($0) }
            guard levels.count == 21 else { return nil }
            lastFrame = now
            sending = true
            return levels
        }
        guard let levels else { return }
        outputQueue.async {
            defer { self.guardLock.withLock { self.sending = false } }
            guard self.guardLock.withLock({ self.generation == token }) else { return }
            do {
                let table = self.frame(levels, mode: mode, keys: keys)
                let keyboard = try Keyboard()
                if !FileManager.default.fileExists(atPath: self.journal.path) {
                    let settings = try keyboard.read()
                    try FileManager.default.createDirectory(at: self.journal.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try Data([settings[1], settings[2]]).write(to: self.journal, options: .atomic)
                    _ = try keyboard.apply(changes: [1: 0xFE, 2: 4])
                }
                try keyboard.writeTable(0x12, bytes: table, streaming: true)
            } catch {
                self.finish(token: token, error: error.localizedDescription)
            }
        }
    }

    func restoreIfNeeded(on keyboard: Keyboard) throws {
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let data = Array(try Data(contentsOf: journal))
        guard data.count == 2 else { throw EditorError("The saved lighting recovery data is invalid.") }
        if try keyboard.read()[1] == 0xFE {
            _ = try keyboard.apply(changes: [1: data[0], 2: data[1]])
        }
        try FileManager.default.removeItem(at: journal)
    }

    private func restore() {
        do {
            guard FileManager.default.fileExists(atPath: journal.path) else { return }
            try restoreIfNeeded(on: Keyboard())
        } catch {
            guardLock.withLock { lastError = error.localizedDescription }
        }
    }

    private func frame(_ levels: [UInt8], mode: String, keys: [KeyboardLayout.Key]) -> [UInt8] {
        let palette: [String: (Double, Double, Double)] = [
            "blanco": (1, 1, 1), "rojo": (1, 0, 0), "naranja": (1, 0.32, 0),
            "amarillo": (1, 0.85, 0), "verde": (0, 1, 0), "azul": (0.05, 0.25, 1)
        ]
        var frame = [UInt8](repeating: 0, count: 384)
        for key in keys {
            guard let slot = key.slot else { continue }
            let column = min(20, max(0, Int((key.x + 12) / 29)))
            let row = min(5, max(0, Int((key.y + 10) / 40)))
            let level = max(0, min(1, 6 * Double(levels[column]) / 255 - Double(5 - row)))
            let tint: (Double, Double, Double)
            if let fixed = palette[mode] {
                tint = fixed
            } else if mode == "verde-amarillo-rojo" {
                tint = row < 2 ? (1, 0.04, 0) : row < 4 ? (1, 0.75, 0) : (0, 1, 0.12)
            } else {
                let phase = ProcessInfo.processInfo.systemUptime * 0.12
                let hue: Double
                switch mode {
                case "arcoiris-inverso": hue = 1 - Double(column) / 21
                case "degradado": hue = Double(row) / 9
                case "ciclo": hue = phase.truncatingRemainder(dividingBy: 1)
                default: hue = Double(column) / 21
                }
                let color = NSColor(calibratedHue: hue, saturation: 0.95, brightness: 1, alpha: 1)
                tint = (color.redComponent, color.greenComponent, color.blueComponent)
            }
            frame[slot * 3] = UInt8(tint.0 * level * 255)
            frame[slot * 3 + 1] = UInt8(tint.1 * level * 255)
            frame[slot * 3 + 2] = UInt8(tint.2 * level * 255)
        }
        return frame
    }
}
