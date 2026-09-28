import AVFoundation
import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Review buddy delayed narration", .serialized)
struct PRReviewGuideDelayedNarrationTests {
    @Test("A late Kokoro response respects Ask and speech ownership interruptions", arguments: [false, true])
    func pendingAutoplayIsInterrupted(byOtherOwner: Bool) async throws {
        let configuration = try #require(ServerConfiguration(urlString: "https://guide.example.invalid", token: "synthetic-token"))
        let transportConfiguration = URLSessionConfiguration.ephemeral
        transportConfiguration.protocolClasses = [GuideDelayedAudioProtocol.self]
        let client = HerdrAPIClient(configuration: configuration, session: URLSession(configuration: transportConfiguration))
        let store = PRReviewStore()
        store.configure(client: client, machineID: "synthetic-delayed-host", demo: false)
        store.select(PRReviewDemo.reviewID)
        store.receive(PRReviewDemo.snapshot())
        store.capabilities = try JSONDecoder().decode(PRReviewCapabilities.self, from: Data("""
            {"ok":true,"available":true,"capabilities":["pr-review-v1","pr-review-guide-v1"],"skills":[]}
            """.utf8))
        let guide = PRReviewGuideSession(persistenceURL: nil)
        guide.configure(store: store)
        let engine = GuideSilentAudioEngine()
        guide.player.makePlayer = { _ in engine }
        guide.start()
        for _ in 0..<200 where guide.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(guide.plan != nil)
        guide.togglePlayback()
        for _ in 0..<200 where !GuideDelayedAudioProtocol.hasPending { try await Task.sleep(for: .milliseconds(5)) }
        #expect(GuideDelayedAudioProtocol.hasPending)
        let otherOwner = UUID()
        var otherOwnerWasInterrupted = false
        defer { HerdrSpeechOwnership.shared.release(otherOwner) }
        if byOtherOwner {
            HerdrSpeechOwnership.shared.claim(otherOwner) { otherOwnerWasInterrupted = true }
        } else { guide.beginQuestion() }
        GuideDelayedAudioProtocol.finishAudio()
        for _ in 0..<200 where guide.isLoadingAudio { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!guide.isLoadingAudio)
        #expect(guide.isAsking == !byOtherOwner)
        #expect(!otherOwnerWasInterrupted)
        #expect(!guide.isPlaying)
        #expect(engine.playCount == 0)
        guide.suspend()
    }
}

private final class GuideSilentAudioEngine: PRReviewAudioEngine {
    var delegate: (any AVAudioPlayerDelegate)?
    var currentTime = 0.0
    var duration = 1.0
    var enableRate = false
    var rate: Float = 1
    var playCount = 0
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { playCount += 1; return true }
    func pause() {}
    func stop() {}
}

private final class GuideDelayedAudioProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: GuideDelayedAudioProtocol?
    private var audioBody: [String: Any] = [:]
    static var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "guide.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let result: Data
        if url.path.hasSuffix("captioned-speech") {
            audioBody = (try? JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any]) ?? [:]
            Self.lock.lock(); Self.pending = self; Self.lock.unlock()
            return
        } else if url.path.hasSuffix("captioned-capabilities") {
            result = Data("{\"available\":true,\"voices\":[\"synthetic-voice\"],\"default_voice\":\"synthetic-voice\"}".utf8)
        } else {
            result = Data("""
            {"ok":true,"guide":{"id":"synthetic-guide","state":"finished","review_id":"prr_demo42","base_sha":"base","head_sha":"head","chapters":[{"id":"intent","title":"Start here","objective":"Inspect the change","display_text":"Inspect this change.","spoken_text":"Inspect this change.","segments":[{"id":"intent-1","spoken_text":"Inspect this change.","drawings":[],"source_refs":[]}],"suggested_questions":[]}],"sources":[],"coverage":{"limitations":[]}}}
            """.utf8)
        }
        finish(result)
    }
    override func stopLoading() {}
    static func finishAudio() {
        lock.lock(); let instance = pending; pending = nil; lock.unlock()
        guard let instance else { return }
        let script = instance.audioBody["text"] as? String ?? ""
        let voice = instance.audioBody["voice"] as? String ?? ""
        let audio = Data([1, 2, 3])
        let manifest = PRReviewNarrationManifest(available: true, script: script, voice: voice,
            audioBase64: audio.base64EncodedString(), contentType: "audio/wav",
            scriptSHA256: PRReviewNarrationManifest.sha256(Data(script.utf8)), audioSHA256: PRReviewNarrationManifest.sha256(audio),
            duration: 1, words: [.init(word: "Inspect", start: 0, end: 1)], cues: [])
        instance.finish(try! JSONEncoder().encode(manifest))
    }
    private func finish(_ data: Data) {
        guard let url = request.url else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
