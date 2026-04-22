import SwiftUI

// MARK: - Set Protection Sheet

/// Sheet for setting or changing password protection on a collection.
struct SetProtectionSheet: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) var dismiss

    let collectionId: UUID

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var selectedLevel: ProtectionLevel = .readOnly
    @State private var error: String? = nil

    private var collection: Collection? {
        appState.collections.first(where: { $0.id == collectionId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(collection?.isProtected == true ? "Change Protection" : "Set Protection")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            if let name = collection?.name {
                Text("Protect \"\(name)\"")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Protection level picker
            Text("Protection Level")
                .font(.headline)
                .fontWeight(.semibold)

            ForEach(ProtectionLevel.allCases, id: \.self) { level in
                HStack(spacing: 12) {
                    Image(systemName: level == selectedLevel ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(level == selectedLevel ? .accentColor : .secondary)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(level.displayName)
                            .font(.callout)
                            .fontWeight(.medium)
                        Text(level.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedLevel = level
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Password fields
            Text("Password")
                .font(.headline)
                .fontWeight(.semibold)

            SecureField("Enter password", text: $password)
                .textFieldStyle(.roundedBorder)

            SecureField("Confirm password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Text("The password grants full access to edit and view all contents.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("Collection data will be encrypted. If you forget your password, the data cannot be recovered.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Divider()

            // Actions
            HStack {
                if collection?.isProtected == true {
                    Button("Remove Protection", role: .destructive) {
                        appState.removeProtection(collectionId: collectionId)
                        dismiss()
                    }
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Set Protection") {
                    applyProtection()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || confirmPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            if let level = collection?.protectionLevel {
                selectedLevel = level
            }
        }
    }

    private func applyProtection() {
        guard !password.isEmpty else {
            error = "Password cannot be empty."
            return
        }
        guard password == confirmPassword else {
            error = "Passwords do not match."
            return
        }
        guard password.count >= 8 else {
            error = "Password must be at least 8 characters."
            return
        }

        appState.setProtection(collectionId: collectionId, password: password, level: selectedLevel)
        dismiss()
    }
}

// MARK: - Password Prompt Sheet

/// Modal sheet for unlocking a protected collection.
struct PasswordPromptSheet: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) var dismiss

    let collectionId: UUID

    @State private var password = ""
    @State private var error: String? = nil
    @State private var attempts = 0

    private var collection: Collection? {
        appState.collections.first(where: { $0.id == collectionId })
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange.opacity(0.7), .orange.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            if let name = collection?.name {
                Text("Unlock \"\(name)\"")
                    .font(.title3)
                    .fontWeight(.semibold)
            }

            if collection?.protectionLevel == .sourcesMasked {
                Text("Enter the password to enable querying.\nSources will remain hidden.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Enter the password to get full access.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { tryUnlock() }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Unlock") {
                    tryUnlock()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 360)
    }

    private func tryUnlock() {
        if appState.unlockCollection(collectionId, password: password) {
            dismiss()
        } else {
            attempts += 1
            error = "Incorrect password. (\(attempts) attempt\(attempts == 1 ? "" : "s"))"
            password = ""
        }
    }
}

