import CoreGraphics
import Foundation

// SimPortal's viewer WebSocket protocol, as the companion relays it. Parsing
// and encoding only: no sockets, no rendering, so every rule here is testable.

/// The video codec a viewer asks SimPortal for.
enum SimulatorStreamCodec: String, CaseIterable, Equatable, Sendable {
    case h264
    case jpeg
}

/// SimPortal streams `high` at 1×, `balanced` at 0.75× and `low` at 0.5× of
/// the simulator's pixels. Other viewers can drive the shared size, so the
/// advertised dimensions win over what was asked for.
enum SimulatorStreamQuality: String, CaseIterable, Equatable, Sendable {
    case high
    case balanced
    case low
}

enum SimulatorHardwareButton: String, CaseIterable, Equatable, Sendable {
    case home
    case lock
    case siri
    case side
}

enum SimulatorTouchPhase: String, Equatable, Sendable {
    case began
    case moved
    case ended
    case cancelled
}

enum SimulatorKeyPhase: String, Equatable, Sendable {
    case down
    case up
    case press
}

/// One finger, or a pinch's two, in fractions (0–1) of the displayed screen.
struct SimulatorTouch: Equatable, Sendable {
    var phase: SimulatorTouchPhase
    var x: Double
    var y: Double
    var x2: Double?
    var y2: Double?

    /// Clamps every coordinate to the screen; a non-finite one becomes its center.
    init(phase: SimulatorTouchPhase, x: Double, y: Double, x2: Double? = nil, y2: Double? = nil) {
        self.phase = phase
        self.x = Self.unit(x)
        self.y = Self.unit(y)
        self.x2 = x2.map(Self.unit)
        self.y2 = y2.map(Self.unit)
    }

    init(phase: SimulatorTouchPhase, at point: CGPoint, second: CGPoint? = nil) {
        self.init(phase: phase, x: Double(point.x), y: Double(point.y),
                  x2: second.map { Double($0.x) }, y2: second.map { Double($0.y) })
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }
}

/// Everything this app may send on a viewer socket. `boot` and `focus` are
/// absent on purpose: the relay drops them, and either would take shared
/// focus from whoever is driving the simulator.
enum SimulatorClientMessage: Equatable, Sendable {
    /// Attaches (or re-attaches) the stream. Always watches without claiming focus.
    case hello(codec: SimulatorStreamCodec, quality: SimulatorStreamQuality)
    case quality(SimulatorStreamQuality)
    case keyframe
    /// `t` is echoed back in `pong`; a local monotonic millisecond clock.
    case ping(t: Double)
    case touch(SimulatorTouch)
    /// `usage` is a USB HID keyboard usage (page 0x07).
    case key(usage: Int, phase: SimulatorKeyPhase)
    case button(SimulatorHardwareButton)
    case text(String)
    /// Writes the simulator's pasteboard, then presses ⌘V there.
    case paste(String)

    /// The text frame to send.
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Every case holds plain strings and clamped, finite numbers.
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The companion relay drops longer `text` and `paste` messages; counted
    /// in Unicode scalars, as its Python `len()` counts them.
    static let maximumTextLength = 64 * 1024

    /// Whether the relay will pass this on (it drops empty or overlong text).
    var isWithinRelayLimits: Bool {
        switch self {
        case .text(let text), .paste(let text):
            !text.isEmpty && text.unicodeScalars.count <= Self.maximumTextLength
        case .hello, .quality, .keyframe, .ping, .touch, .key, .button:
            true
        }
    }

    /// Input that acts on the simulator, as opposed to stream control.
    var isInput: Bool {
        switch self {
        case .touch, .key, .button, .text, .paste: true
        case .hello, .quality, .keyframe, .ping: false
        }
    }
}

