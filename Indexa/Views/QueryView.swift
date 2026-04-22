import SwiftUI

/// The query input area and conversation display at the bottom of the collection detail view.
struct QueryView: View {
    @Environment(AppState.self) var appState
    @State private var isEditingPrompt = false
    @State private var promptDraft = ""
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 0) {
            // ── Conversation area ─────────────────────────────────────
            if !appState.conversationHistory.isEmpty || appState.isQuerying || appState.queryError != nil {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(appState.conversationHistory) { message in
                                MessageBubble(message: message, showSources: appState.canViewSources)
                            }

                            if appState.isQuerying {
                                if appState.streamingAnswer.isEmpty {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Searching documents...")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .id("loading")
                                } else {
                                    // Show streaming response as it comes in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "sparkles")
                                                .font(.caption2)
                                                .foregroundColor(.accentColor)
                                            Text("Indexa")
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundColor(.secondary)
                                            ProgressView()
                                                .controlSize(.mini)
                                        }
                                        MarkdownView(text: appState.streamingAnswer)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(Color.primary.opacity(0.03))
                                            .cornerRadius(10)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .id("streaming")
                                }
                            }

                            if let error = appState.queryError {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(.orange)
                                    Text(error)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .frame(maxHeight: 350)
                    .onChange(of: appState.conversationHistory.count) {
                        withAnimation {
                            if appState.isQuerying {
                                proxy.scrollTo("loading", anchor: .bottom)
                            } else if let last = appState.conversationHistory.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: appState.isQuerying) {
                        withAnimation {
                            if appState.isQuerying {
                                proxy.scrollTo("loading", anchor: .bottom)
                            } else if let last = appState.conversationHistory.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: appState.streamingAnswer) {
                        if !appState.streamingAnswer.isEmpty {
                            proxy.scrollTo("streaming", anchor: .bottom)
                        }
                    }
                }
            }

            // ── System prompt ─────────────────────────────────────────
            if isEditingPrompt {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("System Prompt", systemImage: "text.quote")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Done") {
                            if let id = appState.selectedCollectionId {
                                appState.updateSystemPrompt(for: id, prompt: promptDraft)
                            }
                            isEditingPrompt = false
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }

                    TextEditor(text: $promptDraft)
                        .font(.callout)
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2))
                        )

                    Text("Customize how the AI answers questions for this collection. Leave empty for the default behavior.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            // ── Query input ──────────────────────────────────────────
            HStack(spacing: 8) {
                Button {
                    if !isEditingPrompt {
                        promptDraft = appState.selectedCollection?.systemPrompt ?? ""
                    }
                    isEditingPrompt.toggle()
                } label: {
                    Image(systemName: "text.quote")
                        .font(.callout)
                        .foregroundColor(hasCustomPrompt ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("System Prompt")
                .disabled(!appState.canEditSelectedCollection)

                if !appState.conversationHistory.isEmpty {
                    Button {
                        appState.clearConversation()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("New Conversation")
                }

                TextField("Ask a question about your documents...", text: $state.queryText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isQueryFocused)
                    .onSubmit {
                        Task { await appState.runQuery() }
                    }
                    .disabled(appState.isQuerying)

                Button {
                    Task { await appState.runQuery() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(appState.queryText.trimmingCharacters(in: .whitespaces).isEmpty || appState.isQuerying)
            }
            .padding(12)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .onChange(of: appState.selectedCollectionId) {
            isEditingPrompt = false
        }
        .onChange(of: appState.focusQueryField) {
            if appState.focusQueryField {
                isQueryFocused = true
                appState.focusQueryField = false
            }
        }
    }

    private var hasCustomPrompt: Bool {
        appState.selectedCollection?.systemPrompt != nil
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: ConversationMessage
    let showSources: Bool
    @State private var showCopied = false

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            HStack(spacing: 6) {
                if message.role == .assistant {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
                Text(message.role == .user ? "You" : "Indexa")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                if message.role == .assistant {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showCopied = false
                        }
                    } label: {
                        Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundColor(showCopied ? .green : .secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Copy answer")
                }
            }

            if message.role == .user {
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(10)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownView(text: message.content)

                    // Source citations (hidden when sources are masked)
                    if !message.sources.isEmpty && showSources {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(message.sources.prefix(5)) { source in
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "doc.text")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(source.documentName)
                                                .font(.caption)
                                                .fontWeight(.medium)
                                            Text(String(source.chunk.content.prefix(120)))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Label("\(message.sources.count) source\(message.sources.count == 1 ? "" : "s")", systemImage: "link")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, 16)
        .id(message.id)
    }
}

// MARK: - Remote Query View

struct RemoteQueryView: View {
    @Environment(AppState.self) var appState
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 0) {
            if !appState.remoteConversationHistory.isEmpty || appState.isRemoteQuerying || appState.remoteQueryError != nil {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(appState.remoteConversationHistory) { message in
                                MessageBubble(message: message, showSources: false)
                            }

                            // Show remote sources below last assistant message
                            if !appState.remoteLastSources.isEmpty && !appState.remoteLastSourcesMasked {
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(appState.remoteLastSources.prefix(5)) { source in
                                            HStack(alignment: .top, spacing: 6) {
                                                Image(systemName: "doc.text")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(source.document)
                                                        .font(.caption)
                                                        .fontWeight(.medium)
                                                    Text(String(source.content.prefix(120)))
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                        .lineLimit(2)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.top, 4)
                                } label: {
                                    Label("\(appState.remoteLastSources.count) source\(appState.remoteLastSources.count == 1 ? "" : "s")", systemImage: "link")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 16)
                            }

                            if appState.isRemoteQuerying {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Querying remote server...")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .id("remote-loading")
                            }

                            if let error = appState.remoteQueryError {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(.orange)
                                    Text(error)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onChange(of: appState.remoteConversationHistory.count) {
                        withAnimation {
                            if let last = appState.remoteConversationHistory.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            if appState.remoteConversationHistory.isEmpty && !appState.isRemoteQuerying {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "cloud")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("Ask a question to query the remote collection")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }

            HStack(spacing: 8) {
                if !appState.remoteConversationHistory.isEmpty {
                    Button {
                        appState.clearRemoteConversation()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("New Conversation")
                }

                TextField("Ask a question...", text: $state.queryText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isQueryFocused)
                    .onSubmit {
                        Task { await appState.runRemoteQuery() }
                    }
                    .disabled(appState.isRemoteQuerying)

                Button {
                    Task { await appState.runRemoteQuery() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(appState.queryText.trimmingCharacters(in: .whitespaces).isEmpty || appState.isRemoteQuerying)
            }
            .padding(12)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
}
