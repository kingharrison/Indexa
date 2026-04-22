import SwiftUI
import AppKit

/// Translucent frosted-glass background using NSVisualEffectView
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

struct ContentView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            #if DEBUG
            HStack(spacing: 6) {
                Image(systemName: "hammer.fill")
                    .font(.caption2)
                Text("DEBUG BUILD")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .tracking(1.5)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Color.red)
            #endif

            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 220)

                Divider()

                // Main content area
                VStack {
                    if appState.chatServerConnected == nil && appState.embedServerConnected == nil {
                        ConnectionCheckingView()
                    } else if appState.chatServerConnected == false && appState.embedServerConnected == false {
                        ConnectionFailedView()
                    } else if appState.embedModelMissing {
                        MissingEmbedModelView()
                    } else if appState.selectedRemoteCollection != nil {
                        RemoteCollectionDetailView()
                    } else if appState.selectedCollectionId == nil {
                        if appState.collections.isEmpty {
                            WelcomeView()
                        } else {
                            CrossCollectionSearchView()
                        }
                    } else {
                        CollectionDetailView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(VisualEffectBackground())
        .task {
            await appState.bootstrap()
        }
        .sheet(isPresented: $state.showImportSheet) {
            if let url = appState.pendingImportURL {
                ImportSheet(bundleURL: url)
            }
        }
        .sheet(isPresented: $state.showSettingsSheet) {
            SettingsSheet()
        }
        .sheet(isPresented: $state.showPasswordPrompt) {
            if let id = appState.passwordPromptCollectionId {
                PasswordPromptSheet(collectionId: id)
            }
        }
        .sheet(isPresented: $state.showProtectionSheet) {
            if let id = appState.passwordPromptCollectionId {
                SetProtectionSheet(collectionId: id)
            }
        }
    }
}

// MARK: - Remote Collection Detail

struct RemoteCollectionDetailView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(spacing: 0) {
            if let remote = appState.selectedRemoteCollection,
               let collName = appState.remoteCollectionName(serverId: remote.serverId, collectionId: remote.collectionId),
               let serverName = appState.remoteServerName(for: remote.serverId) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "cloud.fill")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                            Text(collName)
                                .font(.title2)
                                .fontWeight(.bold)
                        }
                        Text("on \(serverName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text("Remote")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                Divider()
            }

            RemoteQueryView()
        }
    }
}
