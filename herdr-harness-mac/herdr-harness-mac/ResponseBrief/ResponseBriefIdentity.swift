import CryptoKit
import Foundation

/// Identity evidence copied only from data the reducer actually projected:
/// completed-message and user-message timestamps plus exact content hashes.
///
/// The source builder never invents a timestamp from wall-clock time, so two
/// independent projections of one answer can only agree when both observed the
/// same real message data. Matching also requires timestamp agreement, which
/// keeps identical text from being treated as identity on its own.
struct ResponseBriefIdentityEvidence: Codable, Equatable, Hashable, Sendable {
    let responseTextHash: String
    let responseTimestamp: Date?
    let userTextHash: String?
    let userTimestamp: Date?

    init(
        responseText: String,
        responseTimestamp: Date?,
        userText: String?,
        userTimestamp: Date?
    ) {
        responseTextHash = Self.hash(responseText)
        self.responseTimestamp = responseTimestamp
        userTextHash = userText.map(Self.hash)
        self.userTimestamp = userTimestamp
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Narrow identity equivalence for one completed answer across live and
/// persisted projections.
enum ResponseBriefIdentity {
    enum Match: Equatable, Sendable {
        case exactIdentifier
        case verifiedContinuation
    }

    /// Equates two projections of one completed answer. Distinct answers that
    /// merely share text, labels, ordering, or a chat never match.
    static func match(_ lhs: ResponseBriefSource, _ rhs: ResponseBriefSource) -> Match? {
        guard lhs.chat == rhs.chat else { return nil }
        if lhs.responseID == rhs.responseID { return .exactIdentifier }
        guard let left = lhs.identity, let right = rhs.identity else { return nil }
        return verifiesContinuity(left, right) ? .verifiedContinuation : nil
    }

    /// Default presentation equivalence for a comparison that has no durable
    /// alias state: exact identifiers or verified identity evidence. The
    /// coordinator's `areEquivalent` adds previously verified aliases and is
    /// the authority used by the rail whenever it is available.
    static func equivalentByVerifiedIdentity(
        _ lhs: ResponseBriefSource,
        _ rhs: ResponseBriefSource
    ) -> Bool {
        match(lhs, rhs) != nil
    }

    /// Verified continuity needs the exact content hash plus both real
    /// completed-message timestamps, corroborated by the user turn. Content-only
    /// agreement, missing timestamps, or conflicting evidence is rejected.
    static func verifiesContinuity(
        _ lhs: ResponseBriefIdentityEvidence,
        _ rhs: ResponseBriefIdentityEvidence
    ) -> Bool {
        guard lhs.responseTextHash == rhs.responseTextHash else { return false }
        guard let leftTimestamp = lhs.responseTimestamp,
              let rightTimestamp = rhs.responseTimestamp,
              leftTimestamp == rightTimestamp
        else { return false }

        if let leftUserTimestamp = lhs.userTimestamp,
           let rightUserTimestamp = rhs.userTimestamp,
           leftUserTimestamp != rightUserTimestamp {
            return false
        }
        if let leftUserHash = lhs.userTextHash,
           let rightUserHash = rhs.userTextHash,
           leftUserHash != rightUserHash {
            return false
        }
        return (lhs.userTimestamp != nil && lhs.userTimestamp == rhs.userTimestamp)
            || (lhs.userTextHash != nil && lhs.userTextHash == rhs.userTextHash)
    }

    /// Exactly one candidate may claim a recorded baseline anchor. Zero matches,
    /// several ambiguous matches, or content-only agreement return nil instead
    /// of a guess that could reconcile the wrong answer.
    static func uniqueVerifiedCandidate(
        responseID: String,
        identity: ResponseBriefIdentityEvidence,
        among candidates: [ResponseBriefSource]
    ) -> ResponseBriefSource? {
        var verified: [ResponseBriefSource] = []
        for candidate in candidates {
            if candidate.responseID == responseID { return candidate }
            guard let candidateIdentity = candidate.identity else { continue }
            if verifiesContinuity(identity, candidateIdentity) {
                verified.append(candidate)
            }
        }
        return verified.count == 1 ? verified[0] : nil
    }
}
