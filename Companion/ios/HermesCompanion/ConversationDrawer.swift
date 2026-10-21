import SwiftUI

struct ConversationDrawer: View {
    var store: AppStore
    let onClose: () -> Void
    let onDestination: (ChatView.ChatSheet) -> Void
    let onSelect: (ChatSession) -> Void
    @State private var search = ""
    @State private var creating = false
    @State private var footerHeight: CGFloat = 60
    @Environment(\.dynamicTypeSize) private var typeSize
    @AccessibilityFocusState private var mainChatFocused: Bool

    private var sessions: [ChatSession] {
        store.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(store.grant?.host.profile ?? "Hermes")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                    .accessibilityAddTraits(.isHeader)
                sectionTitle("TABS", identifier: "drawerTabsHeading")
                    .padding(.bottom, 8)
                VStack(spacing: 2) {
                    Button(action: onClose) {
                        destination("Main chat", systemImage: "bubble", selected: true)
                    }.accessibilityIdentifier("drawerMainChat")
                        .accessibilityHint("Return to the current conversation")
                        .accessibilityFocused($mainChatFocused)
                    Button { onDestination(.activity) } label: {
                        destination("Follow-ups & updates", systemImage: "bell")
                    }.accessibilityIdentifier("drawerActivity")
                    Button { onDestination(.controls) } label: {
                        destination("Model & reasoning", systemImage: "slider.horizontal.3")
                    }.accessibilityIdentifier("drawerControls")
                }
                Divider().overlay(.white.opacity(0.08))
                    .padding(.horizontal, 12).padding(.vertical, 18)
                sectionTitle("SIDE CHATS", identifier: "drawerSideChatsHeading")
                    .padding(.bottom, 8)
                if sessions.isEmpty {
                    Text(search.isEmpty ? "No conversations yet" : "No conversations found")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(12).accessibilityIdentifier("drawerEmpty")
                }
                LazyVStack(spacing: 0) {
                    ForEach(sessions) { session in
                        let selected = session.id == store.selectedSession?.id
                        let title = session.title.isEmpty ? "Untitled conversation" : session.title
                        Button { onSelect(session) } label: {
                            Text(title)
                                .font(.body.weight(selected ? .medium : .regular))
                                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 11)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }.accessibilityLabel(title)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("conversation-" + session.id)
                    }
                }
            }.padding(.horizontal, 10).padding(.bottom, footerHeight + 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("drawerContent")
        .clipped()
        .overlay(alignment: .bottom) {
            footer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .background(Color.black.ignoresSafeArea(.container))
        .accessibilityAction(.escape) { onClose() }
        .onAppear { mainChatFocused = true }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { onDestination(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 19))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }.modifier(ChatGlass(cornerRadius: 22))
                .accessibilityLabel("Settings").accessibilityIdentifier("drawerSettings")
            TextField("Search", text: $search)
                .font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 14).frame(minHeight: 44)
                .modifier(ChatGlass(cornerRadius: 22))
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
                }.frame(width: 44, height: 44).contentShape(Circle())
            }.modifier(ChatGlass(cornerRadius: 22))
                .disabled(creating || !store.canCommand || store.isSending)
                .accessibilityLabel(creating ? "Creating conversation" : "New conversation")
                .accessibilityIdentifier("newConversation")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .padding(.top, -16)
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    private func sectionTitle(_ title: String, identifier: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier)
    }

    private func destination(_ title: String, systemImage: String, selected: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 21)).frame(width: 26)
            Text(title).font(.body).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 12).padding(.vertical, 9).frame(minHeight: 44)
            .background(selected ? Color(white: 0.17) : .clear, in: Capsule())
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
