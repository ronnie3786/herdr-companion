import CoreGraphics
import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("Simulator viewer protocol")
struct SimulatorViewerProtocolTests {
    // MARK: Binary

    @Test("H.264 configuration parses codec, size and avcC at SimPortal's offsets")
    func parsesConfig() throws {
        let message = try SimulatorBinaryMessage.parse(SimulatorWire.config(width: 1206, height: 2622, avcC: SimulatorWire.avcC))
        let config = SimulatorH264Config(codec: "avc1.640c33", width: 1206, height: 2622, avcC: SimulatorWire.avcC)
        #expect(message == .h264Config(config))
        #expect(config.nalLengthSize == 4)
    }

    @Test("H.264 frames carry the keyframe bit, a 64-bit timestamp and AVCC bytes")
    func parsesFrame() throws {
        let timestamp: UInt64 = 0x0102_0304_0506_0708
        let key = try SimulatorBinaryMessage.parse(
            SimulatorWire.frame(keyframe: true, timestampUs: timestamp, data: SimulatorWire.accessUnit))
        #expect(key == .h264Frame(SimulatorH264Frame(isKeyframe: true, timestampUs: timestamp, data: SimulatorWire.accessUnit)))
        // Only bit 0 means keyframe.
        var delta = SimulatorWire.frame(keyframe: false, timestampUs: 7, data: SimulatorWire.accessUnit)
        delta[1] = 0xFE
        guard case .h264Frame(let frame)? = try SimulatorBinaryMessage.parse(delta) else {
            Issue.record("Expected a frame")
            return
        }
        #expect(!frame.isKeyframe)
        #expect(frame.timestampUs == 7)
        #expect(frame.isWellFormed(nalLengthSize: 4))
    }

