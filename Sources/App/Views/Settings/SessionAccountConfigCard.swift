import SwiftUI
import Domain

/// Optional "sign in with the CLI" flow for providers whose sessions MyMeter can
/// create itself (Grok). When present, the add sheet leads with a sign-in button
/// and demotes manual path entry to an advanced option.
struct SessionLoginSupport {
    let buttonTitle: String
    let help: String
    let waitingMessage: String
    /// Signs in a brand-new account with the given label and registers it.
    let signIn: (_ label: String) async throws -> Void
    /// Re-runs sign-in for an existing account (e.g. after the session expired).
    let signInAgain: (_ account: ProviderAccount) async throws -> Void
}

/// Settings card for registering extra local sessions (Cursor user-data-dir, Grok home).
struct SessionAccountConfigCard<Provider: MultiAccountProvider>: View {
    let provider: Provider
    let title: String
    let subtitle: String
    let pathPlaceholder: String
    let pathHelp: String
    var loginSupport: SessionLoginSupport? = nil
    let onAdd: (String, String) -> Void
    let onRemove: (String) -> Void

    @Environment(\.appTheme) private var theme
    @State private var isExpanded = true
    @State private var showAddSheet = false
    @State private var showAdvancedPath = false
    @State private var newLabel = ""
    @State private var newPath = ""
    @State private var loginTask: Task<Void, Never>?
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var reloginAccountId: String?
    @State private var reloginError: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Divider()
                .background(theme.glassBorder)
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 10) {
                Text(pathHelp)
                    .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)

                ForEach(provider.accounts, id: \.id) { account in
                    accountRow(account)
                }

                if let reloginError {
                    Text(reloginError)
                        .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.statusCritical)
                }

                addAccountButton
            }
        } label: {
            header
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                .fill(theme.cardGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                        .stroke(theme.glassBorder, lineWidth: 1)
                )
        )
        .sheet(isPresented: $showAddSheet, onDismiss: cancelSignIn) {
            addSheet
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(theme.accentGradient)
                    .frame(width: 32, height: 32)

                Image(systemName: "person.2.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)

                Text(subtitle)
                    .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer()
        }
    }

    private func accountRow(_ account: ProviderAccount) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        account.accountId == provider.activeAccount.accountId
                            ? theme.accentPrimary
                            : theme.glassBackground
                    )
                    .frame(width: 24, height: 24)

                Text(account.initialLetter)
                    .font(.system(size: 10, weight: .bold, design: theme.fontDesign))
                    .foregroundStyle(
                        account.accountId == provider.activeAccount.accountId
                            ? .white
                            : theme.textSecondary
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.system(size: 12, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                if let email = account.email {
                    Text(email)
                        .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                } else if account.isDefault {
                    Text("Local session")
                        .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.textTertiary)
                }
            }

            Spacer()

            if loginSupport != nil {
                reloginButton(account)
            }

            if account.accountId == provider.activeAccount.accountId {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.statusHealthy)
            } else {
                Button {
                    _ = provider.switchAccount(to: account.accountId)
                } label: {
                    Text("Switch")
                        .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.accentPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .stroke(theme.accentPrimary.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            if !account.isDefault {
                Button {
                    onRemove(account.accountId)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func reloginButton(_ account: ProviderAccount) -> some View {
        if reloginAccountId == account.accountId {
            ProgressView()
                .controlSize(.small)
                .help("Waiting for sign-in to finish in Terminal")
        } else {
            Button {
                startRelogin(account)
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(reloginAccountId != nil)
            .help("Sign in again with the CLI")
        }
    }

    private var addAccountButton: some View {
        Button {
            newLabel = ""
            newPath = ""
            signInError = nil
            showAdvancedPath = false
            showAddSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12, weight: .semibold))

                Text("Add Account")
                    .font(.system(size: 11, weight: .medium, design: theme.fontDesign))
            }
            .foregroundStyle(theme.accentPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.accentPrimary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
        }
        .buttonStyle(.plain)
    }

    private var trimmedLabel: String {
        newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPath: String {
        newPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Account")
                .font(.system(size: 16, weight: .bold, design: theme.fontDesign))

            VStack(alignment: .leading, spacing: 6) {
                Text("LABEL")
                    .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.5)

                TextField("Work", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSigningIn)
            }

            if let loginSupport {
                signInSection(loginSupport)

                DisclosureGroup(isExpanded: $showAdvancedPath) {
                    pathSection
                        .padding(.top, 8)
                } label: {
                    Text("Advanced: use an existing session")
                        .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.textSecondary)
                }
                .disabled(isSigningIn)
            } else {
                pathSection
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showAddSheet = false
                }
                if loginSupport == nil || showAdvancedPath {
                    Button("Add") {
                        guard !trimmedLabel.isEmpty, !trimmedPath.isEmpty else { return }
                        onAdd(trimmedLabel, trimmedPath)
                        showAddSheet = false
                    }
                    .disabled(trimmedLabel.isEmpty || trimmedPath.isEmpty || isSigningIn)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func signInSection(_ support: SessionLoginSupport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                startSignIn(support)
            } label: {
                HStack(spacing: 8) {
                    if isSigningIn {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(isSigningIn ? "Waiting for sign-in…" : support.buttonTitle)
                        .font(.system(size: 12, weight: .semibold, design: theme.fontDesign))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmedLabel.isEmpty || isSigningIn)
            .keyboardShortcut(showAdvancedPath ? nil : .defaultAction)

            Text(isSigningIn ? support.waitingMessage : support.help)
                .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let signInError {
                Text(signInError)
                    .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.statusCritical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PATH")
                .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                .foregroundStyle(theme.textSecondary)
                .tracking(0.5)

            HStack(spacing: 8) {
                TextField(pathPlaceholder, text: $newPath)
                    .textFieldStyle(.roundedBorder)

                Button("Browse") {
                    browseForPath()
                }
            }

            Text(pathHelp)
                .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sign-in flow

    private func startSignIn(_ support: SessionLoginSupport) {
        let label = trimmedLabel
        guard !label.isEmpty, !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        loginTask = Task {
            do {
                try await support.signIn(label)
                guard !Task.isCancelled else { return }
                isSigningIn = false
                showAddSheet = false
            } catch {
                guard !Task.isCancelled else { return }
                isSigningIn = false
                signInError = error.localizedDescription
            }
        }
    }

    private func cancelSignIn() {
        loginTask?.cancel()
        loginTask = nil
        isSigningIn = false
    }

    private func startRelogin(_ account: ProviderAccount) {
        guard let loginSupport, reloginAccountId == nil else { return }
        reloginAccountId = account.accountId
        reloginError = nil
        Task {
            do {
                try await loginSupport.signInAgain(account)
            } catch {
                reloginError = "\(account.displayName): \(error.localizedDescription)"
            }
            reloginAccountId = nil
        }
    }

    private func browseForPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            newPath = url.path
        }
    }
}
