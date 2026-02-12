//
//  StreamManagerSheet.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import SwiftUI

struct StreamManagerSheet: View {
    @Bindable var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newStreamName = ""
    @State private var renameTarget: StreamSession?
    @State private var renameValue = ""
    @State private var deleteTarget: StreamSession?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            List {
                Section("Add Stream") {
                    HStack(spacing: 12) {
                        TextField("Stream name", text: $newStreamName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled(false)
                        Button("Add") {
                            Task { await createStream() }
                        }
                        .disabled(isWorking || newStreamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("Streams") {
                    ForEach(viewModel.orderedStreams) { stream in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(stream.displayName)
                                    .font(.body.weight(stream.sessionKey == viewModel.activeSessionKey ? .semibold : .regular))
                                Text(stream.sessionKey)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if stream.isBuiltIn {
                                Text("Built-in")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if viewModel.canRenameStream(sessionKey: stream.sessionKey) {
                                Button("Rename") {
                                    renameTarget = stream
                                    renameValue = stream.displayName
                                }
                                .buttonStyle(.borderless)
                                Button("Delete", role: .destructive) {
                                    deleteTarget = stream
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Text("Read-only")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Streams")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .disabled(isWorking)
            .alert("Rename Stream", isPresented: renamePresentedBinding) {
                TextField("Name", text: $renameValue)
                Button("Cancel", role: .cancel) {
                    renameTarget = nil
                }
                Button("Save") {
                    Task { await renameStream() }
                }
            } message: {
                Text("Enter a new stream name.")
            }
            .alert("Delete Stream?", isPresented: deletePresentedBinding) {
                Button("Cancel", role: .cancel) {
                    deleteTarget = nil
                }
                Button("Delete", role: .destructive) {
                    Task { await deleteStream() }
                }
            } message: {
                Text("This permanently deletes the stream and its message history.")
            }
        }
    }

    private var renamePresentedBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var deletePresentedBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private func createStream() async {
        let trimmed = newStreamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        await viewModel.createStream(displayName: trimmed)
        newStreamName = ""
        isWorking = false
    }

    private func renameStream() async {
        guard let target = renameTarget else { return }
        let trimmed = renameValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        await viewModel.renameStream(sessionKey: target.sessionKey, displayName: trimmed)
        renameTarget = nil
        isWorking = false
    }

    private func deleteStream() async {
        guard let target = deleteTarget else { return }
        isWorking = true
        await viewModel.deleteStream(sessionKey: target.sessionKey)
        deleteTarget = nil
        isWorking = false
    }
}
