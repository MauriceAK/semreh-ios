import SwiftUI
import WebKit
import OSLog

#if DEBUG
private let websiteLoginE2ELogger = Logger(
    subsystem: "com.mauriceak.semreh",
    category: "website-login-e2e"
)

/// DEBUG-only website-login diagnostics. Never include URLs, page contents,
/// headers, cookies, form values, credentials, or response bodies.
private func logWebsiteLoginStage(_ stage: String) {
    websiteLoginE2ELogger.info("website_login_stage=\(stage, privacy: .public)")
}

private func logWebsiteLoginFailureStage(_ stage: String, error: Error? = nil) {
    if let error {
        let nsError = error as NSError
        websiteLoginE2ELogger.info(
            "website_login_stage=\(stage, privacy: .public) error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code)"
        )
    } else {
        logWebsiteLoginStage(stage)
    }
}
#endif

struct WebsiteLoginWebView: UIViewRepresentable {
    let request: WebsiteLoginRequest
    let onBlocked: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(request: request, onBlocked: onBlocked)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Intentionally no user scripts or message handlers. The webpage owns
        // its login fields; the app has no DOM/form/cookie bridge.
        configuration.userContentController = WKUserContentController()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsLinkPreview = false
        context.coordinator.webView = webView
        context.coordinator.loadInitialPageIfNeeded()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let request: WebsiteLoginRequest
        private let policy: WebsiteLoginNavigationPolicy
        private let onBlocked: (String) -> Void
        weak var webView: WKWebView?
        private var didLoadInitialPage = false
        private var didReportFailure = false

        init(request: WebsiteLoginRequest, onBlocked: @escaping (String) -> Void) {
            self.request = request
            self.policy = request.navigationPolicy
            self.onBlocked = onBlocked
        }

        func loadInitialPageIfNeeded() {
            guard !didLoadInitialPage, let webView else { return }
            didLoadInitialPage = true
            #if DEBUG
            logWebsiteLoginStage("initial_load_start")
            #endif
            webView.load(URLRequest(url: request.initialURL))
        }

        func cleanup() {
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView = nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                #if DEBUG
                logWebsiteLoginFailureStage("navigation_missing_url")
                #endif
                reportFailure("The website navigation was blocked.")
                return
            }

            // A targetFrame of nil is a popup/new-window request. Popups remain
            // disabled; no hidden second browser view is created.
            guard navigationAction.targetFrame != nil else {
                decisionHandler(.cancel)
                #if DEBUG
                logWebsiteLoginFailureStage("navigation_popup_blocked")
                #endif
                reportFailure("This website login does not allow popups.")
                return
            }

            guard policy.allowsOIDCRedirect(url) else {
                if navigationAction.targetFrame?.isMainFrame == true,
                   let upgradedURL = policy.httpsUpgradeURL(url) {
                    // Keep plaintext off the wire while preserving a provider's
                    // normal redirect/callback path.
                    decisionHandler(.cancel)
                    #if DEBUG
                    logWebsiteLoginStage("navigation_http_upgraded")
                    #endif
                    webView.load(URLRequest(url: upgradedURL))
                    return
                }

                decisionHandler(.cancel)
                #if DEBUG
                logWebsiteLoginFailureStage(
                    navigationAction.targetFrame?.isMainFrame == false
                        ? "navigation_insecure_subframe_blocked"
                        : "navigation_insecure_blocked"
                )
                #endif
                // An insecure subframe is rejected without terminating the
                // entire login surface; a main-frame non-HTTP scheme remains a
                // user-visible failure.
                if navigationAction.targetFrame?.isMainFrame != false {
                    reportFailure("Only secure HTTPS website navigation is allowed.")
                }
                return
            }
            #if DEBUG
            logWebsiteLoginStage(
                "navigation_allowed frame=\(navigationAction.targetFrame?.isMainFrame == true ? "main" : "subframe")"
            )
            #endif
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let mimeType = navigationResponse.response.mimeType
            guard !policy.shouldBlockNavigationResponse(
                isForMainFrame: navigationResponse.isForMainFrame,
                canShowMIMEType: navigationResponse.canShowMIMEType,
                mimeType: mimeType
            ) else {
                decisionHandler(.cancel)
                #if DEBUG
                logWebsiteLoginFailureStage("response_main_mime_blocked")
                #endif
                reportFailure("Downloads are disabled for website login.")
                return
            }

