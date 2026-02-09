import Testing
@testable import Clawline

struct ScrollToBottomUnreadTests {
    @Test("Appended message IDs: previous nil yields empty")
    func appendedIdsPreviousNil() {
        let result = MessageFlowCollectionViewController.appendedMessageIDs(
            previousLastMessageId: nil,
            messageIDs: ["a", "b"]
        )
        #expect(result.isEmpty)
    }

    @Test("Appended message IDs: returns IDs after previous last")
    func appendedIdsAfterPrevious() {
        let result = MessageFlowCollectionViewController.appendedMessageIDs(
            previousLastMessageId: "b",
            messageIDs: ["a", "b", "c", "d"]
        )
        #expect(result == ["c", "d"])
    }

    @Test("Appended message IDs: previous last at end yields empty")
    func appendedIdsPreviousAtEnd() {
        let result = MessageFlowCollectionViewController.appendedMessageIDs(
            previousLastMessageId: "d",
            messageIDs: ["a", "b", "c", "d"]
        )
        #expect(result.isEmpty)
    }

    @Test("Appended message IDs: previous not found yields empty")
    func appendedIdsPreviousMissing() {
        let result = MessageFlowCollectionViewController.appendedMessageIDs(
            previousLastMessageId: "x",
            messageIDs: ["a", "b", "c"]
        )
        #expect(result.isEmpty)
    }
}

