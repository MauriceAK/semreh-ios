import SwiftUI

/// The three primary surfaces in the Semreh mobile shell.
enum AppShellSurface: String, CaseIterable, Hashable, Identifiable {
    case sessions
    case control
    case you

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions:
            "Sessions"
        case .control:
            "Control"
        case .you:
            "You"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions:
            "bubble.left.and.bubble.right.fill"
        case .control:
            "slider.horizontal.3"
        case .you:
            "person.crop.circle.fill"
        }
    }

    var showsPrimaryAction: Bool {
        switch self {
        case .sessions:
            true
        case .control, .you:
            false
        }
    }
}

enum AppShellOrganizerPolicy {
    static let projectsEnabled = true
}

@MainActor
struct AppShellView: View {
    @Bindable var authManager: AuthManager
    let server: URL
    @Binding var selectedSurface: AppShellSurface
    @Binding var pendingSharedImport: SharedImport?
    @Binding var pendingDeepLinkedSessionID: String?
    @Binding var pendingNewChatRequest: NewChatRequest?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isSessionConversationPresented = false
    @State private var isControlDestinationPresented = false
    @State private var controlSurfaceVisitID = 0
    @State private var sessionSurfaceVisitID = 0
    @State private var capsuleMotion: AppShellCapsuleMotion

    init(
        authManager: AuthManager,
        server: URL,
        selectedSurface: Binding<AppShellSurface>,
        pendingSharedImport: Binding<SharedImport?>,
        pendingDeepLinkedSessionID: Binding<String?>,
        pendingNewChatRequest: Binding<NewChatRequest?>
    ) {
        self.authManager = authManager
        self.server = server
        self._selectedSurface = selectedSurface
        self._pendingSharedImport = pendingSharedImport
        self._pendingDeepLinkedSessionID = pendingDeepLinkedSessionID
        self._pendingNewChatRequest = pendingNewChatRequest
        let initialIndex = CGFloat(AppShellSurface.allCases.firstIndex(of: selectedSurface.wrappedValue) ?? 0)
        self._capsuleMotion = State(initialValue: AppShellCapsuleMotion(settledAt: initialIndex))
    }

    var body: some View {
        surfaceContent
            .safeAreaInset(edge: .top, spacing: 0) {
                if AppShellChromePolicy.showsTopBar(
                    surface: selectedSurface,
                    isSessionConversationPresented: isSessionConversationPresented,
                    isControlDestinationPresented: isControlDestinationPresented
                ) {
                    AppShellTopBar(
                        surface: selectedSurface,
                        onPrimaryAction: handlePrimaryAction
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if AppShellChromePolicy.showsBottomBar(
                    isConversationPresented: isSessionConversationPresented,
                    isControlDestinationPresented: isControlDestinationPresented
                ) {
                    AppShellBottomBar(
                        selection: $selectedSurface,
                        motion: capsuleMotion,
                        onSelect: selectSurface
                    )
                }
            }
            .onChange(of: selectedSurface) { oldValue, newValue in
                guard oldValue != newValue else { return }
                capsuleMotion = capsuleMotion.reconciled(
                    to: surfaceIndex(newValue),
                    reduceMotion: reduceMotion,
                    at: Date()
                )
                isControlDestinationPresented = false
                controlSurfaceVisitID += 1
                if newValue == .sessions {
                    sessionSurfaceVisitID += 1
                }
            }
            .onChange(of: reduceMotion) { _, isEnabled in
                guard isEnabled else { return }
                capsuleMotion = capsuleMotion.reconciled(
                    to: surfaceIndex(selectedSurface),
                    reduceMotion: true,
                    at: Date()
                )
            }
    }

    @ViewBuilder
    private var surfaceContent: some View {
        switch selectedSurface {
        case .sessions:
            SessionListView(
                authManager: authManager,
                server: server,
                projectsEnabled: AppShellOrganizerPolicy.projectsEnabled,
                pendingSharedImport: $pendingSharedImport,
                pendingDeepLinkedSessionID: $pendingDeepLinkedSessionID,
                requestedNewChat: $pendingNewChatRequest,
                usesShellChrome: true,
                shellSurfaceVisitID: sessionSurfaceVisitID,
                onConversationVisibilityChanged: { isPresented in
                    // This state owns the shell safe area. Keep it synchronous
                    // while New Chat transfers a focused composer.
                    isSessionConversationPresented = isPresented
                }
            )

        case .control:
            ControlView(
                authManager: authManager,
                server: server,
                projectsEnabled: AppShellOrganizerPolicy.projectsEnabled,
                isActive: selectedSurface == .control,
                onNestedDestinationVisibilityChanged: { isPresented in
                    isControlDestinationPresented = isPresented
                }
            )
            .id(controlSurfaceVisitID)

        case .you:
            YouView(authManager: authManager, server: server)
        }
    }

    private func handlePrimaryAction() {
        switch selectedSurface {
        case .sessions:
            pendingNewChatRequest = NewChatRequest()
        case .control, .you:
            break
        }
    }

    private func selectSurface(_ surface: AppShellSurface) {
        guard surface != selectedSurface else { return }

        let now = Date()
        let target = surfaceIndex(surface)
        capsuleMotion = reduceMotion
            ? AppShellCapsuleMotion(settledAt: target)
            : capsuleMotion.retargeted(to: target, at: now)
        selectedSurface = surface
    }

    private func surfaceIndex(_ surface: AppShellSurface) -> CGFloat {
        CGFloat(AppShellSurface.allCases.firstIndex(of: surface) ?? 0)
    }
}

enum AppShellChromePolicy {
    static func showsTopBar(
        surface: AppShellSurface,
        isSessionConversationPresented: Bool,
        isControlDestinationPresented: Bool
    ) -> Bool {
        surface != .you
            && !isSessionConversationPresented
            && !(surface == .control && isControlDestinationPresented)
    }

    static func showsBottomBar(
        isConversationPresented: Bool,
        isControlDestinationPresented: Bool
    ) -> Bool {
        !isConversationPresented && !isControlDestinationPresented
    }

    static func showsBottomBar(isConversationPresented: Bool) -> Bool {
        !isConversationPresented
    }
}

struct ControlNavigationState: Equatable {
    var destination: SessionListUtilityDestination?

    var isNestedDestinationPresented: Bool {
        destination != nil
    }

    mutating func select(_ destination: SessionListUtilityDestination) {
        self.destination = destination
    }

    mutating func resetForSurfaceDeactivation() {
        destination = nil
    }
}

private struct AppShellTopBar: View {
    let surface: AppShellSurface
    let onPrimaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)

                if surface.showsPrimaryAction {
                    AppShellCircularButton(
                        systemImage: "plus",
                        accessibilityLabel: "New session",
                        action: onPrimaryAction
                    )
                }
            }
            .frame(minHeight: 48)

