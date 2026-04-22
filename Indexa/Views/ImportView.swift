import SwiftUI

/// Sheet for importing a `.indexa` bundle — shows manifest preview and optional password field.
struct ImportSheet: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) var dismiss

    let bundleURL: URL

    @State private var manifest: BundleManager.BundleManifest?
    @State private var password = ""
    @State private var needsPassword = false
    @State private var importDone = false
    @State private var errorMessage: String?
    @State private var importResult: BundleManager.ImportResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──────────────────────────────────────────────
            Text("Import Knowledge Base")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 4)

            Text(bundleURL.lastPathComponent)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            Divider()

            // ── Manifest preview ────────────────────────────────────
            if let manifest {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Bundle Info", systemImage: "info.circle")
                        .font(.callout)
                        .fontWeight(.semibold)

                    if manifest.isEncrypted {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.orange)
                            Text("This file is password-protected")
                                .font(.callout)
                        }
                    } else {
                        InfoRow(label: "Collections", value: "\(manifest.collectionCount)")
                        InfoRow(label: "Documents", value: "\(manifest.documentCount)")
                        InfoRow(label: "Chunks", value: "\(manifest.chunkCount)")
                        if let protectedCount = manifest.protectedCollectionCount, protectedCount > 0 {
                            InfoRow(label: "Protected", value: "\(protectedCount) of \(manifest.collectionCount)")
                        }
                        InfoRow(label: "Created", value: manifest.createdAt.formatted(date: .abbreviated, time: .shortened))

                        if let protectedCount = manifest.protectedCollectionCount, protectedCount > 0 {
                            Text("Protected collections can be queried immediately. The collection password is needed for full access.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(24)
            } else {
                ProgressView("Reading bundle...")
                    .padding(24)
            }

            // ── Password field (if encrypted) ────────────────────────
            if needsPassword {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter the file password to unlock this bundle:")
                        .font(.callout)

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(24)
            }

            // ── Error / success ──────────────────────────────────────
            if let error = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            if importDone, let result = importResult {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Imported \(result.collectionsImported) collection(s), \(result.documentsImported) document(s), \(result.chunksImported) chunk(s)")
                            .font(.callout)
                    }

                    if result.protectedCollectionCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                            Text("Includes \(result.protectedCollectionCount) protected collection(s) — password needed for full access")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                        .padding(.leading, 26)
                    }

                    if result.encryptedCollectionCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.shield.fill")
                                .font(.caption)
                            Text("Includes \(result.encryptedCollectionCount) encrypted collection(s) — chunk data is cryptographically protected")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                        .padding(.leading, 26)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            Spacer()

            Divider()

            // ── Actions ─────────────────────────────────────────────
            HStack {
                Spacer()

                if importDone {
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Import") {
                        performImport()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(needsPassword && password.isEmpty)
                    .disabled(appState.isImporting)
                }
            }
            .padding(16)
        }
        .frame(width: 440, height: 400)
        .task {
            loadManifest()
        }
    }

    private func loadManifest() {
        manifest = appState.peekBundle(at: bundleURL)
        needsPassword = manifest?.isEncrypted ?? false
    }

    private func performImport() {
        errorMessage = nil
        importDone = false

        let pwd = needsPassword ? password : nil
        appState.importBundle(from: bundleURL, password: pwd)

        if let error = appState.importError {
            errorMessage = error
        } else {
            importResult = appState.lastImportResult
            importDone = true
        }
    }
}

// MARK: - Helper row

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.callout)
                .fontWeight(.medium)
        }
    }
}
