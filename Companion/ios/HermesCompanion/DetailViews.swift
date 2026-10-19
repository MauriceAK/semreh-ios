import SwiftUI

struct SessionsView: View {
    var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                Button { Task { await store.newSession(); dismiss() } } label: { Label("New conversation", systemImage: "square.and.pencil") }.disabled(!store.canCommand).accessibilityIdentifier("newConversation")
                ForEach(store.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { session in
                    Button { Task { await store.select(session); dismiss() } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) { Text(session.title.isEmpty ? "Untitled conversation" : session.title).foregroundStyle(.primary); Text(session.profile).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if session.id == store.selectedSession?.id { Image(systemName: "checkmark").font(.caption) }
                        }.padding(.vertical, 5)
                    }
                }
            }.searchable(text: $search, prompt: "Find a conversation")
                .navigationTitle("Conversations").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct ControlsView: View {
    var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var slashArgument = ""
    @State private var slashName = ""
    @State private var showModels = false
    var body: some View {
        NavigationStack {
            Form {
                if let controls = store.controls {
                    Section("Current session") {
                        LabeledContent("Model") { Text(controls.model).accessibilityIdentifier("effectiveModel") }
                        LabeledContent("Provider", value: controls.provider)
                        LabeledContent("Reasoning") { Text(controls.reasoning).accessibilityIdentifier("effectiveReasoning") }
                        if let pending = controls.pendingModel { LabeledContent("Pending model", value: pending) }
                    }
                    Section("Session controls") {
                        if !controls.models.isEmpty {
                            Button("Choose model", systemImage: "square.stack") { showModels = true }.accessibilityIdentifier("chooseModel")
                        }
                        if !controls.reasoningLevels.isEmpty {
                            Menu {
                                ForEach(controls.reasoningLevels, id: \.self) { level in
                                    Button(level.capitalized) { Task { await store.execute(.init(kind: "reasoning", value: level)) } }.accessibilityIdentifier("reasoning-" + level)
                                }
                            } label: {
                                LabeledContent("Reasoning effort", value: controls.reasoning.capitalized)
                            }.accessibilityIdentifier("reasoningPicker")
                        }
                    }
                    if !controls.commands.isEmpty {
                        Section {
                            Picker("Hermes command", selection: $slashName) {
                                Text("Choose command").tag("")
                                ForEach(controls.commands) { command in Text("/" + command.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).tag(command.name) }
                            }
                            if let command = controls.commands.first(where: { $0.name == slashName }) { Text(command.description).font(.caption).foregroundStyle(.secondary) }
                            TextField("Arguments, if needed", text: $slashArgument).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Run command") { Task { await store.execute(.init(kind: "slash", name: slashName.trimmingCharacters(in: CharacterSet(charactersIn: "/")), arg: slashArgument)) } }.disabled(slashName.isEmpty)
                        } header: { Text("Commands") } footer: { Text("Controls are read back from Hermes. Availability depends on your configured provider and model.") }
                    }
                } else { ContentUnavailableView("Controls unavailable", systemImage: "slider.horizontal.3", description: Text("Open a conversation and reconnect to your host.")) }
                if let notice = store.notice { Section { Text(notice).font(.footnote).textSelection(.enabled) } }
            }.disabled(store.isSending || !store.canCommand)
                .navigationTitle("Model & reasoning").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(false) } }
                .sheet(isPresented: $showModels) { ModelPickerView(store: store).modifier(AppAlerts(store: store)) }
        }
    }
}