            Text(surface.title)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background {
            LinearGradient(
                colors: [
                    Color(.systemBackground).opacity(0.96),
                    Color(.systemBackground).opacity(0.76),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }
}

private struct AppShellCircularButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(AppShellCircularButtonStyle(reduceMotion: reduceMotion))
        .adaptiveGlass(
            .regular,
            isInteractive: true,
            fallbackMaterial: reduceTransparency ? .regularMaterial : .ultraThinMaterial,
            in: Circle()
        )
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct AppShellCircularButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.93 : 1))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14),
                value: configuration.isPressed
            )
    }
}

struct AppShellBottomBar: View {
    @Binding var selection: AppShellSurface
    let motion: AppShellCapsuleMotion
    let onSelect: (AppShellSurface) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AdaptiveGlassContainer(spacing: 12) {
            ZStack(alignment: .leading) {
                AppShellSelectionCapsule(motion: motion, reduceMotion: reduceMotion)

                HStack(spacing: AppShellBottomBarMotion.tabSpacing) {
                    ForEach(AppShellSurface.allCases) { surface in
                        AppShellTabButton(
                            surface: surface,
                            isSelected: selection == surface,
                            reduceMotion: reduceMotion
                        ) { onSelect(surface) }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: 390)
            .frame(height: 76)
            .adaptiveGlass(
                .regular,
                isInteractive: false,
                fallbackMaterial: .ultraThinMaterial,
                in: Capsule()
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .background(Color.clear)
    }
}

private enum AppShellBottomBarMotion {
    static let tabSpacing: CGFloat = 6
    static let glideDuration: Double = 0.28

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.20, 0.85, 0.20, 1.0, duration: glideDuration)
    }
}

private struct AppShellSelectionCapsule: View {
    let motion: AppShellCapsuleMotion
    let reduceMotion: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { proxy in
            let tabWidth = (proxy.size.width - AppShellBottomBarMotion.tabSpacing * 2) / 3
            let timelineDates = motion.timelineDates(reduceMotion: reduceMotion, now: Date())
            TimelineView(.explicit(timelineDates)) { context in
                let frame = motion.frame(at: context.date, tabWidth: tabWidth)
                let inFlightHighlight = reduceTransparency
                    ? 0.16
                    : frame.highlight

                Capsule()
                    .adaptiveGlass(
                        .regular,
                        isInteractive: false,
                        tint: reduceTransparency ? nil : Color.white.opacity(0.16),
                        fallbackMaterial: reduceTransparency ? .regularMaterial : .ultraThinMaterial,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(reduceTransparency ? 0.34 : inFlightHighlight),
                                        Color.white.opacity(0.06),
                                        Color.white.opacity(reduceTransparency ? 0.28 : inFlightHighlight * 0.78)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.25
                            )
                    }
                    .overlay {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(reduceTransparency ? 0.14 : inFlightHighlight * 0.82),
                                        .clear,
                                        Color.white.opacity(reduceTransparency ? 0.06 : inFlightHighlight * 0.30)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    .shadow(
                        color: Color.white.opacity(reduceTransparency ? 0 : 0.14),
                        radius: 2,
                        y: 1
                    )
                    .frame(width: frame.width, height: 64)
                    .offset(x: frame.left)
            }
        }
        .allowsHitTesting(false)
    }
}

