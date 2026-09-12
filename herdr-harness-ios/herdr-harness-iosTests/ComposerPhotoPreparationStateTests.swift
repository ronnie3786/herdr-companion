import Testing
@testable import herdr_harness_ios

@Suite("Composer photo preparation state")
struct ComposerPhotoPreparationStateTests {
    @Test("Preparation is visible and blocks sending until completion")
    func preparationBlocksSending() {
        var state = ComposerPhotoPreparationState()
        let token = state.begin(photoCount: 1)

        #expect(state.isPreparing)
        #expect(state.blocksSending)
        #expect(state.statusText == "Preparing photo…")

        let didFinish = state.finish(token)
        #expect(didFinish)
        #expect(!state.isPreparing)
        #expect(!state.blocksSending)
    }

    @Test("Invalid preparation completion unblocks sending")
    func invalidPreparationCompletionUnblocksSending() {
        var state = ComposerPhotoPreparationState()
        let token = state.begin(photoCount: 2)

        // Validation failures complete the same generation without enqueueing it.
        #expect(state.statusText == "Preparing 2 photos…")
        let didFinish = state.finish(token)
        #expect(didFinish)
        #expect(!state.blocksSending)
        #expect(state.photoCount == 0)
    }

    @Test("A canceled or superseded task cannot clear newer progress")
    func staleCompletionDoesNotResetNewerSelection() {
        var state = ComposerPhotoPreparationState()
        let oldToken = state.begin(photoCount: 1)
        let newToken = state.begin(photoCount: 3)

        let oldTaskFinished = state.finish(oldToken)
        #expect(!oldTaskFinished)
        #expect(state.owns(newToken))
        #expect(state.photoCount == 3)
        #expect(state.blocksSending)

        state.cancel()
        let canceledTaskFinished = state.finish(newToken)
        #expect(!canceledTaskFinished)
        #expect(!state.isPreparing)
        #expect(!state.blocksSending)
    }
}