struct ModelPickerView: View {
    var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                if let controls = store.controls {
                    ForEach(controls.models.filter { search.isEmpty || ($0.label + " " + $0.provider + " " + $0.id).localizedCaseInsensitiveContains(search) }, id: \.key) { model in
                        Button {
                            Task { if await store.execute(.init(kind: "model", value: model.id, provider: model.provider)) { dismiss() } }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.label).foregroundStyle(.primary)
                                    Text(model.provider + " · " + model.id).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if controls.model == model.id && controls.provider == model.provider { Image(systemName: "checkmark") }
                            }
                        }.disabled(store.isSending || !store.canCommand).accessibilityIdentifier("model-" + model.key)
                    }
                }
            }
            .searchable(text: $search, prompt: "Find a model or provider")
            .navigationTitle("Choose model").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct ActivityView: View {
    private enum SectionKind: String, Hashable { case updates = "Updates", followUps = "Follow-ups" }
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false
    @State private var updateID: String?
    @State private var section = SectionKind.updates
    var body: some View {
        NavigationStack {
            List {
                if section == .updates {
                Section("Updates") {
                    if store.updates.isEmpty { Text("Useful results and requests for your attention appear here.").foregroundStyle(.secondary) }
                    ForEach(store.updates) { update in
                        Button { updateID = update.id } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: update.kind == "needs_you" ? "hand.raised" : update.kind == "error" ? "exclamationmark.circle" : "sparkles").foregroundStyle(update.kind == "error" ? .orange : .blue).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 5) { Text(update.title).font(.headline).foregroundStyle(.primary); Text(update.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                            }.padding(.vertical, 5)
                        }
                    }
                }
                } else {
                Section {
                    if store.jobs.isEmpty { Text("Give Hermes an ongoing responsibility in chat, or tap New follow-up.").foregroundStyle(.secondary) }
                    ForEach(store.jobs) { job in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(job.name).font(.headline); Spacer(); Text(job.enabled ? "Active" : "Paused").font(.caption).foregroundStyle(job.enabled ? .green : .secondary) }
                            Text(job.instruction).font(.subheadline).foregroundStyle(.secondary)
                            Text(job.schedule).font(.caption.monospaced())
                            if let status = job.lastStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                            Button(job.enabled ? "Pause follow-up" : "Resume follow-up") { Task { await store.toggleJob(job) } }.disabled(!store.canCommand)
                        }.padding(.vertical, 6)
                    }
                } header: { Text("Ongoing responsibilities") } footer: { Text("Hermes runs these tasks on your host, even when this app is closed. Pause a follow-up to prevent future scheduled runs.") }
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("Activity", selection: $section) {
                    Text("Updates").tag(SectionKind.updates)
                    Text("Follow-ups").tag(SectionKind.followUps)
                }.pickerStyle(.segmented).accessibilityIdentifier("activitySection").padding(.horizontal, 16).padding(.vertical, 8).background(Color(white: 0.055))
            }
            .navigationTitle("Follow-ups & updates").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { section = .followUps; showCreate = true } label: { Label("New follow-up", systemImage: "plus") }
                        .disabled(store.selectedSession == nil || !store.canCommand).accessibilityIdentifier("newFollowUp")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await store.loadActivity(); if let routed = store.routedUpdateID { updateID = routed; store.routedUpdateID = nil } }
            .onChange(of: store.routedUpdateID) { _, routed in
                if let routed { section = .updates; updateID = routed; store.routedUpdateID = nil }
            }
            .refreshable { await store.loadActivity() }
            .sheet(isPresented: $showCreate) { CreateJobView(store: store).modifier(AppAlerts(store: store)) }
            .navigationDestination(isPresented: Binding(get: { updateID != nil }, set: { if !$0 { updateID = nil } })) {
                if let updateID { UpdateView(store: store, id: updateID, onOpen: { dismiss() }).id(updateID) }
            }
        }
    }
}

struct CreateJobView: View {
    var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instruction = ""
    @State private var schedule = "every 1h"
    @State private var notify = "changes"
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Section("What should Hermes follow through on?") {
                    TextField("Name", text: $name)
                    TextField("What to watch, what matters, and when to tell you", text: $instruction, axis: .vertical).lineLimit(4...8)
                }
                Section {
                    TextField("Schedule", text: $schedule).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Notify me", selection: $notify) { Text("When something changes").tag("changes"); Text("After every run").tag("all") }
                } header: { Text("Timing") } footer: { Text("Use a Hermes schedule such as every 1h or a cron expression. Include the evidence and changes that would make an update useful in your instruction.") }
                Section { Text("This task uses your Hermes profile and its existing tools. Consequential actions still require the permissions configured on your host.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("New follow-up").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Create") { saving = true; Task { if await store.createJob(name: name, instruction: instruction, schedule: schedule, notify: notify) { dismiss() }; saving = false } }.disabled(saving || name.isEmpty || instruction.isEmpty || schedule.isEmpty) }
                }
        }
    }
}

