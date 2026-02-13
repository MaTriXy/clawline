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
    @FocusState private var focusedEditor: EditorMode?

    private enum EditorMode: Hashable {
        case renaming(String)
    }

    private let listRowHeight: CGFloat = 52
    private let functionBarHeight: CGFloat = 58
    private let listOuterVerticalPadding: CGFloat = 16
    private let minimumPopoverHeight: CGFloat = 140

    private var cappedContainerHeight: CGFloat {
        StreamSelectorLayout.containerHeight(
            itemCount: viewModel.orderedStreams.count,
            showsCreateInlineRow: false,
            rowHeight: listRowHeight,
            functionBarHeight: functionBarHeight,
            outerVerticalPadding: listOuterVerticalPadding,
            maxAvailableHeight: maxAvailableHeight,
            minimumPopoverHeight: minimumPopoverHeight
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(viewModel.orderedStreams) { stream in
                    rowContent(for: stream)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                beginRenaming(stream)
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .disabled(!canPerformRenameAction(for: stream))
                            .tint(canPerformRenameAction(for: stream) ? .blue : Color.gray.opacity(0.35))

                            Button {
                                Task { await deleteStream(stream) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(!canPerformDeleteAction(for: stream))
                            .tint(canPerformDeleteAction(for: stream) ? .red : Color.gray.opacity(0.35))
                        }
                }
            }
            .listStyle(.plain)
            .padding(.vertical, listOuterVerticalPadding)
            .disabled(isWorking)

            // Keep add affordance vertically centered regardless of keyboard/layout changes.
            ZStack {
                Button {
                    Task { await addStreamDirectly() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .accessibilityLabel("Add stream")
                .accessibilityHint("Creates a new stream")
            }
            .frame(maxWidth: .infinity)
            .frame(height: functionBarHeight, alignment: .center)
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
                .font(.system(size: 28))
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
                HStack(spacing: 10) {
                    Circle()
                        .fill(stream.sessionKey == viewModel.activeSessionKey ? Color.accentColor : Color.primary.opacity(0.25))
                        .frame(width: 8, height: 8)
                    Text(stream.displayName)
                        .font(.system(size: 28, weight: stream.sessionKey == viewModel.activeSessionKey ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    private func beginRenaming(_ stream: StreamSession) {
        activeEditor = .renaming(stream.sessionKey)
        draftName = stream.displayName
        Task { @MainActor in
            focusedEditor = .renaming(stream.sessionKey)
        }
    }

    private func resetInlineEditing() {
        activeEditor = nil
        draftName = ""
        focusedEditor = nil
    }

    private func canPerformRenameAction(for stream: StreamSession) -> Bool {
        guard !isWorking else { return false }
        guard activeEditor != .renaming(stream.sessionKey) else { return false }
        return viewModel.canRenameStream(sessionKey: stream.sessionKey)
    }

    private func canPerformDeleteAction(for stream: StreamSession) -> Bool {
        guard !isWorking else { return false }
        guard activeEditor != .renaming(stream.sessionKey) else { return false }
        return viewModel.canDeleteStream(sessionKey: stream.sessionKey)
    }

    private func addStreamDirectly() async {
        let existingCount = viewModel.orderedStreams.count
        let name = "Stream \(existingCount + 1)"
        isWorking = true
        let succeeded = await viewModel.createStream(displayName: name)
        isWorking = false
        guard succeeded else { return }
        // Switch to the new stream and dismiss
        if let newStream = viewModel.orderedStreams.last {
            onSelectStream(newStream.sessionKey)
        }
        isPresented = false
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
        outerVerticalPadding: CGFloat,
        maxAvailableHeight: CGFloat,
        minimumPopoverHeight: CGFloat
    ) -> CGFloat {
        let rows = max(1, itemCount + (showsCreateInlineRow ? 1 : 0))
        let desired = CGFloat(rows) * rowHeight + functionBarHeight + (outerVerticalPadding * 2)
        let cap = max(minimumPopoverHeight, maxAvailableHeight)
        return min(desired, cap)
    }
}