struct AppShellCapsuleMotionFrame: Equatable {
    let left: CGFloat
    let right: CGFloat
    let width: CGFloat
    let center: CGFloat
    let position: CGFloat
    let travel: CGFloat
    let highlight: CGFloat
    let isSettled: Bool
}

struct AppShellCapsuleMotion: Equatable {
    let start: CGFloat
    let target: CGFloat
    let startedAt: Date
    let initialDeformation: CGFloat
    let initialLeftPull: CGFloat
    let initialRightPull: CGFloat
    let initialCompression: CGFloat
    let initialHighlight: CGFloat

    static let travelDuration: TimeInterval = AppShellBottomBarMotion.glideDuration
    static let settleDuration: TimeInterval = 0.0
    static let totalDuration: TimeInterval = travelDuration + settleDuration
    static let retargetBlendDuration: TimeInterval = 0.10

    init(
        start: CGFloat,
        target: CGFloat,
        startedAt: Date,
        initialDeformation: CGFloat = 0,
        initialLeftPull: CGFloat = 0,
        initialRightPull: CGFloat = 0,
        initialCompression: CGFloat = 0,
        initialHighlight: CGFloat = 0.14
    ) {
        self.start = start
        self.target = target
        self.startedAt = startedAt
        self.initialDeformation = initialDeformation
        self.initialLeftPull = initialLeftPull
        self.initialRightPull = initialRightPull
        self.initialCompression = initialCompression
        self.initialHighlight = initialHighlight
    }

    init(settledAt position: CGFloat) {
        self.init(start: position, target: position, startedAt: Date())
    }

    func retargeted(to newTarget: CGFloat, at date: Date) -> Self {
        let currentDeformation = deformation(at: date)
        let currentDirection: CGFloat = target >= start ? 1 : -1
        let directionBlend = directionBlend(at: date)
        let desiredLeftPull = currentDirection > 0 ? 0.09 * currentDeformation : 0.26 * currentDeformation
        let desiredRightPull = currentDirection > 0 ? 0.26 * currentDeformation : 0.09 * currentDeformation
        let currentLeftPull = interpolated(initialLeftPull, toward: desiredLeftPull, by: directionBlend)
        let currentRightPull = interpolated(initialRightPull, toward: desiredRightPull, by: directionBlend)
        return Self(
            start: position(at: date),
            target: newTarget,
            startedAt: date,
            initialDeformation: currentDeformation,
            initialLeftPull: currentLeftPull,
            initialRightPull: currentRightPull,
            initialCompression: 0,
            initialHighlight: highlight(at: date)
        )
    }

    func reconciled(to newTarget: CGFloat, reduceMotion: Bool, at date: Date) -> Self {
        if reduceMotion {
            return Self(start: newTarget, target: newTarget, startedAt: date)
        }
        guard target != newTarget else { return self }
        return retargeted(to: newTarget, at: date)
    }

    func travelProgress(at date: Date) -> CGFloat {
        guard start != target else { return 1 }
        return min(max(date.timeIntervalSince(startedAt) / Self.travelDuration, 0), 1)
    }

    func timelineDates(reduceMotion: Bool, now: Date) -> [Date] {
        let end = startedAt.addingTimeInterval(Self.totalDuration)
        let settledEnd = Date(timeIntervalSinceReferenceDate: end.timeIntervalSinceReferenceDate.nextUp)
        let hasVisualMotion = start != target
            || initialDeformation != 0
            || initialLeftPull != 0
            || initialRightPull != 0
            || initialCompression != 0
            || initialHighlight != 0.14
        guard !reduceMotion, hasVisualMotion, now < settledEnd else { return [now] }

        let interval = 1.0 / 60.0
        var dates = [now]
        var next = now.addingTimeInterval(interval)
        while next < settledEnd {
            dates.append(next)
            next = next.addingTimeInterval(interval)
        }
        dates.append(settledEnd)
        return dates
    }

