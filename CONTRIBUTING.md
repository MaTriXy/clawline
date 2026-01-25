# Contributing to Clawline

We welcome contributions to Clawline! This document explains how to set up your development environment and contribute effectively.

## Development Environment

### Requirements

- **macOS**: Sequoia 15.0 or later
- **Xcode**: 26.0 or later (install from Mac App Store)
- **iOS Device/Simulator**: iOS 26.0+
- **Git**: For version control

### Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/clicketyclackety/clawline.git
   cd clawline
   ```

2. **Open in Xcode**
   ```bash
   open ios/Clawline/Clawline.xcodeproj
   ```

3. **Select a simulator or device** from the scheme menu

4. **Build** (⌘B) to verify everything compiles

### Running the App

- **Simulator**: Select any iPhone or iPad simulator and press ⌘R
- **Device**: Connect your device, trust it, and select it as the run destination

### Running Tests

From Xcode:
- Press ⌘U to run all tests

From command line:
```bash
cd ios/Clawline
xcodebuild test \
  -scheme Clawline \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -resultBundlePath TestResults
```

## Coding Standards

### Swift Style

- Use Swift's official [API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Prefer `let` over `var` when possible
- Use meaningful names; avoid abbreviations
- Keep functions focused and small

### SwiftUI Conventions

- Use `@Observable` for view models (not `ObservableObject`)
- Prefer composition over inheritance
- Extract reusable views into separate files
- Use `@Environment` for dependency injection where appropriate

### Architecture Patterns

- **Protocol-oriented design**: Define protocols for services to enable testing
- **Dependency injection**: Pass dependencies through initializers
- **Unidirectional data flow**: ViewModels expose read-only state

Example service protocol pattern:
```swift
// Protocol for testability
protocol ChatServicing {
    var incomingMessages: AsyncStream<Message> { get }
    func send(id: String, content: String) async throws
}

// Production implementation
final class ProviderChatService: ChatServicing {
    // ...
}

// Test mock
final class MockChatService: ChatServicing {
    // ...
}
```

### File Organization

```
Clawline/
├── Models/          # Data structures, no business logic
├── Views/           # SwiftUI views
├── ViewModels/      # @Observable state containers
├── Services/        # Business logic, networking
├── Protocols/       # Service protocols
├── DesignSystem/    # Theme, reusable components
├── Networking/      # Low-level network code
└── Extensions/      # Swift extensions
```

### Code Formatting

- Use 4-space indentation (Xcode default)
- Maximum line length: 120 characters (soft limit)
- One blank line between functions
- Group related properties and methods

## Pull Request Process

### Before You Start

1. **Check existing issues** — Your idea may already be tracked
2. **Open an issue first** for significant changes to discuss the approach
3. **Keep PRs focused** — One feature or fix per PR

### Creating a PR

1. **Fork** the repository (external contributors)

2. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make your changes** with clear, atomic commits

4. **Write/update tests** for your changes

5. **Run tests locally** to verify nothing breaks

6. **Push and open a PR** against `main`

### PR Guidelines

- **Title**: Use imperative mood ("Add feature" not "Added feature")
- **Description**: Explain what and why, not just how
- **Screenshots**: Include for UI changes
- **Testing**: Describe how you tested the changes

### Code Review

- All PRs require at least one approval
- Address review feedback with new commits (don't force-push during review)
- Squash commits when merging if the history is messy

## Commit Messages

Follow conventional commit format:

```
<type>: <short description>

<optional longer description>
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Formatting, no code change
- `refactor`: Code change that neither fixes a bug nor adds a feature
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

Examples:
```
feat: Add typing indicator for assistant responses

fix: Prevent keyboard from dismissing when sending message

docs: Update README with build instructions
```

## Testing

### Unit Tests

Located in `ClawlineTests/`. Test:
- ViewModels
- Services (using protocol mocks)
- Model logic
- Utilities

### Writing Tests

```swift
import XCTest
@testable import Clawline

final class ChatViewModelTests: XCTestCase {
    var sut: ChatViewModel!
    var mockService: MockChatService!

    override func setUp() {
        super.setUp()
        mockService = MockChatService()
        sut = ChatViewModel(chatService: mockService, ...)
    }

    func testSendMessage_appendsToMessages() async {
        // Given
        let content = "Hello"

        // When
        await sut.send(content: content)

        // Then
        XCTAssertEqual(sut.messages.count, 1)
    }
}
```

## Getting Help

- **Questions**: Open a [Discussion](https://github.com/clicketyclackety/clawline/discussions)
- **Bugs**: Open an [Issue](https://github.com/clicketyclackety/clawline/issues) with reproduction steps
- **Security**: Email security@clicketyclacks.co (do not open public issues)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
