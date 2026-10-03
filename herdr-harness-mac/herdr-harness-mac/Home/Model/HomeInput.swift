import Foundation

/// An immutable, credential-free capture of the authoritative stores. Building
/// or projecting this value never fetches detail, changes selection, or marks read.
struct HomeInput: Equatable, Sendable {
    let machines: [HomeMachineFact]
    let sources: [HomeSourceFact]
    let features: [HomeFeatureFact]
    let reviews: [HomeReviewFact]
    let reviewRequests: [HomeReviewRequestFact]
    let watchers: [HomeWatcherFact]
    let chats: [HomeChatFact]
    let currentRecap: [HomeRecapFact]
    let historicalRecap: [HomeRecapFact]
    let previousVisit: Date?
    let leadAvailable: Bool
    let coverageLine: String

    init(machines: [HomeMachineFact] = [], sources: [HomeSourceFact] = [],
         features: [HomeFeatureFact] = [], reviews: [HomeReviewFact] = [],
         reviewRequests: [HomeReviewRequestFact] = [], watchers: [HomeWatcherFact] = [],
         chats: [HomeChatFact] = [], currentRecap: [HomeRecapFact] = [],
         historicalRecap: [HomeRecapFact] = [], previousVisit: Date? = nil, leadAvailable: Bool = false,
         coverageLine: String = "") {
        self.machines = machines; self.sources = sources; self.features = features
        self.reviews = reviews; self.reviewRequests = reviewRequests; self.watchers = watchers
        self.chats = chats; self.currentRecap = currentRecap; self.historicalRecap = historicalRecap
        self.previousVisit = previousVisit; self.leadAvailable = leadAvailable; self.coverageLine = coverageLine
    }
}

struct HomeMachineFact: Equatable, Sendable {
    enum State: String, Sendable { case connecting, online, offline }
    let id: String
    let name: String
    let state: State
    /// An actual connection failure, rather than an unconfigured or never-connected machine.
    let needsAttention: Bool
    let notice: String?
    let failureBeganAt: Date?
    init(id: String, name: String, state: State, needsAttention: Bool = false, notice: String? = nil,
         failureBeganAt: Date? = nil) {
        self.id = id; self.name = name; self.state = state
        self.needsAttention = needsAttention; self.notice = notice; self.failureBeganAt = failureBeganAt
    }
}

struct HomeSourceFact: Equatable, Sendable {
    enum State: String, Sendable { case loading, current, stale, unavailable, unsupported }
    let id: String
    let state: State
    let updatedAt: Date?
    let notice: String?
    init(id: String, state: State, updatedAt: Date? = nil, notice: String? = nil) {
        self.id = id; self.state = state; self.updatedAt = updatedAt; self.notice = notice
    }
}

struct HomeFeatureFact: Equatable, Sendable {
    enum State: String, Sendable { case blocked, needsDecision, working, ready, closed, unknown }
    let machineID: String
    let machineName: String
    let featureID: String
    let title: String
    let preview: String
    let state: State
    let emoji: String?
    let isLead: Bool
    let isArchived: Bool
    let isStale: Bool
    let activityAt: Date?
    /// The latest meaningful message, stage, or other source episode, never a poll timestamp.
    let evidenceID: String
    init(machineID: String, machineName: String, featureID: String, title: String,
         preview: String = "", state: State, emoji: String? = nil, isLead: Bool = false,
         isArchived: Bool = false, isStale: Bool = false, activityAt: Date? = nil, evidenceID: String = "") {
        self.machineID = machineID; self.machineName = machineName; self.featureID = featureID
        self.title = title; self.preview = preview; self.state = state; self.emoji = emoji
        self.isLead = isLead; self.isArchived = isArchived; self.isStale = isStale
        self.activityAt = activityAt; self.evidenceID = evidenceID
    }
    var id: String { HomeIdentity.scoped(kind: "feature", machineID: machineID, entityID: featureID) }
    var route: HomeRoute { .firstMate(machineID: machineID, featureID: featureID) }
}

