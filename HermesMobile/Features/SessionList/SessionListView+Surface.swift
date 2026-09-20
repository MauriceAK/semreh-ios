import SwiftUI
import SwiftData

extension SessionListView {

    var sessionListSurface: some View {
        ZStack(alignment: .bottom) {
            SemrehBackdrop()
                .ignoresSafeArea()

            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if usesShellChrome {
                        shellSearchBar
                            .padding(.horizontal, 18)
                            .padding(.bottom, 10)
                    }
                }

            if !usesShellChrome, !isSearchingSessions {
                newSessionButton
                    .padding(.trailing, 24)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

        }
        .navigationTitle(usesShellChrome ? "Sessions" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if usesShellChrome {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil", action: onNewChat)
                    Button(AppShellSettingsAction.accessibilityLabel, systemImage: AppShellSettingsAction.systemImage, action: onAccount)
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    var regularWidthDetail: some View {
        if let destination = navigationState.destination {
            navigationDestination(destination)
        } else {
            ContentUnavailableView {
                Label("Select a Chat", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Choose a session from the sidebar or start a new chat.")
            } actions: {
                Button("New Chat", action: openNewChat)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

}