extension SimulatorClientMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, codec, quality, observe, focus, t, phase, x, y, x2, y2, usage, button, text
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let codec, let quality):
            try container.encode("hello", forKey: .type)
            try container.encode(codec.rawValue, forKey: .codec)
            try container.encode(quality.rawValue, forKey: .quality)
            try container.encode(true, forKey: .observe)
            try container.encode(false, forKey: .focus)
        case .quality(let quality):
            try container.encode("quality", forKey: .type)
            try container.encode(quality.rawValue, forKey: .quality)
        case .keyframe:
            try container.encode("keyframe", forKey: .type)
        case .ping(let t):
            try container.encode("ping", forKey: .type)
            try container.encode(t, forKey: .t)
        case .touch(let touch):
            try container.encode("touch", forKey: .type)
            try container.encode(touch.phase.rawValue, forKey: .phase)
            try container.encode(touch.x, forKey: .x)
            try container.encode(touch.y, forKey: .y)
            if let x2 = touch.x2, let y2 = touch.y2 {
                try container.encode(x2, forKey: .x2)
                try container.encode(y2, forKey: .y2)
            }
        case .key(let usage, let phase):
            try container.encode("key", forKey: .type)
            try container.encode(usage, forKey: .usage)
            try container.encode(phase.rawValue, forKey: .phase)
        case .button(let button):
            try container.encode("button", forKey: .type)
            try container.encode(button.rawValue, forKey: .button)
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .paste(let text):
            try container.encode("paste", forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }
}

// MARK: - Server text messages

/// SimPortal's inventory projection of the simulator. Advisory only, so each
/// field decodes on its own and a surprising one is dropped, not fatal.
struct SimulatorDeviceSummary: Equatable, Sendable {
    struct Screen: Equatable, Sendable {
        var width: Double?
        var height: Double?
        var scale: Double?
        var pointWidth: Double?
        var pointHeight: Double?
        /// Points, from the device type's capabilities.
        var cornerRadius: Double?
        var homeButton: Bool?
    }

    var udid: String?
    var name: String?
    var state: String?
    var family: String?
    var screen: Screen?

    /// The screen's corner radius as a fraction of its displayed width, for a
    /// caller that rounds the stream like the device.
    var cornerRadiusFraction: Double? {
        guard let radius = screen?.cornerRadius, let width = screen?.pointWidth, width > 0, radius >= 0 else { return nil }
        return radius / width
    }
}

extension SimulatorDeviceSummary: Decodable {
    private enum CodingKeys: String, CodingKey { case udid, name, state, family, screen }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        udid = try? container.decodeIfPresent(String.self, forKey: .udid)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        state = try? container.decodeIfPresent(String.self, forKey: .state)
        family = try? container.decodeIfPresent(String.self, forKey: .family)
        screen = try? container.decodeIfPresent(Screen.self, forKey: .screen)
    }
}

extension SimulatorDeviceSummary.Screen: Decodable {
    private enum CodingKeys: String, CodingKey { case width, height, scale, pointWidth, pointHeight, cornerRadius, homeButton }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try? container.decodeIfPresent(Double.self, forKey: .width)
        height = try? container.decodeIfPresent(Double.self, forKey: .height)
        scale = try? container.decodeIfPresent(Double.self, forKey: .scale)
        pointWidth = try? container.decodeIfPresent(Double.self, forKey: .pointWidth)
        pointHeight = try? container.decodeIfPresent(Double.self, forKey: .pointHeight)
        cornerRadius = try? container.decodeIfPresent(Double.self, forKey: .cornerRadius)
        homeButton = try? container.decodeIfPresent(Bool.self, forKey: .homeButton)
    }
}

/// An API action someone's agent took on the simulator. Typed-text snippets
/// are deliberately not decoded: they are private app data.
struct SimulatorAgentAction: Equatable, Sendable {
    var source: String?
    var action: String?
    /// Where it acted, in fractions of the screen, when the action has a point.
    var point: CGPoint?
}

enum SimulatorServerMessage: Equatable, Sendable {
    case device(SimulatorDeviceSummary)
    /// The helper attached; not yet a decoded frame.
    case ready(width: Int, height: Int, codec: SimulatorStreamCodec?)
    /// The simulator is not booted (e.g. `Booting`, `Shutdown`); the stream waits.
    case state(String)
    case surface(width: Int, height: Int)
    case viewers(count: Int)
    case pong(t: Double)
    case activity(SimulatorAgentAction)
    case notice(level: String, message: String)
    case error(message: String)
    /// The helper ended; the socket stays open and re-attaches when it can.
    case ended(reason: String)

