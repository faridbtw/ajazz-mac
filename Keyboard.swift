import CoreGraphics
import Foundation
import IOKit.hid

enum KeyboardError: LocalizedError {
    case disconnected, permission, ambiguous, io(String, IOReturn), timeout(UInt8), rejected(UInt8, UInt8), verify

    var errorDescription: String? {
        switch self {
        case .disconnected: "Connect your wired Ajazz AK820 over USB."
        case .permission: "ajazz-mac needs Input Monitoring to read this keyboard. Enable it in System Settings, then choose Quit & Reopen."
        case .ambiguous: "Connect only one Ajazz AK820 at a time."
        case let .io(action, code): "\(action) failed (\(String(format: "0x%08X", UInt32(bitPattern: code))))."
        case let .timeout(id): "The keyboard did not answer USB command \(String(format: "0x%02X", id)). Reconnect USB and try again."
        case let .rejected(id, code): "The keyboard rejected USB command \(String(format: "0x%02X", id)) (status \(code))."
        case .verify: "The keyboard returned different settings after saving. Read it again before editing."
        }
    }
}

final class Keyboard {
    static let configLength = 29
    private let device: IOHIDDevice
    private let loop = CFRunLoopGetCurrent()!
    private let mode = CFRunLoopMode(rawValue: "AjazzControl.HID" as CFString)
    private let buffer: UnsafeMutablePointer<UInt8>
    private var expected: [UInt8] = []
    private var reply: [UInt8]?

    static var connectedOverUSB: Bool {
        var devices: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &devices)
                == kIOReturnSuccess else { return false }
        defer { IOObjectRelease(devices) }
        while case let service = IOIteratorNext(devices), service != 0 {
            defer { IOObjectRelease(service) }
            let vendor = IORegistryEntryCreateCFProperty(service, "idVendor" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            let product = IORegistryEntryCreateCFProperty(service, "idProduct" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            if vendor?.intValue == 0x320F, product?.intValue == 0x505B { return true }
        }
        return false
    }

    init() throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))
        let match = [kIOHIDVendorIDKey: 0x320F, kIOHIDProductIDKey: 0x505B]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).filter {
            IOHIDDeviceConformsTo($0, 0xFF1C, 0x92)
        }
        guard devices.count <= 1 else { throw KeyboardError.ambiguous }
        guard let device = devices.first else {
            if Self.connectedOverUSB && !CGPreflightListenEventAccess() { throw KeyboardError.permission }
            throw KeyboardError.disconnected
        }
        let status = IOHIDDeviceOpen(device, 0)
        guard status == kIOReturnSuccess else {
            if status == kIOReturnNotPermitted || status == kIOReturnNotPrivileged {
                throw KeyboardError.permission
            }
            throw KeyboardError.io("Opening USB connection", status)
        }
        self.device = device
        buffer = .allocate(capacity: 64)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, result, _, _, _, report, length in
            guard result == kIOReturnSuccess, let context, length == 64 else { return }
            let keyboard = Unmanaged<Keyboard>.fromOpaque(context).takeUnretainedValue()
            guard !keyboard.expected.isEmpty else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            guard bytes[0...3] == keyboard.expected[0...3],
                  bytes[5...6] == keyboard.expected[5...6] else { return }
            keyboard.reply = bytes
            CFRunLoopStop(keyboard.loop)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, loop, mode.rawValue)
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, loop, mode.rawValue)
        IOHIDDeviceClose(device, 0)
        buffer.deallocate()
    }

    @discardableResult
    func command(_ id: UInt8, length: Int = 0, offset: Int = 0, payload: [UInt8] = [], streaming: Bool = false) throws -> [UInt8] {
        do {
            return try exchange(id, length: length, offset: offset, payload: payload, streaming: streaming)
        } catch KeyboardError.timeout where !streaming {
            return try exchange(id, length: length, offset: offset, payload: payload, streaming: false)
        }
    }

    private func exchange(_ id: UInt8, length: Int = 0, offset: Int = 0, payload: [UInt8] = [], streaming: Bool = false) throws -> [UInt8] {
        precondition(length <= 56 && payload.count <= 56)
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 4
        bytes[3] = id
        bytes[4] = UInt8(length)
        bytes[5] = UInt8(truncatingIfNeeded: offset)
        bytes[6] = UInt8(offset >> 8)
        bytes.replaceSubrange(8..<(8 + payload.count), with: payload)
        let checksum = bytes.dropFirst(3).reduce(0) { $0 + Int($1) }
        bytes[1] = UInt8(truncatingIfNeeded: checksum)
        bytes[2] = UInt8(checksum >> 8)
        expected = bytes
        reply = nil
        defer { expected = [] }
        Thread.sleep(forTimeInterval: streaming ? 0.010 : 0.035)
        let status = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 4, $0.baseAddress!, $0.count)
        }
        guard status == kIOReturnSuccess else { throw KeyboardError.io("Sending USB report", status) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        while reply == nil {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw KeyboardError.timeout(id) }
            let result = CFRunLoopRunInMode(mode, remaining, true)
            if result == .finished { throw KeyboardError.timeout(id) }
        }
        let response = reply!
        guard response[7] == 0 else { throw KeyboardError.rejected(id, response[7]) }
        return Array(response[8..<(8 + length)])
    }

    func readTable(_ commandID: UInt8, count: Int = 384) throws -> [UInt8] {
        try stride(from: 0, to: count, by: 56).flatMap { offset in
            try command(commandID, length: min(56, count - offset), offset: offset)
        }
    }

    func writeTable(_ commandID: UInt8, bytes: [UInt8], streaming: Bool = false) throws {
        for offset in stride(from: 0, to: bytes.count, by: 56) {
            let chunk = Array(bytes[offset..<min(offset + 56, bytes.count)])
            try command(commandID, length: chunk.count, offset: offset, payload: chunk, streaming: streaming)
        }
    }

    func transaction(_ writes: () throws -> Void) throws {
        Thread.sleep(forTimeInterval: 0.22)
        try command(0x01)
        do { try writes() } catch {
            _ = try? command(0x02)
            throw error
        }
        try command(0x02)
    }

    struct BankChange {
        let write: UInt8
        let read: UInt8
        let updated: [UInt8]
        let original: [UInt8]
    }

    func writeVerified(_ changes: BankChange...) throws {
        let updates = changes.filter { $0.updated != $0.original }
        guard !updates.isEmpty else { return }
        do {
            try transaction {
                for change in updates { try writeTable(change.write, bytes: change.updated) }
            }
            for change in updates {
                guard try readTable(change.read, count: change.updated.count) == change.updated else {
                    throw KeyboardError.verify
                }
            }
        } catch {
            let attempted = updates.filter { change in
                (try? readTable(change.read, count: change.original.count)) != change.original
            }
            if !attempted.isEmpty {
                try transaction {
                    for change in attempted { try writeTable(change.write, bytes: change.original) }
                }
                for change in attempted {
                    guard try readTable(change.read, count: change.original.count) == change.original else {
                        throw KeyboardError.verify
                    }
                }
            }
            throw error
        }
    }

    func read() throws -> [UInt8] {
        try command(0x05, length: Self.configLength)
    }

    func apply(changes: [Int: UInt8]) throws -> [UInt8] {
        let current = try read()
        var updated = current
        for (index, value) in changes { updated[index] = value }
        guard updated != current else { return current }
        try writeVerified(.init(write: 0x06, read: 0x05, updated: updated, original: current))
        return updated
    }
}
