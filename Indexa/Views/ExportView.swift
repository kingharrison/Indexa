import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Opens a native NSSavePanel with an embedded accessory view for collection selection and encryption.
/// No SwiftUI sheets — just one panel that does everything.
enum ExportPanel {

    @MainActor
    static func show(appState: AppState) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("com.kingharrison.indexa.bundle") ?? UTType(filenameExtension: "indexa") ?? .data]
        panel.nameFieldStringValue = "knowledge-base.indexa"
        panel.message = "Export knowledge base bundle"
        panel.prompt = "Export"

        // Build the accessory view
        let accessoryModel = ExportAccessoryModel(collections: appState.collections, selectedId: appState.selectedCollectionId)
        let accessoryView = ExportAccessoryView(model: accessoryModel)
        let hostingController = NSHostingController(rootView: accessoryView)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 400, height: 360)
        panel.accessoryView = hostingController.view
        panel.isExtensionHidden = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Perform the export
        let selectedIds = Array(accessoryModel.selectedCollectionIds)

        guard !selectedIds.isEmpty else { return }

        // Block export if encryption is required but password is missing/mismatched
        if accessoryModel.useEncryption {
            guard !accessoryModel.password.isEmpty else {
                appState.alertMessage = "A password is required to export protected collections."
                return
            }
            guard accessoryModel.password == accessoryModel.confirmPassword else {
                appState.alertMessage = "Export passwords do not match."
                return
            }
        }

        let password = accessoryModel.useEncryption ? accessoryModel.password : nil
        appState.exportBundle(collectionIds: selectedIds, password: password, to: url)
    }
}

// MARK: - Accessory view model (shared mutable state between SwiftUI and the panel)

@Observable
class ExportAccessoryModel {
    var selectedCollectionIds: Set<UUID>
    var collections: [Collection]
    var useEncryption = false
    var password = ""
    var confirmPassword = ""

    init(collections: [Collection], selectedId: UUID?) {
        self.collections = collections
        self.selectedCollectionIds = selectedId != nil ? [selectedId!] : []

        // Force encryption if the initially selected collection is protected
        if let id = selectedId,
           let col = collections.first(where: { $0.id == id }),
           col.isProtected {
            self.useEncryption = true
        }
    }

    var passwordsMatch: Bool {
        !useEncryption || (password == confirmPassword && !password.isEmpty)
    }

    /// True when any selected collection has password protection.
    var hasProtectedSelection: Bool {
        collections.contains(where: { $0.isProtected && selectedCollectionIds.contains($0.id) })
    }
}

// MARK: - SwiftUI accessory view embedded in the save panel

private struct ExportAccessoryView: View {
    @Bindable var model: ExportAccessoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── Collection selection ─────────────────────────
            HStack {
                Text("Collections to export")
                    .font(.callout)
                    .fontWeight(.semibold)

                Spacer()

                Button("All") {
                    model.selectedCollectionIds = Set(model.collections.map(\.id))
                }
                .font(.caption)
                Button("None") {
                    model.selectedCollectionIds.removeAll()
                }
                .font(.caption)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.collections) { collection in
                        HStack(spacing: 8) {
                            Image(systemName: model.selectedCollectionIds.contains(collection.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(model.selectedCollectionIds.contains(collection.id) ? .accentColor : .secondary)

                            Text(collection.name)
                                .font(.callout)

                            if let level = collection.protectionLevel {
                                HStack(spacing: 3) {
                                    Image(systemName: "lock.fill")
                                    Text(level.displayName)
                                }
                                .font(.caption2)
                                .foregroundColor(.orange)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if model.selectedCollectionIds.contains(collection.id) {
                                model.selectedCollectionIds.remove(collection.id)
                            } else {
                                model.selectedCollectionIds.insert(collection.id)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 100)

            // Protection preservation note
            if model.collections.contains(where: { $0.isProtected && model.selectedCollectionIds.contains($0.id) }) {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                    Text("Protected collections keep their restrictions when exported")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                .padding(.top, 2)
            }

            Divider()

            // ── File encryption ────────────────────────────────
            Toggle("Require password to open file", isOn: $model.useEncryption)
                .font(.callout)
                .disabled(model.hasProtectedSelection)
                .onChange(of: model.hasProtectedSelection) { _, required in
                    if required { model.useEncryption = true }
                }
                .onChange(of: model.selectedCollectionIds) { _, _ in
                    if model.hasProtectedSelection { model.useEncryption = true }
                }

            if model.hasProtectedSelection {
                Text("Required — protects collections from being opened unprotected on older versions of Indexa.")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                Text("This locks the .indexa file itself. Separate from collection protection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if model.useEncryption {
                HStack(spacing: 8) {
                    SecureField("Password", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Confirm", text: $model.confirmPassword)
                        .textFieldStyle(.roundedBorder)
                }

                if !model.password.isEmpty && !model.confirmPassword.isEmpty && model.password != model.confirmPassword {
                    Text("Passwords don't match")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
