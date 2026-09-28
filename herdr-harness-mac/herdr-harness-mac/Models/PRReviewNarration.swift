import CryptoKit
import Foundation

struct PRReviewGuideTarget: Codable, Equatable, Hashable, Sendable {
    var path: String
    var side: PRReviewSide
    var startLine: Int
    var endLine: Int
}

struct PRReviewGuideDrawing: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var shape: String
    var targets: [PRReviewGuideTarget]
    var onPhrase: String
    var occurrence: Int? = nil
    var drawSeconds: Double? = nil
    var untilPhrase: String? = nil
    var untilOccurrence: Int? = nil
    var label: String? = nil
}

struct PRReviewTimedCue: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var shape: String
    var targets: [PRReviewGuideTarget]
    var onset: Double
    var drawSeconds: Double
    var until: Double? = nil
    var label: String? = nil

    func progress(at time: Double, reducedMotion: Bool = false) -> Double? {
        guard time.isFinite, time >= onset, until.map({ time < $0 }) ?? true else { return nil }
        return reducedMotion ? 1 : min(1, max(0, (time - onset) / drawSeconds))
    }
}

struct PRReviewNarrationWord: Codable, Equatable, Sendable {
    var word: String
    var start: Double
    var end: Double
}

struct PRReviewNarrationCapabilities: Decodable, Sendable {
    var available: Bool
    var voices: [String]
    var defaultVoice: String
    var reason: String?
    enum CodingKeys: String, CodingKey {
        case available, voices, reason
        case defaultVoice = "default_voice"
    }
}

struct PRReviewNarrationManifest: Codable, Equatable, Sendable {
    var available: Bool
    var script: String
    var voice: String
    var audioBase64: String? = nil
    var contentType: String? = nil
    var scriptSHA256: String? = nil
    var audioSHA256: String? = nil
    var duration: Double? = nil
    var words: [PRReviewNarrationWord] = []
    var cues: [PRReviewTimedCue] = []
    var reason: String? = nil
    var rejectedCues: [String]? = nil
    enum CodingKeys: String, CodingKey {
        case available, script, voice, duration, words, cues, reason
        case audioBase64 = "audio_base64", contentType = "content_type"
        case scriptSHA256 = "script_sha256", audioSHA256 = "audio_sha256", rejectedCues = "rejected_cues"
    }

    func validatedAudio(expectedScript: String, expectedVoice: String) throws -> Data {
        guard available else { throw PRReviewNarrationError.unavailable(reason) }
        guard script == expectedScript, voice == expectedVoice,
              scriptSHA256 == Self.sha256(Data(script.utf8)),
              let audioBase64, let data = Data(base64Encoded: audioBase64), !data.isEmpty,
              audioSHA256 == Self.sha256(data), contentType == "audio/wav",
              let duration, duration.isFinite, duration > 0, duration <= 240,
              !words.isEmpty else { throw PRReviewNarrationError.invalidRecording }
        var previous = 0.0
        for word in words {
            guard !word.word.isEmpty, word.start.isFinite, word.end.isFinite,
                  word.start >= previous, word.end >= word.start, word.end <= duration else {
                throw PRReviewNarrationError.invalidRecording
            }
            previous = word.start
        }
        var cueIDs = Set<String>()
        for cue in cues {
            guard !cue.id.isEmpty, cueIDs.insert(cue.id).inserted,
                  ["circle", "underline", "arrow", "highlight"].contains(cue.shape),
                  cue.targets.count == (cue.shape == "arrow" ? 2 : 1),
                  Set(cue.targets.map(\.path)).count == 1,
                  cue.onset.isFinite, cue.drawSeconds.isFinite, cue.onset >= 0, cue.drawSeconds > 0,
                  cue.onset + cue.drawSeconds <= duration + 0.00001,
                  cue.until.map({ $0.isFinite && $0 >= cue.onset + cue.drawSeconds && $0 <= duration }) ?? true,
                  cue.targets.allSatisfy({
                      !$0.path.isEmpty && !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..")
                      && !$0.path.contains("\\") && $0.startLine > 0 && $0.endLine >= $0.startLine
                  }) else { throw PRReviewNarrationError.invalidRecording }
        }
        return data
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum PRReviewNarrationError: LocalizedError {
    case unavailable(String?)
    case invalidRecording
    var errorDescription: String? {
        switch self {
        case let .unavailable(reason): reason ?? "Narration is unavailable. You can keep reading the walkthrough."
        case .invalidRecording: "The recording and its drawing timings could not be verified. You can keep reading."
        }
    }
}
