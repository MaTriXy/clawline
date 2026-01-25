import SwiftUI

struct ErrorCatchingView<Content: View>: View {
    private let builder: () throws -> Content

    init(@ViewBuilder builder: @escaping () throws -> Content) {
        self.builder = builder
    }

    var body: some View {
        switch Result(catching: builder) {
        case .success(let content):
            content
        case .failure:
            Text("[Table rendering failed]")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