            #if DEBUG
            logWebsiteLoginStage(
                "response_allowed frame=\(navigationResponse.isForMainFrame ? "main" : "subframe")"
            )
            #endif
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            #if DEBUG
            logWebsiteLoginFailureStage("navigation_failed", error: error)
            #endif
            guard WebsiteLoginNavigationPolicy.shouldReportNavigationFailure(error) else {
                return
            }
            reportFailure("The website could not be loaded.")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            #if DEBUG
            logWebsiteLoginFailureStage("provisional_navigation_failed", error: error)
            #endif
            guard WebsiteLoginNavigationPolicy.shouldReportNavigationFailure(error) else {
                return
            }
            reportFailure("The website could not be loaded.")
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Never create an invisible or unmanaged popup window.
            #if DEBUG
            logWebsiteLoginFailureStage("create_popup_blocked")
            #endif
            reportFailure("This website login does not allow popups.")
            return nil
        }

        @available(iOS 18.4, *)
        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            // No upload picker or file handoff is exposed to the page.
            #if DEBUG
            logWebsiteLoginFailureStage("upload_panel_blocked")
            #endif
            completionHandler([])
        }

        private func reportFailure(_ message: String) {
            guard !didReportFailure else { return }
            didReportFailure = true
            onBlocked(message)
        }
    }
}

struct WebsiteLoginRequestOverlay: View {
    let prompt: WebsiteLoginRequest
    let onResult: (WebsiteLoginResult) async -> Bool

    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var blockedMessage: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.shield")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sign in to \(prompt.displayName)")
                                .font(.headline)
                            Text(prompt.origin)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }

                    Text("Use the website’s own fields. Passwords can fill them directly; Semreh never reads your password or the page’s form values.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.regularMaterial)

                WebsiteLoginWebView(
                    request: prompt,
                    onBlocked: { message in
                        blockedMessage = message
                        Task { await submit(.failed) }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))

                if let message = blockedMessage ?? errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                }

                HStack(spacing: 12) {
                    Button("Cancel") {
                        Task { await submit(.cancelled) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting)

                    Button("Done") {
                        Task { await submit(.completed) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting)
                }
                .frame(maxWidth: .infinity)
                .padding(18)
                .background(.regularMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.vertical, 24)
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("website-login-overlay")
    }

    private func submit(_ result: WebsiteLoginResult) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        let succeeded = await onResult(result)
        if !succeeded {
            isSubmitting = false
            if errorMessage == nil {
                errorMessage = "The website login result was not accepted. Try again or cancel."
            }
        }
    }
}

struct NativeAuthBrowserStepPresentation: Equatable {
    let icon: String
    let guidance: String
    let isSupported: Bool
}

enum NativeAuthOverlayPresentation {
    static let browserOwnedKinds: [NativeAuthWireFieldKind] = [
        .ssoContinue,
        .emailMagicLink,
        .phoneVerification,
        .passkey,
        .securityKey,
        .captcha,
        .pushApproval,
        .deviceApproval
    ]

    static func browserStep(for kind: NativeAuthWireFieldKind) -> NativeAuthBrowserStepPresentation {
        browserStep(forRawKind: kind.rawValue)
    }