    /// Parses one text frame: `nil` for anything that is not JSON, not an
    /// object, of an unknown type, or missing what its type needs.
    init?(text: String) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)) else { return nil }
        switch envelope.type {
        case "device":
            guard let device = envelope.device else { return nil }
            self = .device(device)
        case "ready":
            guard let width = Self.dimension(envelope.width), let height = Self.dimension(envelope.height) else { return nil }
            self = .ready(width: width, height: height, codec: envelope.codec.flatMap(SimulatorStreamCodec.init(rawValue:)))
        case "state":
            self = .state(envelope.state ?? "Unknown")
        case "surface":
            guard let width = Self.dimension(envelope.width), let height = Self.dimension(envelope.height) else { return nil }
            self = .surface(width: width, height: height)
        case "viewers":
            guard let count = envelope.count, count.isFinite, count >= 0, count < 1_000_000 else { return nil }
            self = .viewers(count: Int(count))
        case "pong":
            guard let t = envelope.t, t.isFinite else { return nil }
            self = .pong(t: t)
        case "activity":
            var point: CGPoint?
            if let x = envelope.x, let y = envelope.y, x.isFinite, y.isFinite {
                point = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
            }
            self = .activity(SimulatorAgentAction(source: envelope.source, action: envelope.action, point: point))
        case "notice":
            guard let message = envelope.message else { return nil }
            self = .notice(level: envelope.level ?? "info", message: message)
        case "error":
            self = .error(message: envelope.message ?? "The simulator stream reported an error.")
        case "ended":
            self = .ended(reason: envelope.reason ?? "")
        default:
            return nil
        }
    }

    private static func dimension(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value >= 1, value <= 65_535 else { return nil }
        return Int(value)
    }

    /// Every field any message type uses, each decoded leniently.
    private struct Envelope: Decodable {
        var type: String
        var device: SimulatorDeviceSummary?
        var width: Double?
        var height: Double?
        var codec: String?
        var state: String?
        var count: Double?
        var t: Double?
        var source: String?
        var action: String?
        var x: Double?
        var y: Double?
        var level: String?
        var message: String?
        var reason: String?

        private enum CodingKeys: String, CodingKey {
            case type, device, width, height, codec, state, count, t, source, action, x, y, level, message, reason
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            device = try? container.decodeIfPresent(SimulatorDeviceSummary.self, forKey: .device)
            width = try? container.decodeIfPresent(Double.self, forKey: .width)
            height = try? container.decodeIfPresent(Double.self, forKey: .height)
            codec = try? container.decodeIfPresent(String.self, forKey: .codec)
            state = try? container.decodeIfPresent(String.self, forKey: .state)
            count = try? container.decodeIfPresent(Double.self, forKey: .count)
            t = try? container.decodeIfPresent(Double.self, forKey: .t)
            source = try? container.decodeIfPresent(String.self, forKey: .source)
            action = try? container.decodeIfPresent(String.self, forKey: .action)
            x = try? container.decodeIfPresent(Double.self, forKey: .x)
            y = try? container.decodeIfPresent(Double.self, forKey: .y)
            level = try? container.decodeIfPresent(String.self, forKey: .level)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        }
    }
}

// MARK: - Server binary messages

/// `0x02`: how to configure the H.264 decoder.
struct SimulatorH264Config: Equatable, Sendable {
    /// e.g. `avc1.640c33`.
    var codec: String
    var width: Int
    var height: Int
    /// The `avcC` decoder configuration record.
    var avcC: Data

    /// Bytes in each NAL unit's length prefix (`lengthSizeMinusOne + 1`).
    var nalLengthSize: Int { avcC.count > 4 ? Int(avcC[avcC.startIndex + 4] & 0x03) + 1 : 4 }
}

/// `0x03`: one access unit as AVCC length-prefixed NAL units (not Annex B).
struct SimulatorH264Frame: Equatable, Sendable {
    var isKeyframe: Bool
    /// Media time in microseconds, not wall-clock time.
    var timestampUs: UInt64
    var data: Data

    /// Walks the length prefixes so a corrupt frame never reaches the decoder.
    func isWellFormed(nalLengthSize: Int) -> Bool {
        guard (1...4).contains(nalLengthSize), !data.isEmpty else { return false }
        var offset = data.startIndex
        while offset < data.endIndex {
            guard data.endIndex - offset >= nalLengthSize else { return false }
            var length = 0
            for index in offset..<(offset + nalLengthSize) { length = length << 8 | Int(data[index]) }
            offset += nalLengthSize
            guard length > 0, data.endIndex - offset >= length else { return false }
            offset += length
        }
        return true
    }
}

/// `0x04`: one JPEG frame.
struct SimulatorJPEGFrame: Equatable, Sendable {
    var timestampUs: UInt64
    var width: Int
    var height: Int
    var data: Data
}

