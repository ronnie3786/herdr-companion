import Foundation

/// Synthetic Builds for demo mode and renders. Two demo features get builds:
/// Receipt export (two Mobile App Hub builds, one with its simulator copy, and
/// a simulator checkpoint, none running) and Review search (a hub build whose
/// simulator is already running, and a checkpoint). Nothing here contacts a
/// hub, a companion or SimPortal, and every name, ID and link is invented.
enum FirstMateBuildsDemo {
    static let hubURL = URL(string: "https://builds.example.invalid")!

    struct Content: Equatable {
        var hub: [MobileAppHubBuild]
        var simulator: [FirstMateSimulatorBuild]
    }

    static func content(for snapshot: FirstMateSnapshot, machineName: String, now: Date = .now) -> Content? {
        let builder = Builder(snapshot: snapshot, machineName: machineName, now: now)
        switch snapshot.feature.id {
        case "demo-receipts": return builder.receipts()
        case "demo-search": return builder.reviewSearch()
        default: return nil
        }
    }

    /// The running demo preview's picture, by app.
    static func screenKind(for build: FirstMateSimulatorBuild) -> FirstMateSimulatorDemoAppScreen.Kind {
        build.app?.bundleID == reviewsBundleID ? .reviews : .receipts
    }

    static let receiptsBundleID = "com.example.receipts"
    static let reviewsBundleID = "com.example.reviews"

    private struct Builder {
        let snapshot: FirstMateSnapshot
        let machineName: String
        let now: Date

        var featureID: String { snapshot.feature.id }

        func receipts() -> Content {
            let qa = visit(["proof", "qa"])
            let tester = assignment(title: "Device QA", role: "Tester")
            let builder = assignment(title: "Export flow", role: "Builder")
            let iPadFix = hub(id: "demo-hub-receipts-118", app: "Receipts", bundleID: receiptsBundleID, version: "2.4", build: "118",
                              minutesAgo: 12, ticket: "DEMO-231", title: "Month export, iPad fix", by: tester)
            let firstBuild = hub(id: "demo-hub-receipts-117", app: "Receipts", bundleID: receiptsBundleID, version: "2.4", build: "117",
                                 minutesAgo: 180, ticket: "DEMO-231", title: "Month export, first build", by: builder)
            return Content(
                hub: [iPadFix, firstBuild],
                simulator: [
                    simulator(id: "demo-sim-receipts-118", label: "Month export, iPad fix", visit: qa, by: tester,
                              app: "Receipts", bundleID: receiptsBundleID, version: "2.4", build: "118", minutesAgo: 13,
                              hubBuildID: iPadFix.id),
                    simulator(id: "demo-sim-receipts-qa2", label: "QA round 2 checkpoint", visit: qa, by: tester,
                              app: "Receipts", bundleID: receiptsBundleID, version: "2.4", build: "118", minutesAgo: 38),
                ])
        }

        func reviewSearch() -> Content {
            let build = visit(["implement", "build"])
            let review = visit(["review"])
            let indexer = assignment(title: "Search index", role: "Builder")
            let reviewers = assignment(title: "Seven reviewers", role: "Reviewer")
            let results = hub(id: "demo-hub-search-88", app: "Review search", bundleID: reviewsBundleID, version: "1.9", build: "88",
                              minutesAgo: 25, ticket: "DEMO-214", title: "Search results screen", by: indexer)
            return Content(
                hub: [results],
                simulator: [
                    simulator(id: "demo-sim-search-88", label: "Search results screen", visit: build, by: indexer,
                              app: "Review search", bundleID: reviewsBundleID, version: "1.9", build: "88", minutesAgo: 26,
                              hubBuildID: results.id, running: true),
                    simulator(id: "demo-sim-search-review", label: "Reviewer fixes checkpoint", visit: review, by: reviewers,
                              app: "Review search", bundleID: reviewsBundleID, version: "1.9", build: "87", minutesAgo: 110),
                ])
        }

        private func visit(_ stageKeys: [String]) -> FirstMateVisit? {
            snapshot.visits.last { stageKeys.contains($0.stageKey) } ?? snapshot.visits.last
        }

        private func assignment(title: String, role: String) -> FirstMateAssignment? {
            snapshot.assignments.first { $0.title == title } ?? snapshot.assignments.first { $0.role == role }
        }

        private func date(_ minutesAgo: Int) -> Date { now.addingTimeInterval(-Double(minutesAgo) * 60) }

        private func hub(id: String, app: String, bundleID: String, version: String, build: String, minutesAgo: Int,
                         ticket: String, title: String, by assignment: FirstMateAssignment?) -> MobileAppHubBuild {
            let page = hubURL.appending(path: "builds/\(id)")
            let manifest = hubURL.appending(path: "install/\(id)/manifest.plist").absoluteString
            return MobileAppHubBuild(
                id: id,
                app: .init(name: app, bundleID: bundleID, slug: bundleID),
                version: version, buildNumber: build, builtAt: date(minutesAgo), uploadedAt: date(minutesAgo),
                label: .init(ticket: ticket, title: title),
                source: .init(machine: machineName, branch: "feature/\(ticket.lowercased())"),
                urls: .init(page: page, appPage: hubURL.appending(path: "apps/\(bundleID)"), icon: nil,
                            install: URL(string: "itms-services://?action=download-manifest&url=\(manifest)")),
                signing: .init(expiresAt: now.addingTimeInterval(180 * 24 * 3600)),
                herdrContexts: [.init(firstMateFeatureID: featureID, firstMateAssignmentID: assignment?.id)])
        }

        private func simulator(id: String, label: String, visit: FirstMateVisit?, by assignment: FirstMateAssignment?,
                               app: String, bundleID: String, version: String, build: String, minutesAgo: Int,
                               hubBuildID: String? = nil, running: Bool = false) -> FirstMateSimulatorBuild {
            let previews = running ? [FirstMateSimulatorPreview(
                id: "fmsp_demo0000000000000000000000000001", featureID: featureID, buildID: id,
                phase: "running", status: "ready", device: FirstMateSimulatorDemo.device)] : []
            return FirstMateSimulatorBuild(
                id: id, featureID: featureID, name: "\(app) · \(label)", checkpointID: assignment?.id ?? id,
                checkpointLabel: label, stageTitle: visit?.title, visitID: visit?.id, assignmentID: assignment?.id,
                hubBuildID: hubBuildID, status: "ready",
                app: .init(name: app, bundleID: bundleID, version: version, build: build, minimumOS: "18.0"),
                source: .init(revision: "4f1c2d9e7b3a5c6d8e9f0a1b2c3d4e5f6a7b8c9d", workingTree: "clean",
                              configuration: "Debug", target: app),
                launchable: true, createdAt: HerdrTimestamp.string(from: date(minutesAgo)), previews: previews)
        }
    }
}
