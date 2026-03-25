import CoreFoundation
import Testing
@testable import Clawline

struct BottomInsetHeightCapInvalidationTests {
    @Test("Typing-driven inset churn does not queue height-cap invalidation")
    func typingInsetChurnIsIgnored() {
        let shouldSchedule = MessageFlowCollectionViewController.shouldScheduleBottomInsetHeightCapInvalidation(
            previousBottomInset: 284,
            newBottomInset: 316,
            isInputActive: true
        )

        #expect(shouldSchedule == false)
    }

    @Test("Large keyboard-dismiss inset collapse still queues height-cap invalidation")
    func keyboardDismissInsetCollapseStillQueues() {
        let shouldSchedule = MessageFlowCollectionViewController.shouldScheduleBottomInsetHeightCapInvalidation(
            previousBottomInset: 420,
            newBottomInset: 280,
            isInputActive: true
        )

        #expect(shouldSchedule == true)
    }

    @Test("Settled inset changes still queue invalidation once input is inactive")
    func inactiveInsetChangeStillQueues() {
        let shouldSchedule = MessageFlowCollectionViewController.shouldScheduleBottomInsetHeightCapInvalidation(
            previousBottomInset: 180,
            newBottomInset: 212,
            isInputActive: false
        )

        #expect(shouldSchedule == true)
    }
}