    static func browserStep(forRawKind rawKind: String) -> NativeAuthBrowserStepPresentation {
        switch rawKind {
        case NativeAuthWireFieldKind.ssoContinue.rawValue:
            return .init(
                icon: "person.crop.circle.badge.checkmark",
                guidance: "Continue with the identity provider in the browser. Do not enter provider credentials in this sheet.",
                isSupported: true
            )
        case NativeAuthWireFieldKind.emailMagicLink.rawValue:
            return .init(
                icon: "envelope.badge",
                guidance: "Open the sign-in link from your email in the same browser session. Do not paste the link here.",
                isSupported: true
            )
        case NativeAuthWireFieldKind.phoneVerification.rawValue:
            return .init(
                icon: "phone.badge.checkmark",
                guidance: "Complete the phone verification requested by the browser. Only enter a code here if a separate secure code field appears.",
                isSupported: true
            )
        case NativeAuthWireFieldKind.passkey.rawValue:
            return .init(
                icon: "person.badge.key",
                guidance: "Use the passkey prompt presented by the browser or operating system. Semreh cannot complete it in this sheet.",
                isSupported: true
            )
        case NativeAuthWireFieldKind.securityKey.rawValue:
            return .init(
                icon: "key.horizontal",
                guidance: "Follow the browser or system prompt to use your security key. Never enter a security-key PIN here unless a secure field is shown.",
                isSupported: true
            )
        case NativeAuthWireFieldKind.captcha.rawValue:
            return .init(
                icon: "checkmark.shield",
                guidance: "Complete the verification challenge in the browser. Semreh does not solve or relay CAPTCHA responses.",
                isSupported: true
            )
        case NativeAuthWireFieldKind.pushApproval.rawValue:
            return .init(
                icon: "bell.badge",
                guidance: "Approve the sign-in in the provider’s trusted app or device, then return to the browser.",
                isSupported: true
            )
        case NativeAuthWireFieldKind.deviceApproval.rawValue:
            return .init(
                icon: "checkmark.circle.badge.questionmark",
                guidance: "Approve the device where the provider directs you, verify the request details there, then return to the browser.",
                isSupported: true
            )
        default:
            return .init(
                icon: "hand.raised.fill",
                guidance: "This step is not supported in the app. For your security, complete it only in the browser and do not enter sensitive values here.",
                isSupported: false
            )
        }
    }

    static func safeDisplayHost(from origin: String?) -> String {
        guard let origin else { return "this site" }
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "this site" }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              components.user == nil,
              components.password == nil,
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              !host.contains("@") else {
            return "this site"
        }
        return host.lowercased()
    }
}

struct NativeAuthComponentOverlay: View {
    let prompt: NativeAuthPromptState
    let errorMessage: String?
    let onSubmit: ([String: String], NativeAuthWireComponent) async -> Bool
    let onCancel: () async -> Bool

    @State private var values: [String: String] = [:]
    @State private var inFlightAction: InFlightAction?
    @State private var localErrorMessage: String?
    @AccessibilityFocusState private var isErrorFocused: Bool

    private enum InFlightAction: Equatable {
        case submit
        case cancel

        var status: String {
            switch self {
            case .submit: return "Submitting securely…"
            case .cancel: return "Cancelling…"
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .submit: return "native-auth-submit-progress"
            case .cancel: return "native-auth-cancel-progress"
            }
        }
    }

    private var inputComponents: [NativeAuthWireComponent] {
        prompt.inputComponents
    }

    private var browserOwnedComponents: [NativeAuthWireComponent] {
        let inputIDs = Set(inputComponents.map(\.id))
        let submitID = prompt.submitComponent?.id
        return prompt.components.filter {
            !inputIDs.contains($0.id)
                && $0.id != submitID
                && $0.kind.rawValue != "cancel"
        }
    }