enum SimulatorProtocolError: Error, Equatable, Sendable {
    case empty
    case oversized(Int)
    case truncated(type: UInt8)
    case malformed(String)
}

enum SimulatorBinaryMessage: Equatable, Sendable {
    case h264Config(SimulatorH264Config)
    case h264Frame(SimulatorH264Frame)
    case jpeg(SimulatorJPEGFrame)

    /// Larger than any keyframe SimPortal sends; the socket's own limit matches.
    static let maximumSize = 32 * 1024 * 1024
    /// Codec strings are short ASCII like `avc1.640c33`.
    static let maximumCodecLength = 64

    /// Parses one binary WebSocket message. Returns `nil` for type bytes this
    /// viewer ignores and throws for anything truncated, oversized or malformed.
    /// Every length is checked before it is read.
    static func parse(_ data: Data) throws(SimulatorProtocolError) -> SimulatorBinaryMessage? {
        guard !data.isEmpty else { throw .empty }
        guard data.count <= maximumSize else { throw .oversized(data.count) }
        let bytes = ByteReader(data: data)
        let type = bytes.u8(0)
        switch type {
        case 0x02:
            guard let codecLength = bytes.u16(1) else { throw .truncated(type: type) }
            guard (1...maximumCodecLength).contains(codecLength) else { throw .malformed("codec length \(codecLength)") }
            guard let codecBytes = bytes.slice(3, count: codecLength),
                  let width = bytes.u16(3 + codecLength),
                  let height = bytes.u16(5 + codecLength),
                  let avcC = bytes.slice(7 + codecLength) else { throw .truncated(type: type) }
            guard codecBytes.allSatisfy({ (0x21...0x7E).contains($0) }) else { throw .malformed("codec is not ASCII") }
            guard width > 0, height > 0 else { throw .malformed("empty frame size") }
            // configurationVersion 1, profile, compatibility, level, NAL length size.
            guard avcC.count >= 7, avcC[avcC.startIndex] == 1 else { throw .malformed("avcC record") }
            let codec = String(decoding: codecBytes, as: UTF8.self)
            return .h264Config(SimulatorH264Config(codec: codec, width: width, height: height, avcC: avcC))
        case 0x03:
            guard let flags = bytes.optionalU8(1), let timestamp = bytes.u64(2), let payload = bytes.slice(10) else {
                throw .truncated(type: type)
            }
            guard !payload.isEmpty else { throw .truncated(type: type) }
            return .h264Frame(SimulatorH264Frame(isKeyframe: flags & 1 == 1, timestampUs: timestamp, data: payload))
        case 0x04:
            guard let timestamp = bytes.u64(1), let width = bytes.u16(9), let height = bytes.u16(11),
                  let payload = bytes.slice(13) else { throw .truncated(type: type) }
            guard width > 0, height > 0 else { throw .malformed("empty frame size") }
            // Every JPEG starts with the SOI marker.
            guard payload.count >= 2, payload[payload.startIndex] == 0xFF, payload[payload.startIndex + 1] == 0xD8 else {
                throw .malformed("not a JPEG")
            }
            return .jpeg(SimulatorJPEGFrame(timestampUs: timestamp, width: width, height: height, data: payload))
        default:
            return nil
        }
    }

    /// Big-endian reads at offsets from the message start; `nil` past the end.
    private struct ByteReader {
        let data: Data

        func u8(_ offset: Int) -> UInt8 { data[data.startIndex + offset] }

        func optionalU8(_ offset: Int) -> UInt8? {
            offset >= 0 && offset < data.count ? data[data.startIndex + offset] : nil
        }

        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, data.count - offset >= 2 else { return nil }
            let start = data.startIndex + offset
            return Int(data[start]) << 8 | Int(data[start + 1])
        }

        func u64(_ offset: Int) -> UInt64? {
            guard offset >= 0, data.count - offset >= 8 else { return nil }
            let start = data.startIndex + offset
            return data[start..<(start + 8)].reduce(0) { $0 << 8 | UInt64($1) }
        }

        /// `count` bytes from `offset`, or everything after it; always re-based to index 0.
        func slice(_ offset: Int, count: Int? = nil) -> Data? {
            guard offset >= 0, offset <= data.count else { return nil }
            let available = data.count - offset
            let length = count ?? available
            guard length >= 0, length <= available else { return nil }
            let start = data.startIndex + offset
            return Data(data[start..<(start + length)])
        }
    }
}