    func position(at date: Date) -> CGFloat {
        let progress = travelProgress(at: date)
        let easedProgress = cubicProgress(progress)
        return start + (target - start) * easedProgress
    }

    func deformation(at date: Date) -> CGFloat {
        guard start != target else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let localProgress = min(max(elapsed / Self.travelDuration, 0), 1)
        let progress = travelProgress(at: date)
        let activeDeformation = sin(.pi * pow(progress, 0.82))
        return max(initialDeformation * (1 - localProgress), activeDeformation)
    }

    func frame(at date: Date, tabWidth: CGFloat) -> AppShellCapsuleMotionFrame {
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let linearProgress = travelProgress(at: date)
        let normalizedPosition = position(at: date)
        let direction: CGFloat = target >= start ? 1 : -1
        let deformation = deformation(at: date)
        let directionBlend = directionBlend(at: date)
        let desiredLeftPull = direction > 0 ? 0.09 * deformation : 0.26 * deformation
        let desiredRightPull = direction > 0 ? 0.26 * deformation : 0.09 * deformation
        let leftPull = tabWidth * interpolated(initialLeftPull, toward: desiredLeftPull, by: directionBlend)
        let rightPull = tabWidth * interpolated(initialRightPull, toward: desiredRightPull, by: directionBlend)
        let travel = normalizedPosition * (tabWidth + AppShellBottomBarMotion.tabSpacing)
        let left = travel - leftPull
        let right = travel + tabWidth + rightPull
        let width = right - left
        let highlight = interpolated(
            initialHighlight,
            toward: 0.14 + 0.22 * sin(.pi * pow(linearProgress, 0.82)),
            by: directionBlend
        )
        return AppShellCapsuleMotionFrame(
            left: left,
            right: right,
            width: width,
            center: left + width / 2,
            position: normalizedPosition,
            travel: linearProgress,
            highlight: highlight,
            isSettled: elapsed >= Self.totalDuration
        )
    }

    private func highlight(at date: Date) -> CGFloat {
        let blend = directionBlend(at: date)
        let progress = travelProgress(at: date)
        return interpolated(
            initialHighlight,
            toward: 0.14 + 0.22 * sin(.pi * pow(progress, 0.82)),
            by: blend
        )
    }

    private func directionBlend(at date: Date) -> CGFloat {
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        return min(max(elapsed / Self.retargetBlendDuration, 0), 1)
    }

    private func settleCompression(at date: Date) -> CGFloat {
        0
    }

    private func interpolated(_ initial: CGFloat, toward target: CGFloat, by progress: CGFloat) -> CGFloat {
        initial + (target - initial) * progress
    }

    private func cubicProgress(_ progress: CGFloat) -> CGFloat {
        // Fast, immediate takeoff matching touch and haptics, followed by
        // a smooth, critically damped deceleration into the target slot.
        let firstControl: CGFloat = 0.52
        let secondControl: CGFloat = 1.0
        let inverse = 1 - progress
        return 3 * inverse * inverse * progress * firstControl
            + 3 * inverse * progress * progress * secondControl
            + progress * progress * progress
    }
}

private struct AppShellTabButton: View {
    let surface: AppShellSurface
    let isSelected: Bool
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: surface.systemImage)
                    .font(.system(size: 20, weight: isSelected ? .semibold : .medium))
                    .scaleEffect(reduceMotion ? 1.0 : (isSelected ? 1.05 : 1.0))
                Text(surface.title)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(surface.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(AppShellBottomBarMotion.animation(reduceMotion: reduceMotion), value: isSelected)
    }
}

struct TeamsActionPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(SemrehVisualTheme.energy())
                    .frame(width: 84, height: 84)
                    .background(SemrehVisualTheme.energy().opacity(0.14), in: Circle())

                Text("Team setup is next")
                    .font(.title2.weight(.bold))

                Text("The Teams room is ready as a placeholder. The plus action will later add a teammate or Hermes agent.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(SemrehVisualTheme.energy())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .background(SemrehBackdrop().ignoresSafeArea())
            .navigationTitle("Teams")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    AppShellBottomBar(
        selection: .constant(.sessions),
        motion: AppShellCapsuleMotion(settledAt: 0),
        onSelect: { _ in }
    )
        .padding()
        .background(Color.black)
}
