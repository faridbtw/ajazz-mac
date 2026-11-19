import AppKit
import WebKit

private final class EditorWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            if let action = item.action, NSStringFromSelector(action).localizedCaseInsensitiveContains("reload") {
                menu.removeItem(item)
            }
        }
    }
}

final class EditorSession: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private let queue = DispatchQueue(label: "com.local.ajazz.editor")
    private let layout: KeyboardLayout
    private let catalog: JSON
    private let distribution: [[String: Any]]
    private let root: URL
    private let profileURL: URL
    private var defaults: [UInt8]?
    private var observed: [UInt8]?
    private var rendered: [String: Assignment] = [:]
    private var profile: KeyboardProfile?
    private var priorBrightness: UInt8 = 4
    private let music: Music
    let webView: WKWebView
    private let editorHTML: String

    init(root: URL) throws {
        self.root = root
        let bytes = try Data(contentsOf: root.appendingPathComponent("device.json"))
        let document = try JSONSerialization.jsonObject(with: bytes) as? JSON
        guard let catalog = document?["catalog"] as? JSON,
              let distribution = document?["layout"] as? [[String: Any]] else {
            throw EditorError("The keyboard layout is missing.")
        }
        self.catalog = catalog
        self.distribution = distribution
        layout = try JSONDecoder().decode(KeyboardLayout.self, from: bytes)
        profileURL = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("Ajazz Control/Keyboard Profile.json")
        music = Music(journal: profileURL.deletingLastPathComponent().appendingPathComponent("Music Lighting.json"))
        let page = try String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8)
        let translations = try String(contentsOf: root.appendingPathComponent("en.json"), encoding: .utf8)
            .replacingOccurrences(of: "</", with: "<\\/")
        editorHTML = page.replacingOccurrences(of: "{} /*TEXTOS*/", with: translations)
            .replacingOccurrences(of: "\"es\" /*IDIOMA*/", with: "\"en\"")
            .replacingOccurrences(of: "{} /*DEVICE*/", with: String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "</", with: "<\\/"))

        let configuration = WKWebViewConfiguration()
        webView = EditorWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "keyboard")
        webView.navigationDelegate = self
        loadEditor()
    }

    private func loadEditor() {
        webView.loadHTMLString(editorHTML, baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .reload ? .cancel : .allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadEditor()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let request = message.body as? JSON,
              let path = request["path"] as? String else {
            replyHandler(nil, "Invalid request.")
            return
        }
        if path == "/api/input-monitoring" {
            let granted = CGRequestListenEventAccess()
            if !granted, let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(settings)
            }
            replyHandler(["ok": granted], nil)
            return
        }
        let body = request["body"] as? JSON ?? [:]
        queue.async {
            let result: JSON
            do {
                result = try self.handle(path, body)
            } catch {
                let key = path == "/api/estado" ? "bridgeError" : "mensaje"
                result = ["ok": false, key: error.localizedDescription]
            }
            DispatchQueue.main.async { replyHandler(result, nil) }
        }
    }

    func stopMusic() { music.stop() }

    private func handle(_ path: String, _ body: JSON) throws -> JSON {
        if path == "/api/conexion" {
            var state: JSON = ["conexion": NSNull(), "musica": music.mode as Any? ?? NSNull(),
                               "musica_error": music.error]
            do {
                _ = try Keyboard()
                state["conexion"] = "cable"
            } catch KeyboardError.permission {
                state["needsInputMonitoring"] = true
                state["connectionMessage"] = KeyboardError.permission.localizedDescription
            } catch {
                state["connectionMessage"] = error.localizedDescription
            }
            return state
        }
        if path == "/api/validar" {
            let assignment = try Assignment(object(body, "asignacion"))
            _ = try assignment.slot(layout: layout)
            return ["ok": true]
        }
        if path == "/api/musica" {
            if body["accion"] as? String == "parar" {
                music.stop()
            } else {
                guard let mode = body["modo"] as? String,
                      (catalog["modos_musica"] as? [String])?.contains(mode) == true else {
                    throw EditorError("Choose a music mode.")
                }
                music.start(mode: mode, keys: layout.layout, binary: root.appendingPathComponent("Spectrum"))
            }
            return ["ok": true, "musica": music.mode as Any? ?? NSNull()]
        }

        guard music.mode == nil || path == "/api/estado" else {
            throw EditorError("Stop Music mode before saving other settings.")
        }
        let keyboard = try Keyboard()
        switch path {
        case "/api/estado":
            if music.mode != nil, let profile { return state(profile) }
            try music.restoreIfNeeded(on: keyboard)
            let fresh = try KeyboardProfile(device: keyboard)
            try readKeymap(fresh.keymap, keyboard: keyboard)
            profile = fresh
            return state(fresh)
        case "/api/enviar":
            try applyKeymap(object(body, "config"), keyboard: keyboard)
            return ["ok": true, "mensaje": "Saved to keyboard.", "config": bindings]
        case "/api/luces":
            let data = try object(body, "luces")
            guard let name = data["efecto"] as? String, let mode = layout.effects[name] else {
                throw EditorError("Choose a lighting effect.")
            }
            let rgb = try color(data["color"])
            var changes: [Int: UInt8] = [
                1: mode, 2: try num(data["brillo"], 1...5) - 1,
                3: 5 - (try num(data["velocidad"], 1...5)), 5: data["arcoiris"] as? Bool == true ? 1 : 0,
                6: rgb[0], 7: rgb[1], 8: rgb[2]
            ]
            if [3, 12, 18].contains(mode) { changes[4] = data["direccion"] as? String == "derecha" ? 1 : 0 }
            let result = try keyboard.apply(changes: changes)
            priorBrightness = result[2]
            try remember(keyboard)
            return ["ok": true, "luces": lights(result)]
        case "/api/apagar", "/api/encender":
            let before = try keyboard.read()
            if before[2] < 5 { priorBrightness = before[2] }
            let result = try keyboard.apply(changes: [2: path == "/api/apagar" ? 5 : priorBrightness])
            try remember(keyboard)
            return ["ok": true, "luces": lights(result)]
        case "/api/colores":
            let data = try object(body, "colores")
            let custom = try object(data, "teclas")
            let background = try color(data["fondo"])
            let brightness = try num(data["brillo"], 1...5)
            let previousColors = try keyboard.readTable(0x0A)
            var table = previousColors
            for key in layout.layout {
                guard let slot = key.slot, let name = key.name else { continue }
                let rgb = try custom[name].map(color) ?? background
                table.replaceSubrange((3 * slot)..<(3 * slot + 3), with: rgb)
            }
            let previousSettings = try keyboard.read()
            return try savePerKeyColors(on: keyboard, previousSettings: previousSettings,
                                        previousColors: previousColors, colors: table,
                                        brightness: brightness - 1)
        case "/api/single-key-color":
            guard let name = body["key"] as? String,
                  let slot = layout.layout.first(where: { $0.name == name })?.slot else {
                throw EditorError("Choose a key with an RGB light.")
            }
            let rgb = try color(body["color"])
            let previousSettings = try keyboard.read()
            let staticMode = previousSettings[1] == 6 && previousSettings[5] == 0
            guard previousSettings[2] < 5, staticMode || previousSettings[1] == 20 else {
                throw EditorError("Use solid Static or Per key lighting to change one key’s color.")
            }
            let previousColors = try keyboard.readTable(0x0A)
            var table = previousColors
            if staticMode {
                for key in layout.layout {
                    guard let position = key.slot else { continue }
                    table.replaceSubrange((3 * position)..<(3 * position + 3),
                                          with: previousSettings[6...8])
                }
            }
            table.replaceSubrange((3 * slot)..<(3 * slot + 3), with: rgb)
            return try savePerKeyColors(on: keyboard, previousSettings: previousSettings,
                                        previousColors: previousColors, colors: table,
                                        brightness: previousSettings[2])
        case "/api/sistema":
            let data = try object(body, "ajustes")
            let new = try object(data, "bloquear")
            let old = try keyboard.read()
            var changes: [Int: UInt8] = [
                22: try num(data["polling"], 0...3), 26: try num(data["respuesta"], 1...4) - 1,
                27: data["fn"] as? String == "alternar" ? 1 : 0
            ]
            for (name, index) in [("win", 20), ("nkro", 21), ("wasd", 19)] {
                let enabled = new[name] as? Bool == true
                if enabled != (old[index] != 0) { changes[index] = enabled ? 1 : 0 }
            }
            let result = try keyboard.apply(changes: changes)
            try remember(keyboard)
            return ["ok": true, "ajustes": system(result)]
        case "/api/reenviar":
            guard FileManager.default.fileExists(atPath: profileURL.path) else {
                throw EditorError("Save a change first to create a local profile.")
            }
            let saved = try JSONDecoder().decode(KeyboardProfile.self, from: Data(contentsOf: profileURL))
            try saved.write(to: keyboard, previous: KeyboardProfile(device: keyboard))
            try readKeymap(saved.keymap, keyboard: keyboard)
            profile = saved
            return state(saved)
        default: throw EditorError("This control is unavailable on the wired AK820.")
        }
    }

    private func object(_ data: JSON, _ key: String) throws -> JSON {
        guard let value = data[key] as? JSON else { throw EditorError("Invalid keyboard settings.") }
        return value
    }

    private func num(_ value: Any?, _ range: ClosedRange<Int>) throws -> UInt8 {
        guard let value = value as? Int, range.contains(value) else {
            throw EditorError("Enter a number between \(range.lowerBound) and \(range.upperBound).")
        }
        return UInt8(value)
    }

    private func color(_ value: Any?) throws -> [UInt8] {
        guard let text = value as? String, text.count == 6, let rgb = UInt32(text, radix: 16) else {
            throw EditorError("Choose a valid RGB color.")
        }
        return [UInt8(rgb >> 16), UInt8(truncatingIfNeeded: rgb >> 8), UInt8(truncatingIfNeeded: rgb)]
    }

    private func hex(_ color: ArraySlice<UInt8>) -> String {
        color.map { String(format: "%02X", $0) }.joined()
    }

    private var bindings: JSON {
        ["normal": rendered.mapValues(\.json), "fn": JSON()]
    }

    private func lights(_ config: [UInt8]) -> JSON {
        let effect = layout.effects.first(where: { $0.value == config[1] })?.key ?? "fijo"
        let brightness = config[2] < 5 ? config[2] : priorBrightness
        let active: JSON = ["efecto": effect, "brillo": brightness + 1, "velocidad": 5 - min(config[3], 4),
                            "direccion": config[4] == 1 ? "derecha" : "izquierda",
                            "color": hex(config[6...8]), "arcoiris": config[5] != 0]
        return config[2] == 5 ? ["efecto": "apagado", "anterior": active] : active
    }

    private func savePerKeyColors(on keyboard: Keyboard, previousSettings: [UInt8],
                                  previousColors: [UInt8], colors table: [UInt8],
                                  brightness: UInt8) throws -> JSON {
        var settings = previousSettings
        settings[1] = 20
        settings[2] = brightness
        settings[18] = 0
        settings[25] = 0
        try keyboard.writeVerified(
            .init(write: 0x06, read: 0x05, updated: settings, original: previousSettings),
            .init(write: 0x0B, read: 0x0A, updated: table, original: previousColors)
        )
        let current = try remember(keyboard)
        return ["ok": true, "luces": lights(current.settings), "colores": colors(current)]
    }

    private func colors(_ profile: KeyboardProfile) -> JSON {
        var values: [String: String] = [:]
        for key in layout.layout {
            guard let slot = key.slot, let name = key.name else { continue }
            values[name] = hex(profile.colors[(slot * 3)..<(slot * 3 + 3)])
        }
        let counts = Dictionary(grouping: values.values, by: { $0 }).mapValues(\.count)
        let background = counts.keys.sorted().max { counts[$0, default: 0] < counts[$1, default: 0] } ?? "000000"
        return ["fondo": background, "teclas": values.filter { $0.value != background },
                "brillo": min(profile.settings[2], 4) + 1]
    }

    private func system(_ config: [UInt8]) -> JSON {
        ["fn": config[27] != 0 ? "alternar" : "mantener", "reposo": "5",
         "respuesta": min(config[26], 3) + 1, "polling": min(config[22], 3),
         "bloquear": ["win": config[20] != 0, "nkro": config[21] != 0, "wasd": config[19] != 0]]
    }

    private func state(_ profile: KeyboardProfile) -> JSON {
        ["ok": true, "distribucion": distribution, "catalogo": catalog, "config": bindings,
         "luces": lights(profile.settings), "colores": colors(profile), "ajustes": system(profile.settings),
         "conexion": "cable",
         "musica": music.mode as Any? ?? NSNull(), "copia_fabrica": NSNull()]
    }

    @discardableResult
    private func remember(_ keyboard: Keyboard) throws -> KeyboardProfile {
        let latest = try KeyboardProfile(device: keyboard)
        profile = latest
        try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(latest).write(to: profileURL, options: .atomic)
        return latest
    }

    private func readKeymap(_ active: [UInt8], keyboard: Keyboard) throws {
        let factory = try keyboard.readTable(0x07)
        var result: [String: Assignment] = [:]
        for key in layout.layout {
            guard let name = key.nombre, let slot = key.slot else { continue }
            let range = slot * 3..<(slot * 3 + 3)
            guard active[range] != factory[range] else { continue }
            let entry = Array(active[range])
            if observed?[range] == active[range], let old = rendered[name] {
                result[name] = old
            } else {
                result[name] = decode(entry)
            }
        }
        defaults = factory
        observed = active
        rendered = result
    }

    private func decode(_ entry: [UInt8]) -> Assignment {
        switch entry[0] {
        case 0x20:
            var names = KeyboardLayout.modifiers.filter { $0.1 & entry[1] != 0 }.map(\.0)
            if let key = layout.keys.keys.sorted(by: { $0.count < $1.count })
                .first(where: { layout.keys[$0] == entry[2] }) {
                names.append(key)
            }
            if !names.isEmpty { return Assignment(names.joined(separator: "+")) }
        case 0x30:
            let code = UInt16(entry[1]) | UInt16(entry[2]) << 8
            if let media = layout.media.first(where: { $0.value == code }) { return Assignment(media.key) }
        case 0x40:
            let value: [UInt8] = entry[1] != 0 ? [1, entry[1]] : [3, entry[2]]
            if let mouse = layout.mouse.first(where: { $0.value == value }) { return Assignment(mouse.key) }
        case 0x70:
            return Assignment("Stored macro \(Int(entry[1]) + 1)")
        default: break
        }
        return Assignment("Custom HID action")
    }

    private func applyKeymap(_ data: JSON, keyboard: Keyboard) throws {
        let requested = try object(data, "normal").mapValues { value in
            guard let record = value as? JSON else { throw EditorError("Invalid key assignment.") }
            return try Assignment(record)
        }
        let current = try keyboard.readTable(0x08)
        guard let defaults, let observed, observed == current else {
            throw EditorError("The keymap changed. Read the keyboard and try again.")
        }
        var updated = current
        for key in layout.layout {
            guard let name = key.nombre, let slot = key.slot, requested[name] != rendered[name] else { continue }
            let range = slot * 3..<(slot * 3 + 3)
            guard let assignment = requested[name] else {
                updated.replaceSubrange(range, with: defaults[range])
                continue
            }
            updated.replaceSubrange(range, with: try assignment.slot(layout: layout))
        }
        if updated != current {
            try keyboard.writeVerified(.init(write: 0x09, read: 0x08, updated: updated, original: current))
        }
        self.observed = updated
        rendered = requested
        try readKeymap(updated, keyboard: keyboard)
        try remember(keyboard)
    }
}
