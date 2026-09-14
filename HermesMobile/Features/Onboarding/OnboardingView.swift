import SwiftUI

struct OnboardingView: View {
    @Bindable var authManager: AuthManager
    @State private var viewModel: OnboardingViewModel
    @State private var currentPage: Int
    @State private var showsSetupHelp = false
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue
    @AppStorage(AppAccent.storageKey) private var appAccentRawValue = AppAccent.defaultValue.rawValue
    @FocusState private var focusedField: OnboardingConnectField?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let hasSavedServer: Bool

    init(authManager: AuthManager, savedServer: URL? = nil) {
        self.authManager = authManager
        self.hasSavedServer = savedServer != nil
        // A known server means a re-login, not first-run setup: skip the
        // intro pager and land on the connect page with the server filled in.
        _viewModel = State(
            initialValue: OnboardingViewModel(
                savedServer: savedServer,
                // Headers survive a session-expiry sign-out, so prefill them on
                // re-login behind a proxy (empty on first run / full sign-out).
                savedHeaders: authManager.currentCustomHeaders,
                initialErrorMessage: savedServer == nil ? nil : authManager.lastErrorMessage
            )
        )
        _currentPage = State(
            initialValue: OnboardingFlowPolicy.initialPage(hasSavedServer: savedServer != nil)
        )
    }

    private var isEditingConnectionField: Bool {
        currentPage == OnboardingFlowPolicy.connectPageIndex && focusedField != nil
    }

    private var canSubmitConnection: Bool {
        !viewModel.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedTheme: AppTheme {
        AppTheme.storedValue(appThemeRawValue)
    }

    private var selectedAccent: AppAccent {
        AppAccent.storedValue(appAccentRawValue)
    }

    private var onboardingColorScheme: ColorScheme {
        selectedTheme.colorScheme ?? colorScheme
    }

    var body: some View {
        ZStack {
            SemrehBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                TabView(selection: $currentPage) {
                    OnboardingWelcomePage()
                        .tag(OnboardingFlowPolicy.welcomePageIndex)

                    OnboardingAppearancePage()
                        .tag(OnboardingFlowPolicy.appearancePageIndex)

                    OnboardingConnectPage(
                        viewModel: viewModel,
                        authManager: authManager,
                        focusedField: $focusedField
                    )
                    .tag(OnboardingFlowPolicy.connectPageIndex)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomBar
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditingConnectionField {
                keyboardActionBar
                    .transition(
                        reduceMotion
                            ? .identity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: isEditingConnectionField
        )
        .onChange(of: currentPage) { oldPage, newPage in
            handlePageChange(from: oldPage, to: newPage)
        }
        .sheet(isPresented: $showsSetupHelp) {
            NavigationStack {
                OnboardingAgentPromptPage()
                    .background(SemrehBackdrop())
                    .navigationTitle("Connection help")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsSetupHelp = false }
                        }
                    }
            }
        }
        // Onboarding intentionally stays on Semreh's cream/charcoal palette,
        // including for users upgrading from a legacy named palette. The
        // selected accent and appearance are still the real persisted settings.
        .environment(\.appColorPalette, .semreh)
        .environment(\.appAccent, selectedAccent)
        .preferredColorScheme(selectedTheme.colorScheme)
    }

    private var topBar: some View {
        HStack {
            if OnboardingFlowPolicy.shouldShowBackButton(
                for: currentPage,
                hasSavedServer: hasSavedServer
            ) {
                Button(action: goBack) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .foregroundStyle(
                    OnboardingTheme.primaryText(
                        for: onboardingColorScheme,
                        palette: .semreh
                    ).opacity(0.86)
                )
                .buttonStyle(.plain)
                .accessibilityHint("Returns to the previous onboarding step.")
            }

            Spacer(minLength: 0)
        }
        .frame(height: 52)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            OnboardingPageIndicator(
                pageCount: OnboardingFlowPolicy.pageCount,
                currentPage: currentPage
            )

            if currentPage == OnboardingFlowPolicy.connectPageIndex {
                if !isEditingConnectionField {
                    connectActionButtons
                }
            } else {
                Button(action: handlePrimaryAction) {
                    Text(OnboardingFlowPolicy.primaryButtonTitle(for: currentPage))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .accessibilityLabel(OnboardingFlowPolicy.primaryButtonTitle(for: currentPage))

            }

            if currentPage == OnboardingFlowPolicy.connectPageIndex && !isEditingConnectionField {
                Button("Need help connecting?") {
                    focusedField = nil
                    showsSetupHelp = true
                }
                .font(SemrehTypography.label)
                .foregroundStyle(
                    OnboardingTheme.secondaryText(
                        for: onboardingColorScheme,
                        palette: .semreh
                    )
                )
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityHint("Opens optional guidance for your existing Hermes server.")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(
            SemrehVisualTheme.canvas(for: onboardingColorScheme, palette: .semreh)
        )
    }

    private var keyboardActionBar: some View {
        VStack(spacing: 10) {
            connectActionButtons
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var connectActionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                testConnectionButton
                connectButton
            }

            VStack(spacing: 10) {
                testConnectionButton
                connectButton
            }
        }
    }

    private var testConnectionButton: some View {
        Button {
            Task { await viewModel.testConnection(authManager: authManager) }
        } label: {
            Label("Test Connection", systemImage: "network")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(OnboardingSecondaryButtonStyle())
        .disabled(viewModel.isWorking || !canSubmitConnection)
    }

    private var connectButton: some View {
        Button {
            Task { await viewModel.connect(authManager: authManager) }
        } label: {
            Label("Connect", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(OnboardingPrimaryButtonStyle())
        .disabled(viewModel.isWorking || !canSubmitConnection)
    }

    private func handlePrimaryAction() {
        if currentPage < OnboardingFlowPolicy.connectPageIndex {
            advanceToNextPage()
        }
    }

    private func handlePageChange(from _: Int, to newPage: Int) {
        if OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(newPage) {
            focusedField = nil
        }
    }

    private func advanceToNextPage() {
        guard currentPage < OnboardingFlowPolicy.connectPageIndex else { return }
        let nextPage = currentPage + 1
        if reduceMotion {
            currentPage = nextPage
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentPage = nextPage
            }
        }
    }

    private func goBack() {
        guard let previousPage = OnboardingFlowPolicy.previousPage(
            for: currentPage,
            hasSavedServer: hasSavedServer
        ) else {
            return
        }

        if reduceMotion {
            currentPage = previousPage
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentPage = previousPage
            }
        }
    }

}

#Preview {
    OnboardingView(authManager: AuthManager())
}
