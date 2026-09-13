import SwiftUI

enum OnboardingConnectField: Hashable {
    case serverURL
    case username
    case password
}

struct OnboardingConnectPage: View {
    @Bindable var viewModel: OnboardingViewModel
    @Bindable var authManager: AuthManager
    @FocusState.Binding var focusedField: OnboardingConnectField?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette
    @State private var isShowingAdvanced = false
    @State private var isShowingPairingScanner = false
    @State private var pairingPendingScannerDismissal: PairingImport?
    @State private var pairingToReview: PairingImport?
    @State private var focusesServerAfterScannerDismissal = false

    private var canSubmit: Bool {
        !viewModel.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitConnection() {
        guard canSubmit else { return }
        Task { await viewModel.connect(authManager: authManager) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette))

                    Text("Enter the exact HTTPS Tailscale Serve URL your agent returned, for example `https://server.tailnet-name.ts.net`.")
                        .font(.footnote)
                        .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: palette))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    OnboardingField(systemImage: "link", title: String(localized: "Server URL")) {
                        ZStack(alignment: .leading) {
                            if viewModel.serverURLString.isEmpty {
                                Text(verbatim: "https://server.tailnet-name.ts.net")
                                    .foregroundStyle(OnboardingTheme.tertiaryText(for: colorScheme, palette: palette))
                                    .allowsHitTesting(false)
                            }

                            TextField("", text: $viewModel.serverURLString)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .accessibilityIdentifier("onboarding-server-url")
                                .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette))
                                .submitLabel(.go)
                                .tint(OnboardingTheme.action(for: colorScheme, palette: palette))
                                .focused($focusedField, equals: .serverURL)
                                .onSubmit(submitConnection)
                        }
                    }

                    Button {
                        focusedField = nil
                        isShowingPairingScanner = true
                    } label: {
                        Label("Scan setup code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                    .disabled(viewModel.isWorking)
                    .accessibilityHint("Scans a secret-free server address for review. It does not connect or sign in.")

                    if viewModel.isUsernameRequired {
                        OnboardingField(systemImage: "person.fill", title: String(localized: "Username")) {
                            TextField(
                                "",
                                text: $viewModel.username,
                                prompt: Text("Server username")
                                    .foregroundStyle(OnboardingTheme.tertiaryText(for: colorScheme, palette: palette))
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .accessibilityIdentifier("onboarding-username")
                            .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette))
                            .submitLabel(.next)
                            .tint(OnboardingTheme.action(for: colorScheme, palette: palette))
                            .focused($focusedField, equals: .username)
                            .onSubmit {
                                if viewModel.isPasswordRequired {
                                    focusedField = .password
                                } else {
                                    submitConnection()
                                }
                            }
                        }
                    }

                    if viewModel.isPasswordRequired {
                        OnboardingField(systemImage: "key.fill", title: String(localized: "Password")) {
                            SecureField(
                                "",
                                text: $viewModel.password,
                                prompt: Text("Server password")
                                    .foregroundStyle(OnboardingTheme.tertiaryText(for: colorScheme, palette: palette))
                            )
                            .textContentType(.password)
                            .accessibilityIdentifier("onboarding-password")
                            .submitLabel(.go)
                            .focused($focusedField, equals: .password)
                            .onSubmit(submitConnection)
                        }
                    }
                }

                DisclosureGroup(isExpanded: $isShowingAdvanced) {
                    CustomHeadersEditor(
                        headers: $viewModel.customHeaders,
                        style: .onboarding(for: colorScheme, palette: palette)
                    )
                        .padding(.top, 10)
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette).opacity(0.86))
                }
                .tint(OnboardingTheme.action(for: colorScheme, palette: palette).opacity(0.72))

                if viewModel.isWorking {
                    OnboardingStatusBanner(
                        text: String(localized: "Checking server..."),
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: OnboardingTheme.action(for: colorScheme, palette: palette),
                        showsProgress: true
                    )
                }

                if let connectionMessage = viewModel.connectionMessage {
                    OnboardingStatusBanner(
                        text: connectionMessage,
                        systemImage: "checkmark.circle.fill",
                        tint: SemrehVisualTheme.statusPositive(for: .semreh)
                    )
                }

                if let errorMessage = viewModel.errorMessage {
                    OnboardingStatusBanner(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: SemrehVisualTheme.statusCritical(for: .semreh)
                    )
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, dynamicTypeSize.isAccessibilitySize ? 18 : 24)
            .padding(.bottom, 92)
        }
        .scrollBounceBehavior(.basedOnSize)
        .sheet(isPresented: $isShowingPairingScanner, onDismiss: finishPairingScannerDismissal) {
            PairingCameraView(
                accepted: { pairing in
                    pairingPendingScannerDismissal = pairing
                    focusesServerAfterScannerDismissal = false
                    isShowingPairingScanner = false
                },
                manual: {
                    pairingPendingScannerDismissal = nil
                    focusesServerAfterScannerDismissal = true
                    isShowingPairingScanner = false
                },
                cancel: {
                    pairingPendingScannerDismissal = nil
                    focusesServerAfterScannerDismissal = false
                    isShowingPairingScanner = false
                }
            )
            .presentationDetents([.large])
        }
        .sheet(item: $pairingToReview) { pairing in
            PairingOriginReviewView(
                pairing: pairing,
                confirm: {
                    viewModel.applyConfirmedPairingOrigin(pairing)
                    pairingToReview = nil
                    focusedField = .serverURL
                },
                cancel: { pairingToReview = nil }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func finishPairingScannerDismissal() {
        if let pairingPendingScannerDismissal {
            pairingToReview = pairingPendingScannerDismissal
            self.pairingPendingScannerDismissal = nil
        } else if focusesServerAfterScannerDismissal {
            focusedField = .serverURL
        }
        focusesServerAfterScannerDismissal = false
    }
}

private struct PairingOriginReviewView: View {
    let pairing: PairingImport
    let confirm: () -> Void
    let cancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        NavigationStack {
            ZStack {
                SemrehBackdrop().ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Review server address", systemImage: "qrcode.viewfinder")
                            .font(.title3.weight(.bold))
                        Text(pairing.origin.absoluteString)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text("Compare the complete address with your server or administrator. A QR code does not prove who owns a server. Confirming only fills the existing connection form.")
                            .font(.footnote)
                            .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: palette))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Use this address", action: confirm)
                            .buttonStyle(OnboardingPrimaryButtonStyle())
                        Button("Cancel", role: .cancel, action: cancel)
                            .buttonStyle(OnboardingSecondaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
            }
            .navigationTitle("Setup Code")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
