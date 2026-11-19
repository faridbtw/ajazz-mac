import Foundation

typealias JSON = [String: Any]

struct EditorError: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

struct KeyboardLayout: Decodable {
    struct Key: Decodable {
        let nombre: String?
        let etiqueta: String
        let slot: Int?
        let x: Double
        let y: Double

        var name: String? { nombre ?? (etiqueta == "Fn" ? "fn" : nil) }
    }

    let layout: [Key]
    let keys: [String: UInt8]
    let media: [String: UInt16]
    let mouse: [String: [UInt8]]
    let effects: [String: UInt8]

    static let modifiers: [(String, UInt8)] = [
        ("ctrl", 1), ("shift", 2), ("option", 4), ("cmd", 8),
        ("ctrl_der", 16), ("shift_der", 32), ("alt_der", 64), ("win_der", 128)
    ]
}

struct Assignment: Equatable {
    let destination: String
    let mode: String?
    let repeats: Int?

    init(_ destination: String, mode: String? = nil, repeats: Int? = nil) {
        self.destination = destination
        self.mode = mode
        self.repeats = repeats
    }

    init(_ data: JSON) throws {
        guard let target = data["destino"] as? String, !target.isEmpty else {
            throw EditorError("Choose a key or action.")
        }
        self.init(target, mode: data["modo"] as? String, repeats: data["veces"] as? Int)
    }

    var json: JSON {
        var data: JSON = ["destino": destination]
        if let mode { data["modo"] = mode }
        if let repeats { data["veces"] = repeats }
        return data
    }

    func slot(layout: KeyboardLayout) throws -> [UInt8] {
        if let usage = layout.media[destination] {
            return [0x30, UInt8(truncatingIfNeeded: usage), UInt8(usage >> 8)]
        }
        if let mouse = layout.mouse[destination], mouse.count == 2 {
            return mouse[0] == 1 ? [0x40, mouse[1], 0] : [0x40, 0, mouse[1]]
        }
        var usage: UInt8 = 0
        var mods: UInt8 = 0
        for part in destination.split(separator: "+", omittingEmptySubsequences: false) {
            if let bit = KeyboardLayout.modifiers.first(where: { $0.0 == part })?.1 {
                mods |= bit
            } else if let key = layout.keys[String(part)], usage == 0 {
                usage = key
            } else {
                throw EditorError("Choose a single key and any modifier keys.")
            }
        }
        guard usage != 0 || mods != 0 else { throw EditorError("Choose a key or modifier.") }
        return [0x20, mods, usage]
    }

}

struct KeyboardProfile: Codable {
    let settings: [UInt8]
    let keymap: [UInt8]
    let colors: [UInt8]

    init(device: Keyboard) throws {
        settings = try device.read()
        keymap = try device.readTable(0x08)
        colors = try device.readTable(0x0A)
    }

    func write(to device: Keyboard, previous: KeyboardProfile) throws {
        guard settings.count == 29, keymap.count == 384, colors.count == 384 else {
            throw EditorError("The saved keyboard profile has invalid data.")
        }
        try device.writeVerified(
            .init(write: 0x06, read: 0x05, updated: settings, original: previous.settings),
            .init(write: 0x09, read: 0x08, updated: keymap, original: previous.keymap),
            .init(write: 0x0B, read: 0x0A, updated: colors, original: previous.colors)
        )
    }
}
