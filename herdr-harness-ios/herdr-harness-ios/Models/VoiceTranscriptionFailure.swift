import Foundation

/// Contains only app-owned labels and allowlisted codes. Never retain an error's
/// description, userInfo, URL, response body, recording, or transcript here.
struct VoiceTranscriptionFailure: LocalizedError, Equatable, Sendable {
    enum Stage: String, Sendable {
        case recording = "Private transcription / recording validation"
        case request = "Private transcription / upload and server request"
        case response = "Private transcription / response decoding"
        case applePermission = "Apple Speech / permission"
        case appleDevice = "Apple Speech / device support"
        case appleLocale = "Apple Speech / language support"
        case appleAssets = "Apple Speech / model download"
        case appleAudio = "Apple Speech / reading recording"
        case appleRecognition = "Apple Speech / recognition"
    }

    struct Issue: Equatable, Sendable {
        let stage: Stage
        let reason: String
    }

    let issues: [Issue]
    let date: Date
    let reference: UUID

    init(issues: [Issue], date: Date = .now, reference: UUID = UUID()) {
        self.issues = issues
        self.date = date
        self.reference = reference
    }

    static func wrapping(_ error: any Error, stage: Stage) throws -> Self {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        }
        if let failure = error as? Self { return failure }
        return Self(issues: [.init(stage: stage, reason: reason(for: error))])
    }

    static func combined(privateError: any Error, appleError: any Error) throws -> Self {
        let first = try wrapping(privateError, stage: .request)
        let second = try wrapping(appleError, stage: .appleRecognition)
        return Self(issues: first.issues + second.issues)
    }

    var errorDescription: String? {
        issues.map { "\($0.stage.rawValue): \($0.reason)" }.joined(separator: "\n")
    }

    var report: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return """
        Herdr transcription diagnostics
        App: \(version) (\(build))
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Time: \(date.ISO8601Format())
        Reference: \(reference.uuidString)

        \(errorDescription ?? "Transcription failed.")

        No audio, transcript, server address, or credentials are included.
        """
    }

    private static func reason(for error: any Error) -> String {
        if let voice = error as? VoiceTranscriptionError {
            switch voice {
            case .invalidRecording: return "The recording failed WAV validation. Expected nonempty mono 16 kHz, 16-bit PCM audio."
            case .recordingTooLarge: return "The recording exceeds the 20 MB limit."
            case .speechPermissionDenied: return "Speech Recognition permission is denied or restricted. Check Settings > Privacy & Security > Speech Recognition."
            case .deviceUnavailable: return "This device does not support the Apple SpeechTranscriber engine used by this build."
            case .localeUnavailable: return "The Apple engine does not support the requested language."
            case .emptyTranscript: return "Recognition returned no speech."
            }
        }
        if let api = error as? APIError {
            switch api {
            case .server(let status, let message):
                let knownCodes: [String: String] = [
                    "transcription_not_configured": "The companion has no transcription provider configured.",
                    "transcription_configuration_invalid": "The companion's transcription configuration is invalid.",
                    "transcription_provider_error": "The speech provider rejected the companion's request.",
                    "transcription_timeout": "The companion timed out waiting for the speech provider.",
                    "transcription_unavailable": "The companion could not reach the speech provider.",
                    "transcription_invalid_response": "The speech provider returned an invalid or empty transcript.",
                    "transcription_response_too_large": "The speech provider's response exceeded the size limit.",
                    "invalid_voice_recording": "The companion rejected the recording format.",
                    "unauthorized": "The companion rejected authentication.",
                    "forbidden": "The companion refused access.",
                    "not_found": "The companion does not provide the transcription endpoint.",
                    "payload_too_large": "The companion rejected the upload size.",
                ]
                if let code = message.code, let explanation = knownCodes[code] {
                    return "HTTP \(status), \(code). \(explanation)"
                }
                return "HTTP \(status). \(httpReason(status))"
            case .noActiveConnection: return "The conversation's companion connection is unavailable."
            case .invalidResponse: return "The companion response or conversation context was invalid."
            case .streamEnded: return "The companion connection ended."
            case .streamBacklogOverflow: return "The companion connection is resynchronizing."
            }
        }
        if let url = error as? URLError {
            let explanation: String
            switch url.code {
            case .timedOut: explanation = "The request timed out."
            case .notConnectedToInternet: explanation = "The device has no network connection."
            case .cannotFindHost, .dnsLookupFailed: explanation = "The companion address could not be resolved. Check the private network connection."
            case .cannotConnectToHost: explanation = "The device could not connect to the companion."
            case .networkConnectionLost: explanation = "The connection dropped during the request."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                explanation = "The secure connection or server certificate could not be verified."
            case .userAuthenticationRequired: explanation = "Authentication is required."
            default: explanation = "The network request failed."
            }
            return "NSURLErrorDomain \(url.code.rawValue). \(explanation)"
        }
        if let decoding = error as? DecodingError {
            let kind: String
            switch decoding {
            case .keyNotFound: kind = "missing field"
            case .typeMismatch: kind = "incorrect field type"
            case .valueNotFound: kind = "missing value"
            case .dataCorrupted: kind = "invalid JSON or data"
            @unknown default: kind = "unknown decoding failure"
            }
            return "The response could not be decoded (\(kind))."
        }
        let nsError = error as NSError
        let knownDomains: Set<String> = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
            "SFSpeechErrorDomain", "kAFAssistantErrorDomain", "kLSRErrorDomain", "SpeechErrorDomain",
            "com.apple.speech", "com.apple.Speech", "com.apple.MobileAssetError.Download", "AVFoundationErrorDomain"]
        let domain = knownDomains.contains(nsError.domain) ? nsError.domain : "Unrecognized error domain"
        return "\(domain), code \(nsError.code)."
    }

    private static func httpReason(_ status: Int) -> String {
        switch status {
        case 401, 403: return "The companion rejected authentication or access."
        case 404, 405, 501: return "The companion does not support this transcription request."
        case 413: return "The upload exceeded the server's size limit."
        case 429: return "The service is temporarily rate limited."
        case 500...599: return "The companion or its speech provider failed."
        default: return "The companion rejected the request."
        }
    }
}
