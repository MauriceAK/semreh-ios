import SwiftUI

struct OnboardingView: View {
    @Bindable var authManager: AuthManager
    @State private var viewModel: OnboardingViewModel
    @State private var currentPage: Int
    @State private var showsSetupHelp = false
    @FocusState private var focusedField: OnboardingConnectField?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    init(authManager: AuthManager, savedServer: URL? = nil) {
        self.authManager = authManager
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

    var body: some View {
        ZStack {
            SemrehBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    OnboardingWelcomePage()
                        .tag(0)

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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isEditingConnectionField)
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

            if !isEditingConnectionField {
                Button("Need help connecting?") {
                    focusedField = nil
                    showsSetupHelp = true
                }
                .font(SemrehTypography.label)
                .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: palette))
                .buttonStyle(.plain)
                .padding(.vertical, 8)
                .accessibilityHint("Opens optional guidance for your existing Hermes server.")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background {
            OnboardingTheme.panel(for: colorScheme)
                .opacity(colorScheme == .dark ? 0.84 : 0.94)
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [
                            .clear,
                            OnboardingTheme.action(for: colorScheme).opacity(0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 34)
                    .offset(y: -34)
                }
        }
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
        withAnimation(.easeInOut(duration: 0.3)) {
            currentPage += 1
        }
    }

}

#Preview {
    OnboardingView(authManager: AuthManager())
}