    private var canSubmit: Bool {
        guard prompt.submitComponent != nil, !inputComponents.isEmpty else { return false }
        return inputComponents.allSatisfy {
            !(values[$0.field]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    private var displayedErrorMessage: String? {
        if let localErrorMessage, !localErrorMessage.isEmpty { return localErrorMessage }
        if let errorMessage, !errorMessage.isEmpty { return errorMessage }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            header
                            Divider()
                            ForEach(inputComponents) { component in
                                nativeField(component)
                            }
                            ForEach(browserOwnedComponents) { component in
                                browserOwnedRow(component)
                            }
                            if let errorMessage = displayedErrorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel("Error: \(errorMessage)")
                                    .accessibilityIdentifier("native-auth-error")
                                    .accessibilityFocused($isErrorFocused)
                            }
                        }
                        .padding(18)
                    }
                    Divider()
                    footer
                }
                .frame(maxWidth: 520, maxHeight: min(680, max(0, geometry.size.height - 24)))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .accessibilityIdentifier("native-auth-component-overlay")
        .onAppear {
            if displayedErrorMessage != nil {
                isErrorFocused = true
            }
        }
        .onDisappear {
            clearLocalState()
        }
        .onChange(of: prompt.id) { _, _ in
            clearLocalState()
        }
        .onChange(of: displayedErrorMessage) { _, newValue in
            if newValue != nil {
                isErrorFocused = true
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title2.weight(.semibold))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Secure sign-in")
                        .font(.headline)
                    Text("The browser requested information for \(NativeAuthOverlayPresentation.safeDisplayHost(from: prompt.components.first?.providerOrigin))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Text("Enter it here. Semreh sends the values directly to the active browser session; they are not added to chat.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func nativeField(_ component: NativeAuthWireComponent) -> some View {
        let fieldBinding = Binding<String>(
            get: { values[component.field] ?? "" },
            set: { values[component.field] = $0 }
        )
        VStack(alignment: .leading, spacing: 6) {
            Text(component.label)
                .font(.subheadline.weight(.medium))
            if isSecure(component.kind) {
                SecureField(component.label, text: fieldBinding)
                    .textContentType(textContentType(for: component.kind))
                    .nativeAuthFieldSurface()
                    .accessibilityIdentifier("native-auth-field-\(component.field)")
            } else {
                TextField(component.label, text: fieldBinding)
                    .textContentType(textContentType(for: component.kind))
                    .keyboardType(keyboardType(for: component.kind))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .nativeAuthFieldSurface()
                    .accessibilityIdentifier("native-auth-field-\(component.field)")
            }
        }
    }

    private func browserOwnedRow(_ component: NativeAuthWireComponent) -> some View {
        let presentation = NativeAuthOverlayPresentation.browserStep(for: component.kind)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: presentation.icon)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(component.label)
                    .font(.subheadline.weight(.medium))
                Text(presentation.guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("native-auth-browser-step-\(component.kind.rawValue)")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .leading) {
                Color.clear.frame(height: 20)
                if let inFlightAction {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(inFlightAction.status)
                            .font(.footnote.weight(.medium))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(inFlightAction.accessibilityIdentifier)
                }
            }
            .accessibilityHidden(inFlightAction == nil)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    cancelButton
                    Spacer(minLength: 0)
                    submitButton
                }
                VStack(spacing: 10) {
                    submitButton
                    cancelButton
                }
            }
        }
        .padding(18)
    }

    private var cancelButton: some View {
        Button("Cancel") {
            guard inFlightAction == nil else { return }
            inFlightAction = .cancel
            localErrorMessage = nil
            Task {
                if !(await onCancel()) {
                    inFlightAction = nil
                    localErrorMessage = "The cancellation was not accepted. Try again."
                }
            }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, minHeight: 44)
        .disabled(inFlightAction != nil)
        .accessibilityIdentifier("native-auth-cancel")
    }

    private var submitButton: some View {
        Button(prompt.submitComponent?.label ?? "Continue") {
            guard let submitComponent = prompt.submitComponent,
                  canSubmit,
                  inFlightAction == nil else { return }
            inFlightAction = .submit
            localErrorMessage = nil
            let submittedValues = values
            Task {
                if !(await onSubmit(submittedValues, submitComponent)) {
                    inFlightAction = nil
                    localErrorMessage = "The secure sign-in information was not accepted. Review the fields and try again."
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity, minHeight: 44)
        .disabled(!canSubmit || inFlightAction != nil)
        .accessibilityIdentifier("native-auth-submit")
    }

    private func isSecure(_ kind: NativeAuthWireFieldKind) -> Bool {
        kind == .secret || kind == .recoveryCode
    }

    private func textContentType(for kind: NativeAuthWireFieldKind) -> UITextContentType? {
        switch kind {
        case .identifier: return .username
        case .secret, .recoveryCode: return .password
        case .oneTimeCode: return .oneTimeCode
        default: return nil
        }
    }

    private func keyboardType(for kind: NativeAuthWireFieldKind) -> UIKeyboardType {
        switch kind {
        case .oneTimeCode: return .numberPad
        default: return .default
        }
    }

    private func clearLocalState() {
        values.removeAll(keepingCapacity: false)
        inFlightAction = nil
        localErrorMessage = nil
        isErrorFocused = false
    }
}

private extension View {
    func nativeAuthFieldSurface() -> some View {
        self
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