struct HomeReviewFact: Equatable, Sendable {
    enum State: String, Sendable { case preparing, ready, failed, unknown }
    let machineID: String
    let machineName: String
    let reviewID: String
    let title: String
    let pullRequest: HomePullRequestIdentity?
    let state: State
    let needsUser: Bool
    let userAttentionKnown: Bool
    let isOwnPR: Bool
    let isArchived: Bool
    let isClosed: Bool
    let isStale: Bool
    let error: String?
    let activityAt: Date?
    let evidenceID: String
    init(machineID: String, machineName: String, reviewID: String, title: String,
         pullRequest: HomePullRequestIdentity? = nil, state: State, needsUser: Bool = false, userAttentionKnown: Bool = true,
         isOwnPR: Bool = false, isArchived: Bool = false, isClosed: Bool = false,
         isStale: Bool = false, error: String? = nil, activityAt: Date? = nil, evidenceID: String = "") {
        self.machineID = machineID; self.machineName = machineName; self.reviewID = reviewID
        self.title = title; self.pullRequest = pullRequest; self.state = state; self.needsUser = needsUser
        self.userAttentionKnown = userAttentionKnown
        self.isOwnPR = isOwnPR; self.isArchived = isArchived; self.isClosed = isClosed
        self.isStale = isStale; self.error = error; self.activityAt = activityAt; self.evidenceID = evidenceID
    }
    var id: String { HomeIdentity.scoped(kind: "review", machineID: machineID, entityID: reviewID) }
    var route: HomeRoute { .review(machineID: machineID, reviewID: reviewID) }
}

struct HomeReviewRequestFact: Equatable, Sendable {
    let pullRequest: HomePullRequestIdentity
    let title: String
    let isDraft: Bool
    let isOpen: Bool
    let isStale: Bool
    let author: String
    init(pullRequest: HomePullRequestIdentity, title: String, isDraft: Bool = false,
         isOpen: Bool = true, isStale: Bool = false, author: String = "") {
        self.pullRequest = pullRequest; self.title = title
        self.isDraft = isDraft; self.isOpen = isOpen; self.isStale = isStale; self.author = author
    }
}

struct HomeWatcherFact: Equatable, Sendable {
    let machineID: String
    let machineName: String
    let watcherID: String
    let title: String
    let summary: String
    let avatar: String
    let attention: String?
    let isWorking: Bool
    let isStale: Bool
    let evidenceID: String
    init(machineID: String, machineName: String, watcherID: String, title: String,
         summary: String = "", avatar: String = "gauge", attention: String? = nil,
         isWorking: Bool = false, isStale: Bool = false, evidenceID: String = "") {
        self.machineID = machineID; self.machineName = machineName; self.watcherID = watcherID
        self.title = title; self.summary = summary; self.avatar = avatar; self.attention = attention
        self.isWorking = isWorking; self.isStale = isStale; self.evidenceID = evidenceID
    }
    var id: String { HomeIdentity.scoped(kind: "watcher", machineID: machineID, entityID: watcherID) }
    var route: HomeRoute { .watcher(machineID: machineID, watcherID: watcherID) }
}

struct HomeChatFact: Equatable, Sendable {
    let paneID: String
    let machineID: String
    let title: String
    let location: String
    let preview: String
    let isWaiting: Bool
    let isUnreadCompletion: Bool
    let isReservedShell: Bool
    let isWorker: Bool
    let isStale: Bool
    let colorHex: String?
    let activityAt: Date?
    let evidenceID: String
    init(paneID: String, machineID: String, title: String, location: String = "", preview: String = "",
         isWaiting: Bool = false, isUnreadCompletion: Bool = false, isReservedShell: Bool = false,
         isWorker: Bool = false, isStale: Bool = false, colorHex: String? = nil,
         activityAt: Date? = nil, evidenceID: String = "") {
        self.paneID = paneID; self.machineID = machineID; self.title = title; self.location = location
        self.preview = preview; self.isWaiting = isWaiting; self.isUnreadCompletion = isUnreadCompletion
        self.isReservedShell = isReservedShell; self.isWorker = isWorker; self.isStale = isStale
        self.colorHex = colorHex; self.activityAt = activityAt; self.evidenceID = evidenceID
    }
}

struct HomeRecapFact: Equatable, Sendable {
    let machineID: String
    let eventID: String
    let date: Date?
    let title: String
    let detail: String
    let symbol: String
    let tone: HomeTone
    let route: HomeRoute?
    init(machineID: String, eventID: String, date: Date?, title: String, detail: String = "",
         symbol: String = "checkmark.circle", tone: HomeTone = .idle, route: HomeRoute? = nil) {
        self.machineID = machineID; self.eventID = eventID; self.date = date
        self.title = title; self.detail = detail; self.symbol = symbol; self.tone = tone; self.route = route
    }
    var id: String { HomeIdentity.scoped(kind: "recap", machineID: machineID, entityID: eventID) }
}
