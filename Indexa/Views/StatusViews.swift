import SwiftUI

// ── Brand colors ────────────────────────────────────────────────────────────

private let brandTeal = Color(red: 0.22, green: 0.75, blue: 0.91)
private let brandTealLight = Color(red: 0.33, green: 0.83, blue: 0.97)
private let brandDark = Color(red: 0.10, green: 0.11, blue: 0.14)

// ── Checking connection spinner ─────────────────────────────────────────────

struct ConnectionCheckingView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(brandTeal.opacity(0.1))
                    .frame(width: 80, height: 80)
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(brandTeal)
            }

            Text("Connecting to \(appState.activeProviderName)...")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
    }
}

// ── Connection failed ───────────────────────────────────────────────────────

struct ConnectionFailedView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "bolt.slash.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
            }

            Text("Cannot reach \(appState.activeProviderName)")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Make sure \(appState.activeProviderName) is running.\n\(appState.activeProvider?.chatServer.baseURL ?? "http://localhost:11434")")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button {
                    Task { await appState.checkProviderConnection() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(brandTeal)

                if appState.activeProviderName == "Ollama" {
                    Link(destination: URL(string: "https://ollama.com/download")!) {
                        Label("Download Ollama", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(40)
    }
}

// ── Missing embedding model ─────────────────────────────────────────────

struct MissingEmbedModelView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.yellow)
            }

            Text("Embedding Model Required")
                .font(.title3)
                .fontWeight(.semibold)

            let modelName = appState.activeProvider?.embedModel ?? "nomic-embed-text"

            Text("The model **\(modelName)** is needed for document indexing but isn't installed on your Ollama server.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if appState.isPullingModel {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(brandTeal)
                    Text(appState.pullModelStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 4)
            } else {
                VStack(spacing: 12) {
                    if appState.activeProvider?.embedServer.apiFormat == .ollama {
                        Button {
                            Task { await appState.pullEmbedModel() }
                        } label: {
                            Label("Download \(modelName)", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(brandTeal)
                    }

                    Text("Or run in Terminal:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("ollama pull \(modelName)")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(6)
                        .textSelection(.enabled)

                    Button {
                        Task { await appState.checkProviderConnection() }
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
            }
        }
        .padding(40)
    }
}

// ── Welcome screen (no collection selected) ─────────────────────────────────

struct WelcomeView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(spacing: 24) {
            // App icon representation
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.14, green: 0.16, blue: 0.20),
                                Color(red: 0.08, green: 0.09, blue: 0.11)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 80, height: 80)
                    .shadow(color: brandTeal.opacity(0.2), radius: 12, y: 4)

                Image(systemName: "book.pages.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [brandTealLight, brandTeal],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 8) {
                Text("Indexa")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Local Knowledge Base")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(appState.chatServerConnected == true ? Color.green : (appState.chatServerConnected == false ? Color.red : Color.gray))
                        .frame(width: 7, height: 7)
                    Text("LLM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(appState.embedServerConnected == true ? Color.green : (appState.embedServerConnected == false ? Color.red : Color.gray))
                        .frame(width: 7, height: 7)
                    Text("Embed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    FeaturePill(icon: "doc.text.fill", text: "Index documents")
                    FeaturePill(icon: "globe", text: "Crawl websites")
                }
                HStack(spacing: 8) {
                    FeaturePill(icon: "wand.and.stars", text: "AI distillation")
                    FeaturePill(icon: "magnifyingglass", text: "Smart queries")
                }
            }
            .padding(.top, 4)

            Text("Create a collection in the sidebar to get started.")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.top, 4)
        }
        .padding(40)
    }
}

private struct FeaturePill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(brandTeal)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(brandTeal.opacity(0.08))
        .cornerRadius(12)
    }
}
