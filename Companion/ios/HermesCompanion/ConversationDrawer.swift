import SwiftUI

struct ConversationDrawer: View {
    var store: AppStore
    let onClose: () -> Void
    let onDestination: (ChatView.ChatSheet) -> Void
    let onSelect: (ChatSession) -> Void
    @State private var search = ""
    @State private var creating = false
    @AccessibilityFocusState private var mainChatFocused: Bool

    private var sessions: [ChatSession] {
        store.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.grant?.host.profile ?? "Hermes")
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 16)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 4) {
                        Button(action: onClose) {
                            destination("Main chat", systemImage: "bubble", selected: true)
                        }.accessibilityIdentifier("drawerMainChat")
                            .accessibilityFocused($mainChatFocused)
                        Button { onDestination(.activity) } label: {
                            destination("Follow-ups & updates", systemImage: "bell")
                        }.accessibilityIdentifier("drawerActivity")
                        Button { onDestination(.controls) } label: {
                            destination("Model & reasoning", systemImage: "slider.horizontal.3")
                        }.accessibilityIdentifier("drawerControls")
                    }
                    Divider().padding(.horizontal, 12).padding(.vertical, 8)
                    Text("Conversations").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).accessibilityAddTraits(.isHeader)
                    if sessions.isEmpty {
                        Text(search.isEmpty ? "No conversations yet" : "No conversations found")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(12).accessibilityIdentifier("drawerEmpty")
                    }
                    LazyVStack(spacing: 4) {
                        ForEach(sessions) { session in
                            let selected = session.id == store.selectedSession?.id
                            let title = session.title.isEmpty ? "Untitled conversation" : session.title
                            Button { onSelect(session) } label: {
                                HStack(spacing: 8) {
                                    Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    if selected { Image(systemName: "checkmark").font(.caption) }
                                }.padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 44)
                                    .background(selected ? .white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 14))
                            }.accessibilityLabel(title)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityIdentifier("conversation-" + session.id)
                        }
                    }
                }.padding(.horizontal, 12).padding(.bottom, 16)
            }.scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("drawerContent")
            HStack(spacing: 8) {
                Button { onDestination(.settings) } label: {
                    Image(systemName: "gearshape").font(.system(size: 19)).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }.accessibilityLabel("Settings").accessibilityIdentifier("drawerSettings")
                TextField("Search", text: $search)
                    .font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(.white.opacity(0.07), in: Capsule())
                    .accessibilityLabel("Search conversation titles").accessibilityIdentifier("conversationSearch")
                Button {
                    guard !creating else { return }
                    creating = true
                    Task {
                        let id = await store.newSession()
                        creating = false
                        if id != nil { onClose() }
                    }
                } label: {
                    Group {
                        if creating { ProgressView() }
                        else { Image(systemName: "square.and.pencil").font(.system(size: 19)) }
                    }.frame(width: 44, height: 44).contentShape(Rectangle())
                }.disabled(creating || !store.canCommand || store.isSending)
                    .accessibilityLabel(creating ? "Creating conversation" : "New conversation")
                    .accessibilityIdentifier("newConversation")
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .background(Color(white: 0.025).ignoresSafeArea(.container))
        .accessibilityAction(.escape) { onClose() }
        .onAppear { mainChatFocused = true }
    }

    private func destination(_ title: String, systemImage: String, selected: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 22)).frame(width: 26)
            Text(title).font(.body).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 48)
            .background(selected ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 24))
            .contentShape(Rectangle())
    }
}

struct ChatPanelShape: Shape {
    var cornerRadius: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: CGRect(x: rect.minX, y: rect.minY - topInset, width: rect.width, height: rect.height + topInset + bottomInset), cornerRadius: cornerRadius)
    }
}
