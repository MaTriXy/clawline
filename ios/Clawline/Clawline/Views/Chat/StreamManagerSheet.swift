//
//  StreamManagerSheet.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import SwiftUI

struct StreamManagerSheet: View {
    @Environment(\.colorScheme) private var colorScheme

    @Bindable var viewModel: ChatViewModel
    let streams: [StreamSession]
    let unreadSessionKeys: Set<String>
    @Binding var isPresented: Bool
    let maxAvailableHeight: CGFloat
    let onSelectStream: (String) -> Void

    @State private var draftName = ""
    @State private var searchQuery = ""
    @State private var activeEditor: EditorMode?
    @State private var isWorking = false
    @State private var isTrackPickerPresented = false
    @State private var selectedTrackCandidateSessionKey: String?
    @State private var removingSessionKeys: Set<String> = []
    @State private var pendingCreateRows: [PendingCreateRow] = []
    @State private var pendingRemovalStream: StreamSession?
    @State private var renderedContainerHeight: CGFloat = 0
    @FocusState private var focusedEditor: EditorMode?

    private enum EditorMode: Hashable {
        case renaming(String)
    }

    private struct PendingCreateRow: Identifiable, Hashable {
        let id: UUID
        let displayName: String
    }

    private let listRowHeight: CGFloat = 52
    private let listRowSpacing: CGFloat = 2
    private let listRowHorizontalInset: CGFloat = 12
    private let functionBarHeight: CGFloat = 40
    private let actionBarTopPadding: CGFloat = 12
    private let actionBarBottomPadding: CGFloat = 20
    private let listOuterVerticalPadding: CGFloat = 20
    private let minimumPopoverHeight: CGFloat = 140
    private let popupCornerRadius: CGFloat = 20
    private let actionBarSeparatorOpacity: CGFloat = 0.12
    private let actionBarSeparatorInset: CGFloat = 12

    private var actionBarHeight: CGFloat {
        functionBarHeight + actionBarTopPadding + actionBarBottomPadding
    }

    private var listItemCount: Int {
        filteredStreams.count + filteredPendingCreateRows.count
    }

    private var filteredStreams: [StreamSession] {
        StreamSelectorLayout.filter(streams: streams, query: searchQuery)
    }