    @Test("JPEG frames parse timestamp, size and image bytes")
    func parsesJPEG() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
        let message = try SimulatorBinaryMessage.parse(SimulatorWire.jpeg(timestampUs: 42, width: 603, height: 1311, data: jpeg))
        #expect(message == .jpeg(SimulatorJPEGFrame(timestampUs: 42, width: 603, height: 1311, data: jpeg)))
    }

    @Test("Parsed payloads are re-based copies, whatever slice they came from")
    func slicedInput() throws {
        let wire = Data([0xAA, 0xBB]) + SimulatorWire.config(width: 64, height: 128, avcC: SimulatorWire.avcC)
        let slice = wire.dropFirst(2)
        guard case .h264Config(let config)? = try SimulatorBinaryMessage.parse(slice) else {
            Issue.record("Expected a configuration")
            return
        }
        #expect(config.avcC.startIndex == 0)
        #expect(config.avcC == SimulatorWire.avcC)
        #expect(config.width == 64 && config.height == 128)
    }

    @Test("Other type bytes, including the helper's own 0x01 and 0x05, are ignored")
    func ignoresUnknownTypes() throws {
        for type: UInt8 in [0x00, 0x01, 0x05, 0x06, 0x7F, 0xFF] {
            #expect(try SimulatorBinaryMessage.parse(Data([type, 1, 2, 3])) == nil)
            #expect(try SimulatorBinaryMessage.parse(Data([type])) == nil)
        }
    }

    @Test("Truncated, oversized and malformed messages are rejected with a reason")
    func rejectsMalformed() {
        let config = SimulatorWire.config(width: 64, height: 128, avcC: SimulatorWire.avcC)
        let cases: [(Data, SimulatorProtocolError)] = [
            (Data(), .empty),
            (Data([0x02]), .truncated(type: 0x02)),
            (Data([0x02, 0x00]), .truncated(type: 0x02)),
            // Codec length runs past the end.
            (Data([0x02, 0x00, 0x20, 0x61]), .truncated(type: 0x02)),
            (Data([0x02, 0x00, 0x00]), .malformed("codec length 0")),
            (Data([0x02, 0xFF, 0xFF]), .malformed("codec length 65535")),
            (SimulatorWire.config(codec: "avc1\u{7}", width: 64, height: 128, avcC: SimulatorWire.avcC), .malformed("codec is not ASCII")),
            (SimulatorWire.config(width: 0, height: 128, avcC: SimulatorWire.avcC), .malformed("empty frame size")),
            (SimulatorWire.config(codec: "avc1.640c33", width: 64, height: 128, avcC: Data([0x01, 0x64])), .malformed("avcC record")),
            (SimulatorWire.config(codec: "avc1.640c33", width: 64, height: 128, avcC: Data([0x02] + SimulatorWire.avcC.dropFirst())),
             .malformed("avcC record")),
            (Data([0x03]), .truncated(type: 0x03)),
            (Data([0x03, 0x01, 0, 0, 0, 0, 0, 0, 0]), .truncated(type: 0x03)),
            (Data([0x03, 0x01, 0, 0, 0, 0, 0, 0, 0, 1]), .truncated(type: 0x03)),
            (Data([0x04, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0]), .truncated(type: 0x04)),
            (SimulatorWire.jpeg(timestampUs: 1, width: 0, height: 10, data: Data([0xFF, 0xD8])), .malformed("empty frame size")),
            (SimulatorWire.jpeg(timestampUs: 1, width: 10, height: 10, data: Data([0x89, 0x50, 0x4E, 0x47])), .malformed("not a JPEG")),
            (SimulatorWire.jpeg(timestampUs: 1, width: 10, height: 10, data: Data()), .malformed("not a JPEG")),
            (Data([0x03]) + Data(count: SimulatorBinaryMessage.maximumSize), .oversized(SimulatorBinaryMessage.maximumSize + 1)),
        ]
        for (data, expected) in cases {
            #expect(throws: expected, "\(data.prefix(16).map { String(format: "%02x", $0) })") {
                try SimulatorBinaryMessage.parse(data)
            }
        }
        #expect(throws: Never.self) { try SimulatorBinaryMessage.parse(config) }
    }

    @Test("Every prefix of a valid message parses or throws, and a cut header always throws")
    func truncationNeverCrashes() {
        // Message and the length of its fixed part (header, codec, minimal avcC or JPEG marker).
        let messages: [(Data, Int)] = [
            (SimulatorWire.config(width: 64, height: 128, avcC: SimulatorWire.avcC), 7 + 11 + 7),
            (SimulatorWire.frame(keyframe: true, timestampUs: 99, data: SimulatorWire.accessUnit), 11),
            (SimulatorWire.jpeg(timestampUs: 5, width: 3, height: 4, data: Data([0xFF, 0xD8, 0x00])), 15),
        ]
        for (message, fixedLength) in messages {
            for length in 0..<message.count {
                let result = Result { try SimulatorBinaryMessage.parse(message.prefix(length)) }
                if length < fixedLength, case .success(let parsed) = result {
                    Issue.record("A \(length)-byte prefix parsed as \(String(describing: parsed))")
                }
            }
        }
    }

    @Test("A frame's NAL length prefixes must add up exactly")
    func frameWellFormedness() {
        let frame = { (bytes: [UInt8]) in SimulatorH264Frame(isKeyframe: true, timestampUs: 0, data: Data(bytes)) }
        #expect(frame([0, 0, 0, 1, 0x65]).isWellFormed(nalLengthSize: 4))
        #expect(frame([0, 1, 0x65, 0, 2, 0x41, 0x9A]).isWellFormed(nalLengthSize: 2))
        #expect(!frame([0, 0, 0, 5, 0x65]).isWellFormed(nalLengthSize: 4))
        #expect(!frame([0, 0, 0, 0]).isWellFormed(nalLengthSize: 4))
        #expect(!frame([0, 0, 0, 1, 0x65, 0x00]).isWellFormed(nalLengthSize: 4))
        #expect(!frame([]).isWellFormed(nalLengthSize: 4))
        #expect(!frame([0, 0, 0, 1, 0x65]).isWellFormed(nalLengthSize: 0))
    }

    // MARK: Server text

    @Test("Each server text message decodes")
    func serverMessages() {
        let device = """
        {"type":"device","device":{"udid":"00000000-0000-0000-0000-000000000001","name":"Example Phone","state":"Booted",
         "family":"iphone","screen":{"width":1206,"height":2622,"scale":3,"pointWidth":402,"pointHeight":874,
         "cornerRadius":55,"homeButton":false},"links":{"local":"http://127.0.0.1:1/d/example"}}}
        """
        guard case .device(let summary)? = SimulatorServerMessage(text: device) else {
            Issue.record("Expected a device")
            return
        }
        #expect(summary.name == "Example Phone")
        #expect(summary.state == "Booted")
        #expect(summary.screen?.pointWidth == 402)
        #expect(summary.cornerRadiusFraction == 55.0 / 402.0)

        #expect(SimulatorServerMessage(text: #"{"type":"ready","width":603,"height":1311,"codec":"h264"}"#)
                == .ready(width: 603, height: 1311, codec: .h264))
        #expect(SimulatorServerMessage(text: #"{"type":"ready","width":603,"height":1311,"codec":"vp9"}"#)
                == .ready(width: 603, height: 1311, codec: nil))
        #expect(SimulatorServerMessage(text: #"{"type":"state","state":"Booting"}"#) == .state("Booting"))
        #expect(SimulatorServerMessage(text: #"{"type":"state"}"#) == .state("Unknown"))
        #expect(SimulatorServerMessage(text: #"{"type":"surface","width":1311,"height":603}"#) == .surface(width: 1311, height: 603))
        #expect(SimulatorServerMessage(text: #"{"type":"viewers","count":3}"#) == .viewers(count: 3))
        #expect(SimulatorServerMessage(text: #"{"type":"pong","t":1234.5}"#) == .pong(t: 1234.5))
        #expect(SimulatorServerMessage(text: #"{"type":"notice","level":"error","message":"Could not start the stream"}"#)
                == .notice(level: "error", message: "Could not start the stream"))
        #expect(SimulatorServerMessage(text: #"{"type":"error","message":"No simulator matches","candidates":[]}"#)
                == .error(message: "No simulator matches"))
        #expect(SimulatorServerMessage(text: #"{"type":"ended","reason":"simulator shut down"}"#) == .ended(reason: "simulator shut down"))
    }

    @Test("Agent activity keeps the action and point but never typed text")
    func activity() {
        let tap = SimulatorServerMessage(text: #"{"type":"activity","source":"agent","action":"tap","x":0.25,"y":1.5}"#)
        #expect(tap == .activity(SimulatorAgentAction(source: "agent", action: "tap", point: CGPoint(x: 0.25, y: 1))))
        let typed = SimulatorServerMessage(text: #"{"type":"activity","source":"agent","action":"type","text":"hunter2"}"#)
        #expect(typed == .activity(SimulatorAgentAction(source: "agent", action: "type", point: nil)))
        #expect(!String(describing: typed as Any).contains("hunter2"))
    }

    @Test("Unknown, malformed and incomplete text messages are ignored")
    func ignoresOtherText() {
        for text in [
            #"{"type":"welcome"}"#, #"{"kind":"ready"}"#, "not json", "[1,2]", #""ready""#, "",
            #"{"type":"ready","width":0,"height":10}"#, #"{"type":"ready","width":"wide","height":10}"#,
            #"{"type":"surface","width":70000,"height":10}"#, #"{"type":"viewers","count":-1}"#,
            #"{"type":"pong"}"#, #"{"type":"notice","level":"info"}"#, #"{"type":"device"}"#, #"{"type":7}"#,
        ] {
            #expect(SimulatorServerMessage(text: text) == nil, "\(text)")
        }
    }

    @Test("Surprising device fields drop on their own instead of dropping the message")
    func lenientDevice() {
        let text = #"{"type":"device","device":{"udid":"u-1","name":5,"state":"Shutdown","screen":{"pointWidth":"wide","cornerRadius":40}}}"#
        guard case .device(let device)? = SimulatorServerMessage(text: text) else {
            Issue.record("Expected a device")
            return
        }
        #expect(device.udid == "u-1")
        #expect(device.name == nil)
        #expect(device.state == "Shutdown")
        #expect(device.screen?.cornerRadius == 40)
        #expect(device.cornerRadiusFraction == nil)
    }

    // MARK: Client messages

    @Test("Every client message encodes SimPortal's exact keys and values")
    func clientEncoding() {
        let expected: [(SimulatorClientMessage, String)] = [
            (.hello(codec: .h264, quality: .high), #"{"codec":"h264","focus":false,"observe":true,"quality":"high","type":"hello"}"#),
            (.hello(codec: .jpeg, quality: .low), #"{"codec":"jpeg","focus":false,"observe":true,"quality":"low","type":"hello"}"#),
            (.quality(.balanced), #"{"quality":"balanced","type":"quality"}"#),
            (.keyframe, #"{"type":"keyframe"}"#),
            (.ping(t: 1234.5), #"{"t":1234.5,"type":"ping"}"#),
            (.touch(SimulatorTouch(phase: .began, x: 0.25, y: 0.75)), #"{"phase":"began","type":"touch","x":0.25,"y":0.75}"#),
            (.touch(SimulatorTouch(phase: .moved, x: 0.25, y: 0.75, x2: 0.75, y2: 0.25)),
             #"{"phase":"moved","type":"touch","x":0.25,"x2":0.75,"y":0.75,"y2":0.25}"#),
            (.touch(SimulatorTouch(phase: .ended, x: 0, y: 1)), #"{"phase":"ended","type":"touch","x":0,"y":1}"#),
            (.touch(SimulatorTouch(phase: .cancelled, x: 0.5, y: 0.5)), #"{"phase":"cancelled","type":"touch","x":0.5,"y":0.5}"#),
            (.key(usage: 0x04, phase: .down), #"{"phase":"down","type":"key","usage":4}"#),
            (.key(usage: 0xE3, phase: .up), #"{"phase":"up","type":"key","usage":227}"#),
            (.key(usage: 0x19, phase: .press), #"{"phase":"press","type":"key","usage":25}"#),
            (.button(.home), #"{"button":"home","type":"button"}"#),
            (.button(.side), #"{"button":"side","type":"button"}"#),
            (.text("hi"), #"{"text":"hi","type":"text"}"#),
            (.paste("https://example.invalid/a"), #"{"text":"https://example.invalid/a","type":"paste"}"#),
        ]
        for (message, json) in expected {
            #expect(message.json == json)
        }
        for button in SimulatorHardwareButton.allCases {
            #expect(SimulatorClientMessage.button(button).json.contains(#""button":"\#(button.rawValue)""#))
        }
    }

    @Test("Text survives JSON escaping intact")
    func textEscaping() throws {
        let text = "Line \"one\"\nline two\t✓ 🙂 \\ </script>"
        for message in [SimulatorClientMessage.text(text), .paste(text)] {
            let object = try SimulatorWire.jsonObject(message.json)
            #expect(object["text"] as? String == text)
        }
    }

    @Test("Touch coordinates clamp to the screen and never encode NaN")
    func touchClamping() {
        let touch = SimulatorTouch(phase: .moved, x: -0.5, y: 1.5, x2: .nan, y2: .infinity)
        #expect(touch.x == 0 && touch.y == 1)
        #expect(touch.x2 == 0.5 && touch.y2 == 0.5)
        #expect(SimulatorClientMessage.touch(touch).json == #"{"phase":"moved","type":"touch","x":0,"x2":0.5,"y":1,"y2":0.5}"#)
    }

    @Test("Text the relay would drop is recognized before sending")
    func relayLimits() {
        let limit = SimulatorClientMessage.maximumTextLength
        #expect(SimulatorClientMessage.paste(String(repeating: "a", count: limit)).isWithinRelayLimits)
        #expect(!SimulatorClientMessage.paste(String(repeating: "a", count: limit + 1)).isWithinRelayLimits)
        // Counted like Python's len(): one scalar per emoji here, not UTF-16 units or bytes.
        #expect(SimulatorClientMessage.text(String(repeating: "🙂", count: limit)).isWithinRelayLimits)
        #expect(!SimulatorClientMessage.text("").isWithinRelayLimits)
        #expect(SimulatorClientMessage.keyframe.isWithinRelayLimits)
        // The longest allowed text stays far below the relay's 1 MiB message cap, even fully escaped.
        #expect(SimulatorClientMessage.text(String(repeating: "\u{1}", count: limit)).json.utf8.count < 1024 * 1024)
    }

    @Test("Input messages are the ones that act on the simulator")
    func inputClassification() {
        #expect(SimulatorClientMessage.touch(SimulatorTouch(phase: .began, x: 0, y: 0)).isInput)
        #expect(SimulatorClientMessage.paste("x").isInput)
        #expect(!SimulatorClientMessage.hello(codec: .h264, quality: .high).isInput)
        #expect(!SimulatorClientMessage.ping(t: 0).isInput)
    }
}
