import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var store: AppStore
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photos: [PhotosPickerItem] = []
    private var queuesAttachments: Bool { store.isWorking && !store.attachments.isEmpty }
    private var primaryStops: Bool { store.isWorking && !store.hasDraftContent }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if !store.attachments.isEmpty {
                    if let issue = store.attachmentDrafts.persistenceIssue {
                        Text(issue).font(.caption2).foregroundStyle(.orange).padding(.horizontal, 8)
                    }
                    if queuesAttachments {
                        Text("Sends after the current task").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(store.attachments) { item in AttachmentChip(item: item, retry: { store.retryAttachmentUpload(item) }, remove: { store.removeAttachment(item) }).disabled(store.isSending) }
                        }.padding(.horizontal, 6)
                    }.scrollIndicators(.hidden).padding(.top, 6)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    Menu {
                        Button("Photos", systemImage: "photo") { focused = false; showPhotos = true }
                        Button("Files", systemImage: "doc") { focused = false; showFiles = true }
                        Text("4 files · 5 MB each · text 128 KB")
                    } label: {
                        Image(systemName: "plus").font(.system(size: 20)).foregroundStyle(Color.blue).frame(width: 44, height: 44).contentShape(Rectangle())
                    }.disabled(store.isSending || store.attachments.count >= AttachmentDrafts.maxCount)
                        .accessibilityLabel("Add attachment").accessibilityIdentifier("addAttachment")
                    TextField(store.isWorking ? "Add direction…" : "Message Hermes…", text: Binding(get: { store.draft }, set: { ChatPerformance.shared.mark(.draftChanged); store.draft = $0 }), axis: .vertical)
                        .lineLimit(1...(typeSize.isAccessibilitySize ? 2 : 6)).font(.body).focused($focused).padding(.vertical, 10).frame(minHeight: 44)
                        .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                        .accessibilityIdentifier("composer")
                    if store.isWorking && !primaryStops {
                        Button { Task { await store.execute(.init(kind: "interrupt")) } } label: {
                            Image(systemName: "stop.fill").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary).frame(width: 44, height: 44)
                        }.disabled(!store.canCommand || store.isStopping)
                            .accessibilityLabel("Stop agent").accessibilityIdentifier("stopAgent")
                    }
                    Button {
                        Task { if primaryStops { await store.execute(.init(kind: "interrupt")) } else { await store.send() } }
                    } label: {
                        Group {
                            if primaryStops ? store.isStopping : store.isSending { ProgressView().tint(primaryStops ? .black : .white) }
                            else { Image(systemName: primaryStops ? "stop.fill" : "arrow.up").font(.system(size: primaryStops ? 12 : 17, weight: .semibold)) }
                        }.foregroundStyle(primaryStops ? Color.black : Color.white)
                            .frame(width: 36, height: 36)
                            .background(primaryStops ? Color.white.opacity(0.9) : store.canSendDraft ? Color.blue : Color.white.opacity(0.09), in: Circle())
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.disabled(!store.canCommand || (primaryStops ? store.isStopping : store.isSending) || (!primaryStops && (!store.canSendDraft || store.isStopping)))
                        .accessibilityLabel(primaryStops ? "Stop agent" : queuesAttachments ? "Queue message" : store.isWorking ? "Send direction" : "Send message")
                        .accessibilityIdentifier(primaryStops ? "stopAgent" : "sendMessage")
                }
            }.padding(6).frame(minHeight: 56)
                .modifier(ChatGlass(cornerRadius: 28))
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
        }
        .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: max(1, AttachmentDrafts.maxCount - store.attachments.count), matching: .images)
        .onChange(of: photos) { _, selected in
            let imports = selected.compactMap { item in store.beginAttachmentImport(name: "Photo").map { (item, $0) } }
            photos = []
            Task {
                for (item, context) in imports {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw ClientError.server(0, "attachment_import", "This photo could not be opened.") }
                        let payload = try await AttachmentImport.photo(data, directory: context.drafts.directory, id: context.id)
                        store.finishAttachmentImport(context, result: .success(payload))
                    } catch { store.finishAttachmentImport(context, result: .failure(error)) }
                }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { Task { await store.importFile(url) } }
            } else if case .failure(let error) = result { store.error = error.localizedDescription }
            focused = true
        }
        .onChange(of: showPhotos) { _, showing in if !showing { focused = true } }
    }
}

struct ChatGlass: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color(white: 0.16), in: shape)
                .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }
}

private struct AttachmentChip: View {
    let item: DraftAttachment
    let retry: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingIssue = false
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            if let url = item.payload?.previewURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Group { if case .importing = item.state { ProgressView() } else { Image(systemName: "doc").font(.system(size: 22)) } }.frame(width: 28, height: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.caption.weight(.medium)).lineLimit(1)
                if issue != nil {
                    Button { showingIssue = true } label: {
                        Label("Details", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Attachment details for " + item.name).accessibilityIdentifier("attachmentDetails-" + item.id.uuidString)
                }
                else if let payload = item.payload { Text(ByteCountFormatter.string(fromByteCount: Int64(payload.byteCount), countStyle: .file)).font(.caption2).foregroundStyle(.secondary) }
                else { Text("Importing…").font(.caption2).foregroundStyle(.secondary) }
            }
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("Remove " + item.name).accessibilityIdentifier("removeAttachment-" + item.id.uuidString)
        }.padding(.leading, 10).padding(.vertical, 6).frame(width: typeSize.isAccessibilitySize ? 300 : 224).frame(minHeight: 56).fixedSize(horizontal: false, vertical: true)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .alert("Attachment needs attention", isPresented: $showingIssue) {
                if item.payload != nil, !item.uncertainUpload {
                    Button("Retry on send", action: retry)
                }
                Button("Remove file", role: .destructive, action: remove)
                Button("Cancel", role: .cancel) {}
            } message: { Text(issue ?? "") }
    }
    private var issue: String? {
        if case .failed(let message) = item.state { return message + "\n\nRemove this attachment and choose it again." }
        guard let message = item.uploadError else { return nil }
        if item.uncertainUpload { return message + "\n\nReview the conversation before trying again. You can remove this attachment from the draft." }
        return message + "\n\nRetry on send prepares a new upload. Press Send when you are ready."
    }
}