    private var filteredPendingCreateRows: [PendingCreateRow] {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return pendingCreateRows
        }
        return pendingCreateRows.filter {
            StreamSelectorLayout.matchesStreamName($0.displayName, query: searchQuery)
        }
    }

    private var listContentHeight: CGFloat {
        StreamSelectorLayout.listContentHeight(
            itemCount: listItemCount,
            showsCreateInlineRow: false,
            rowHeight: listRowHeight,
            rowSpacing: listRowSpacing,
            outerVerticalPadding: listOuterVerticalPadding
        )
    }

    private var effectiveContainerHeight: CGFloat {
        if renderedContainerHeight > 0 {
            return renderedContainerHeight
        }
        return cappedContainerHeight
    }

    private var listViewportHeight: CGFloat {
        max(0, effectiveContainerHeight - actionBarHeight)
    }

    private var allowsListScrolling: Bool {
        listContentHeight > listViewportHeight + 0.5
    }

    private var cappedContainerHeight: CGFloat {
        StreamSelectorLayout.containerHeight(
            itemCount: listItemCount,
            showsCreateInlineRow: false,
            rowHeight: listRowHeight,
            rowSpacing: listRowSpacing,
            functionBarHeight: actionBarHeight,
            outerVerticalPadding: listOuterVerticalPadding,
            maxAvailableHeight: maxAvailableHeight,
            minimumPopoverHeight: minimumPopoverHeight
        )
    }

    private var trackCandidates: [ChatViewModel.UntrackedSessionCandidate] {
        viewModel.untrackedSessionCandidates
    }

    private var selectedTrackCandidate: ChatViewModel.UntrackedSessionCandidate? {
        guard let selectedTrackCandidateSessionKey else { return nil }
        return trackCandidates.first { $0.sessionKey == selectedTrackCandidateSessionKey }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(filteredStreams) { stream in
                    rowContent(for: stream)
                        .frame(height: listRowHeight, alignment: .center)
                        .listRowInsets(
                            EdgeInsets(
                                top: 0,
                                leading: listRowHorizontalInset,
                                bottom: 0,
                                trailing: listRowHorizontalInset
                            )
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                beginRenaming(stream)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.title3.weight(.semibold))
                            }
                            .accessibilityLabel("Rename")
                            .disabled(!canPerformRenameAction(for: stream))
                            .tint(canPerformRenameAction(for: stream) ? .blue : Color.gray.opacity(0.35))

                            Button {
                                pendingRemovalStream = stream
                            } label: {
                                Image(systemName: removalActionImage(for: stream))
                                    .font(.title3.weight(.semibold))
                            }
                            .accessibilityLabel(removalActionTitle(for: stream))
                            .disabled(!canPerformRemovalAction(for: stream))
                            .tint(canPerformRemovalAction(for: stream) ? .red : Color.gray.opacity(0.35))
                        }
                }

                ForEach(filteredPendingCreateRows) { pendingRow in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.primary.opacity(0.18))
                            .frame(width: 8, height: 8)
                        Text(pendingRow.displayName)
                            .font(.clawline(.subsectionHeader).weight(.regular))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .frame(height: listRowHeight, alignment: .center)
                    .listRowInsets(
                        EdgeInsets(
                            top: 0,
                            leading: listRowHorizontalInset,
                            bottom: 0,
                            trailing: listRowHorizontalInset
                        )
                    )
                    .contentShape(Rectangle())
                }

                if filteredStreams.isEmpty && filteredPendingCreateRows.isEmpty {
                    Text("No streams found")
                        .font(.clawline(.secondaryLabel))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: listRowHeight, alignment: .center)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(
                            EdgeInsets(
                                top: 0,
                                leading: listRowHorizontalInset,
                                bottom: 0,
                                trailing: listRowHorizontalInset
                            )
                        )
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, listRowHeight)
            .listRowSpacing(listRowSpacing)
            .scrollDisabled(!allowsListScrolling)
            .scrollBounceBehavior(.always)
            .contentMargins(.top, listOuterVerticalPadding, for: .scrollContent)
            .contentMargins(.bottom, listOuterVerticalPadding, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .frame(height: listViewportHeight)
            .disabled(isWorking)

            Rectangle()
                .fill(Color.white.opacity(actionBarSeparatorOpacity))
                .frame(height: 0.5)
                .padding(.horizontal, actionBarSeparatorInset)
                .allowsHitTesting(false)

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter…", text: $searchQuery)
                        .font(.clawline(.uiLabel))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: functionBarHeight)
                .contentShape(Rectangle())

                if viewModel.canUseTrackFeature {
                    Button {
                        selectedTrackCandidateSessionKey = nil
                        isTrackPickerPresented = true
                    } label: {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.clear)
                            .frame(width: functionBarHeight, height: functionBarHeight, alignment: .center)
                            .overlay {
                                Image(systemName: "eye")
                                    .font(.clawline(.subsectionHeader).weight(.regular))
                                    .foregroundStyle(.primary)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(activeEditor != nil || trackCandidates.isEmpty)
                    .accessibilityLabel("Track")
                    .accessibilityHint("Tracks an existing untracked session")
                }

                // Keep add affordance optically centered in a fixed-height toolbar regardless of keyboard changes.
                Button {
                    addStreamDirectly()
                } label: {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.clear)
                        .frame(width: functionBarHeight, height: functionBarHeight, alignment: .center)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.clawline(.subsectionHeader).weight(.regular))
                                .foregroundStyle(.primary)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(activeEditor != nil)
                .accessibilityLabel("Add stream")
                .accessibilityHint("Creates a new stream")
            }
            .padding(.horizontal, listRowHorizontalInset)
            .padding(.top, actionBarTopPadding)
            .padding(.bottom, actionBarBottomPadding)
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
        .frame(height: cappedContainerHeight)
        .background(Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        renderedContainerHeight = proxy.size.height
                    }
                    .onChange(of: proxy.size.height) { _, newValue in
                        renderedContainerHeight = newValue
                    }
            }
        )
        .onChange(of: isPresented) { _, presented in
            if !presented {
                resetInlineEditing()
                searchQuery = ""
            }
        }
        .onChange(of: trackCandidates.map(\.sessionKey)) { _, sessionKeys in
            guard let selectedTrackCandidateSessionKey else { return }
            if !sessionKeys.contains(selectedTrackCandidateSessionKey) {
                self.selectedTrackCandidateSessionKey = nil
            }
        }
        .alert(
            pendingRemovalTitle,
            isPresented: Binding(
                get: { pendingRemovalStream != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRemovalStream = nil
                    }
                }
            ),
            presenting: pendingRemovalStream
        ) { stream in
            Button("Cancel", role: .cancel) {}
            Button(removalActionTitle(for: stream), role: .destructive) {
                pendingRemovalStream = nil
                Task { await removeStream(stream) }
            }
        }
        .sheet(
            isPresented: $isTrackPickerPresented,
            onDismiss: { selectedTrackCandidateSessionKey = nil }
        ) {
            trackPickerSheet
        }
    }

    @ViewBuilder
    private func rowContent(for stream: StreamSession) -> some View {
        if activeEditor == .renaming(stream.sessionKey) {
            TextField("Stream name", text: $draftName)
                .font(.clawline(.subsectionHeader))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .submitLabel(.done)
                .focused($focusedEditor, equals: .renaming(stream.sessionKey))
                .onSubmit {
                    Task { await renameStream(stream) }
                }
        } else {
            Button {
                let selectedSessionKey = stream.sessionKey
                isPresented = false
                // Avoid mutating presentation + selected stream in the same synchronous tap turn.
                // Deferring selection to the next main-actor cycle prevents picker-triggered UI lockups.
                Task { @MainActor in
                    await Task.yield()
                    onSelectStream(selectedSessionKey)
                }
            } label: {
                HStack(spacing: 10) {
                    let isActive = stream.sessionKey == viewModel.uiSelectedSessionKey
                    let hasUnread = unreadSessionKeys.contains(stream.sessionKey)
                    Circle()
                        .fill(
                            StreamDotColor.resolve(
                                isActive: isActive,
                                hasUnread: hasUnread,
                                colorScheme: colorScheme
                            )
                        )
                        .frame(width: 8, height: 8)
                        .shadow(
                            color: isActive ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                            radius: isActive ? StreamDotColor.activeOuterGlowRadius(colorScheme: colorScheme) : 0
                        )
                        .shadow(
                            color: isActive ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                            radius: isActive ? StreamDotColor.activeInnerGlowRadius(colorScheme: colorScheme) : 0
                        )
                    Text(stream.displayName)
                        .font(.clawline(.subsectionHeader).weight(isActive ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isRemovingStream(stream.sessionKey) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isWorking || isRemovingStream(stream.sessionKey))
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
        removingSessionKeys.removeAll()
        pendingCreateRows.removeAll()
        pendingRemovalStream = nil
    }

    private func canPerformRenameAction(for stream: StreamSession) -> Bool {
        guard !isWorking else { return false }
        guard !isRemovingStream(stream.sessionKey) else { return false }
        guard activeEditor != .renaming(stream.sessionKey) else { return false }
        return viewModel.canRenameStream(sessionKey: stream.sessionKey)
    }

    private func canPerformRemovalAction(for stream: StreamSession) -> Bool {
        guard !isWorking else { return false }
        guard !isRemovingStream(stream.sessionKey) else { return false }
        guard activeEditor != .renaming(stream.sessionKey) else { return false }
        return viewModel.isAdoptedStream(sessionKey: stream.sessionKey)
            ? viewModel.canUntrackStream(sessionKey: stream.sessionKey)
            : viewModel.canDeleteStream(sessionKey: stream.sessionKey)
    }

    private func isRemovingStream(_ sessionKey: String) -> Bool {
        removingSessionKeys.contains(sessionKey)
    }

    private func addStreamDirectly() {
        let existingCount = streams.count + pendingCreateRows.count
        let name = "Stream \(existingCount + 1)"
        let pendingID = UUID()
        pendingCreateRows.append(PendingCreateRow(id: pendingID, displayName: name))

        Task {
            _ = await viewModel.createStream(displayName: name)
            await MainActor.run {
                pendingCreateRows.removeAll { $0.id == pendingID }
            }
        }
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

    private func removeStream(_ stream: StreamSession) async {
        guard !isRemovingStream(stream.sessionKey) else { return }
        removingSessionKeys.insert(stream.sessionKey)
        let succeeded: Bool
        if viewModel.isAdoptedStream(sessionKey: stream.sessionKey) {
            succeeded = viewModel.untrackStream(sessionKey: stream.sessionKey)
        } else {
            succeeded = await viewModel.deleteStream(sessionKey: stream.sessionKey)
        }
        if !succeeded {
            removingSessionKeys.remove(stream.sessionKey)
        }
        if activeEditor == .renaming(stream.sessionKey) {
            resetInlineEditing()
        }
    }

    private var pendingRemovalTitle: String {
        guard let stream = pendingRemovalStream else { return "Are you sure?" }
        return viewModel.isAdoptedStream(sessionKey: stream.sessionKey) ? "Untrack this session?" : "Delete this stream?"
    }

    private func removalActionTitle(for stream: StreamSession) -> String {
        viewModel.isAdoptedStream(sessionKey: stream.sessionKey) ? "Untrack" : "Delete"
    }

    private func removalActionImage(for stream: StreamSession) -> String {
        viewModel.isAdoptedStream(sessionKey: stream.sessionKey) ? "eye.slash" : "trash"
    }

    private func dismissTrackPicker() {
        selectedTrackCandidateSessionKey = nil
        isTrackPickerPresented = false
    }

    private func adoptSelectedTrackSession() {
        guard let selectedTrackCandidate else { return }
        guard viewModel.trackSession(sessionKey: selectedTrackCandidate.sessionKey) else { return }
        dismissTrackPicker()
    }

    private var trackPickerSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose an untracked session to adopt as a Clawline chat.")
                        .font(.clawline(.secondaryLabel))
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section("Other Sessions") {
                    ForEach(trackCandidates) { candidate in
                        Button {
                            selectedTrackCandidateSessionKey = candidate.sessionKey
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.displayName)
                                        .font(.clawline(.subsectionHeader))
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text("Agent session")
                                        .font(.clawline(.secondaryLabel))
                                        .foregroundStyle(.secondary)
                                }

                                Image(systemName: selectedTrackCandidateSessionKey == candidate.sessionKey ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedTrackCandidateSessionKey == candidate.sessionKey ? .primary : .secondary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Track Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismissTrackPicker()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Adopt") {
                        adoptSelectedTrackSession()
                    }
                    .disabled(selectedTrackCandidate == nil)
                }
            }
        }
    }

}

enum StreamSelectorLayout {
    static func filter(streams: [StreamSession], query: String) -> [StreamSession] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return streams }
        return streams.filter { stream in
            matchesStreamName(stream.displayName, query: normalized)
        }
    }

    static func matchesStreamName(_ displayName: String, query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return displayName.localizedCaseInsensitiveContains(normalized)
    }

    static func listContentHeight(
        itemCount: Int,
        showsCreateInlineRow: Bool,
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        outerVerticalPadding: CGFloat
    ) -> CGFloat {
        let rows = max(1, itemCount + (showsCreateInlineRow ? 1 : 0))
        let interRowSpacing = CGFloat(max(0, rows - 1)) * rowSpacing
        return CGFloat(rows) * rowHeight + interRowSpacing + (outerVerticalPadding * 2)
    }

    static func containerHeight(
        itemCount: Int,
        showsCreateInlineRow: Bool,
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        functionBarHeight: CGFloat,
        outerVerticalPadding: CGFloat,
        maxAvailableHeight: CGFloat,
        minimumPopoverHeight: CGFloat
    ) -> CGFloat {
        let desired = desiredHeight(
            itemCount: itemCount,
            showsCreateInlineRow: showsCreateInlineRow,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing,
            functionBarHeight: functionBarHeight,
            outerVerticalPadding: outerVerticalPadding
        )
        let cap = max(minimumPopoverHeight, maxAvailableHeight)
        return min(desired, cap)
    }

    static func isOverflowing(
        itemCount: Int,
        showsCreateInlineRow: Bool,
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        functionBarHeight: CGFloat,
        outerVerticalPadding: CGFloat,
        maxAvailableHeight: CGFloat,
        minimumPopoverHeight: CGFloat
    ) -> Bool {
        let desired = desiredHeight(
            itemCount: itemCount,
            showsCreateInlineRow: showsCreateInlineRow,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing,
            functionBarHeight: functionBarHeight,
            outerVerticalPadding: outerVerticalPadding
        )
        let cap = max(minimumPopoverHeight, maxAvailableHeight)
        return desired > cap + 0.5
    }

    private static func desiredHeight(
        itemCount: Int,
        showsCreateInlineRow: Bool,
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        functionBarHeight: CGFloat,
        outerVerticalPadding: CGFloat
    ) -> CGFloat {
        let listHeight = listContentHeight(
            itemCount: itemCount,
            showsCreateInlineRow: showsCreateInlineRow,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing,
            outerVerticalPadding: outerVerticalPadding
        )
        return listHeight + functionBarHeight
    }
}
