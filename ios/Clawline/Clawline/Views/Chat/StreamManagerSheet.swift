//
//  StreamManagerSheet.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import SwiftUI

struct StreamManagerSheet: View {
    @Bindable var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    let maxAvailableHeight: CGFloat
    let onSelectStream: (String) -> Void

    @State private var draftName = ""
    @State private var activeEditor: EditorMode?
    @State private var isWorking = false
    @State private var isAddButtonPopoverPresented = false
    @FocusState private var focusedEditor: EditorMode?

    private enum EditorMode: Hashable {
        case creating(UUID)
        case renaming(String)
    }

    private let listRowHeight: CGFloat = 44
    private let functionBarHeight: CGFloat = 52
    private let minimumPopoverHeight: CGFloat = 140

    private var showsCreateInlineRow: Bool {
        if case .creating = activeEditor {
            return true
        }
        return false
    }

    private var cappedContainerHeight: CGFloat {
        StreamSelectorLayout.containerHeight(
            itemCount: viewModel.orderedStreams.count,
            showsCreateInlineRow: showsCreateInlineRow,
            rowHeight: listRowHeight,
            functionBarHeight: functionBarHeight,
            maxAvailableHeight: maxAvailableHeight,
            minimumPopoverHeight: minimumPopoverHeight
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(viewModel.orderedStreams) { stream in
                    rowContent(for: stream)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if activeEditor != .renaming(stream.sessionKey) {
                                if viewModel.canRenameStream(sessionKey: stream.sessionKey) {
                                    Button {
                                        beginRenaming(stream)
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                }
                                if viewModel.canDeleteStream(sessionKey: stream.sessionKey) {
                                    Button(role: .destructive) {
                                        Task { await deleteStream(stream) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                }
                if case .creating(let id) = activeEditor {
                    TextField("Stream name", text: $draftName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(false)
                        .submitLabel(.done)
                        .focused($focusedEditor, equals: .creating(id))
                        .onSubmit {
                            Task { await createStream() }
                        }
                }
            }
            .listStyle(.plain)
            .disabled(isWorking)

            Divider()

            HStack {
                Spacer()
                Button {
                    beginCreatingStream()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 8, weight: .bold))
                            .offset(y: 1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .accessibilityLabel("Add stream")
                .accessibilityHint("Opens stream creation")
                .popover(
                    isPresented: $isAddButtonPopoverPresented,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .padding(12)
                        .presentationCompactAdaptation(.popover)
                }
                Spacer()
            }
            .frame(height: functionBarHeight)
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
        .frame(height: cappedContainerHeight)
        .onChange(of: isPresented) { _, presented in
            if !presented {
                resetInlineEditing()
            }
        }
    }

    @ViewBuilder
    private func rowContent(for stream: StreamSession) -> some View {
        if activeEditor == .renaming(stream.sessionKey) {
            TextField("Stream name", text: $draftName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .submitLabel(.done)
                .focused($focusedEditor, equals: .renaming(stream.sessionKey))
                .onSubmit {
                    Task { await renameStream(stream) }
                }
        } else {
            Button {
                onSelectStream(stream.sessionKey)
                isPresented = false
            } label: {
                Text(stream.displayName)
                    .fontWeight(stream.sessionKey == viewModel.activeSessionKey ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    private func beginCreatingStream() {
        let token = UUID()
        activeEditor = .creating(token)
        draftName = ""
        isAddButtonPopoverPresented = true
        Task { @MainActor in
            focusedEditor = .creating(token)
        }
    }

    private func beginRenaming(_ stream: StreamSession) {
        activeEditor = .renaming(stream.sessionKey)
        draftName = stream.displayName
        isAddButtonPopoverPresented = false
        Task { @MainActor in
            focusedEditor = .renaming(stream.sessionKey)
        }
    }

    private func resetInlineEditing() {
        activeEditor = nil
        draftName = ""
        focusedEditor = nil
        isAddButtonPopoverPresented = false
    }

    private func createStream() async {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        let succeeded = await viewModel.createStream(displayName: trimmed)
        isWorking = false
        guard succeeded else { return }
        resetInlineEditing()
    }

    private func renameStream(_ stream: StreamSession) async {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        let succeeded = await viewModel.renameStream(sessionKey: stream.sessionKey, displayName: trimmed)
        isWorking = false
        guard succeeded else { return }
        resetInlineEditing()
    }

    private func deleteStream(_ stream: StreamSession) async {
        isWorking = true
        _ = await viewModel.deleteStream(sessionKey: stream.sessionKey)
        isWorking = false
        if activeEditor == .renaming(stream.sessionKey) {
            resetInlineEditing()
        }
    }
}

enum StreamSelectorLayout {
    static func containerHeight(
        itemCount: Int,
        showsCreateInlineRow: Bool,
        rowHeight: CGFloat,
        functionBarHeight: CGFloat,
        maxAvailableHeight: CGFloat,
        minimumPopoverHeight: CGFloat
    ) -> CGFloat {
        let rows = max(1, itemCount + (showsCreateInlineRow ? 1 : 0))
        let desired = CGFloat(rows) * rowHeight + functionBarHeight
        let cap = max(minimumPopoverHeight, maxAvailableHeight)
        return min(desired, cap)
    }
}
