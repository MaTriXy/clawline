import Foundation
import Testing
import UIKit
@testable import Clawline

struct TextViewLinkActivationTests {
    @Test("Text-view link activation uses shared release-triggered handler")
    @MainActor
    func sharedReleaseTriggeredHandlerCancelsDefaultAction() {
        let url = URL(string: "https://example.com/release-triggered-link")!
        var openedURLs: [URL] = []

        let shouldAllowDefaultAction = UnifiedMarkdownRenderer.handleReleaseTriggeredLinkActivation(url) { openedURL in
            openedURLs.append(openedURL)
        }

        #expect(openedURLs == [url])
        #expect(shouldAllowDefaultAction == false)
    }

    @Test("Non-default text-item interactions do not eagerly open links")
    @MainActor
    func nonDefaultInteractionsRemainAvailableToUIKit() {
        let url = URL(string: "https://example.com/release-triggered-link")!
        var openedURLs: [URL] = []

        let shouldAllowPreview = UnifiedMarkdownRenderer.handleReleaseTriggeredLinkActivation(
            url,
            interaction: .preview
        ) { openedURL in
            openedURLs.append(openedURL)
        }
        let shouldAllowActions = UnifiedMarkdownRenderer.handleReleaseTriggeredLinkActivation(
            url,
            interaction: .presentActions
        ) { openedURL in
            openedURLs.append(openedURL)
        }

        #expect(openedURLs.isEmpty)
        #expect(shouldAllowPreview)
        #expect(shouldAllowActions)
    }
}