struct UpdateView: View {
    var store: AppStore
    let id: String
    let onOpen: () -> Void
    @State private var detail: UpdateDetail?
    @State private var error: String?
    @State private var opening = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let detail {
                    Text(detail.update.title).font(.title2.bold())
                    Text(detail.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if let sessionID = detail.resultSessionId ?? detail.update.resultSessionId ?? detail.update.sessionId {
                        Button("Open conversation") {
                            opening = true
                            error = nil
                            Task {
                                defer { opening = false }
                                do { try await store.openResultConversation(sessionID); onOpen() }
                                catch { self.error = error.localizedDescription }
                            }
                        }.buttonStyle(.borderedProminent).disabled(opening)
                    }
                    if let error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("resultNavigationError") }
                } else if let error { ContentUnavailableView("Result unavailable", systemImage: "exclamationmark.circle", description: Text(error)) }
                else { ProgressView().frame(maxWidth: .infinity) }
            }.padding(20)
        }.navigationTitle("Update").navigationBarTitleDisplayMode(.inline)
            .task { do { detail = try await store.updateDetail(id) } catch { self.error = error.localizedDescription } }
    }
}

struct SettingsView: View {
    var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var notifications = true
    @State private var quiet = false
    @State private var quietStart = Calendar.current.date(from: DateComponents(hour: 22)) ?? .now
    @State private var quietEnd = Calendar.current.date(from: DateComponents(hour: 8)) ?? .now
    @State private var saving = false
    @State private var confirmDisconnect = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Your Hermes") {
                    LabeledContent("Host", value: store.grant?.host.name ?? "")
                    LabeledContent("Profile", value: store.grant?.host.profile ?? "")
                    Text("Your conversations, models, tools, and routines stay with Hermes. Your host must be online to work.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Notifications") {
                    Toggle("Notify me about updates", isOn: $notifications).accessibilityIdentifier("notificationToggle")
                    Text(store.notificationStatus).font(.caption).foregroundStyle(.secondary)
                    if store.hostStatus?.capabilities.notifications == false {
                        Text("Phone alerts need setup on your Hermes host. In-app updates are available.").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("hostAlertsUnavailable")
                    }
                    Button("Enable iPhone notifications") { Task { await store.enableNotifications() } }
                    Toggle("Quiet hours", isOn: $quiet).accessibilityIdentifier("quietHours")
                    if quiet {
                        DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute).accessibilityIdentifier("quietStart")
                        DatePicker("Until", selection: $quietEnd, displayedComponents: .hourAndMinute).accessibilityIdentifier("quietEnd")
                        Text(TimeZone.current.identifier).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section { Button("Disconnect this iPhone", role: .destructive) { confirmDisconnect = true }.disabled(store.fixture) } footer: { Text("Revokes this phone’s access on the host. It does not delete your Hermes conversations.") }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Saving…" : "Save") {
                            saving = true
                            let minutes: (Date) -> Int = { Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) }
                            let preferences = DeliveryPreferences(notificationsEnabled: notifications, quietStart: quiet ? minutes(quietStart) : nil, quietEnd: quiet ? minutes(quietEnd) : nil, timeZone: TimeZone.current.identifier)
                            Task { if await store.savePreferences(preferences) { dismiss() }; saving = false }
                        }.disabled(saving).accessibilityIdentifier("savePreferences")
                    }
                }
                .onAppear {
                    notifications = store.preferences.notificationsEnabled
                    quiet = store.preferences.quietStart != nil
                    if let start = store.preferences.quietStart { quietStart = Calendar.current.date(from: DateComponents(hour: start / 60, minute: start % 60)) ?? .now }
                    if let end = store.preferences.quietEnd { quietEnd = Calendar.current.date(from: DateComponents(hour: end / 60, minute: end % 60)) ?? .now }
                }
                .confirmationDialog("Disconnect this iPhone?", isPresented: $confirmDisconnect, titleVisibility: .visible) { Button("Disconnect", role: .destructive) { Task { await store.disconnect(); if store.grant == nil { dismiss() } } } }
        }
    }
}
