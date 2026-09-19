import Foundation
import Observation
import SwiftData
import SwiftUI

extension SessionListViewModel {
    func loadActiveProfile() async {
        if isLoadingActiveProfile {
            await withCheckedContinuation { continuation in
                activeProfileLoadWaiters.append(continuation)
            }
            return
        }

        isLoadingActiveProfile = true
        activeProfileErrorMessage = nil
        defer {
            isLoadingActiveProfile = false
            let waiters = activeProfileLoadWaiters
            activeProfileLoadWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        do {
            let response = try await client.directProfiles()
            let inventorySelection = response.active
                ?? response.profiles?.first(where: { $0.isActive == true })?.normalizedName
            let runningSelection: String?
            if locallySelectedProfileName != nil || inventorySelection != nil {
                // Older compatible servers may still include an authoritative
                // selection in the inventory response.
                runningSelection = nil
            } else {
                // Stock inventory is only metadata. The running dashboard
                // identity is `current`, not the sticky future-CLI `active`.
                runningSelection = try await client.directActiveProfile().current
            }
            // Resolve the local selection after every await: a user may have
            // switched profiles while either request was pending.
            let scoped = ProfilesResponse(profiles: response.profiles,
                                          active: locallySelectedProfileName
                                              ?? inventorySelection
                                              ?? Self.nonEmpty(runningSelection),
                                          singleProfileMode: response.singleProfileMode)
            guard scoped.active != nil else {
                throw APIError.http(statusCode: -1, body: nil)
            }
            applyActiveProfile(scoped)
        } catch {
            guard !isCancellationError(error) else { return }

            activeProfileErrorMessage = error.localizedDescription
        }
    }

    private var locallySelectedProfileName: String?

    func switchActiveProfile(_ profile: ProfileSummary) async -> Bool {
        guard !isViewingCachedData else {
            activeProfileErrorMessage = String(localized: "Reconnect to the server to change profiles.")
            return false
        }

        guard let profileName = Self.nonEmpty(profile.name) else {
            activeProfileErrorMessage = String(localized: "The server did not provide a profile name.")
            return false
        }

        locallySelectedProfileName = profileName
        guard profileName != activeProfileName else {
            return true
        }

        isSwitchingActiveProfile = true
        switchingActiveProfileName = profileName
        activeProfileErrorMessage = nil
        lastError = nil
        defer {
            isSwitchingActiveProfile = false
            switchingActiveProfileName = nil
        }

        // Profile selection is local UI state. The direct sidebar request
        // carries this profile explicitly; switching must not mutate a global
        // server/WebUI profile or issue a legacy `/api/profile/switch` call.
        let profileResponse = ProfilesResponse(
            profiles: profileOptions,
            active: profileName,
            singleProfileMode: isSingleProfileMode
        )
        applyActiveProfile(
            profileResponse,
            fallbackProfile: profile,
            fallbackDefaultModel: profile.model
        )
        return true
    }

    private func applyActiveProfile(
        _ response: ProfilesResponse,
        fallbackProfile: ProfileSummary? = nil,
        fallbackDefaultModel: String? = nil
    ) {
        profileOptions = response.profiles ?? profileOptions

        // Tolerant: only a present field moves the flag, so an older server
        // (or the carried-forward switch-response value) keeps today's behavior.
        if let singleProfileMode = response.singleProfileMode {
            isSingleProfileMode = singleProfileMode
        }

        // Keep the App Intents profile cache fresh so the "New Chat in <Profile>" picker
        // (#339) stays populated when the Shortcuts app resolves it in the background, where
        // a live, authenticated fetch may not be possible, then nudge the system to (re-)index
        // the parameterized App Shortcut (iOS only indexes it once its suggested values exist).
        // A nil `profiles` (field absent/undecoded) is left untouched — tolerant decoding — but
        // an explicit empty list is forwarded so `save([])` can clear a stale picker if the
        // server ever reports none.
        if let profiles = response.profiles {
            let changed = ProfileEntityCache.shared.save(profiles)
            ProfileEntityProvider.refreshAppShortcuts(changed: changed)
        }

        let profileName = response.effectiveDefaultProfileName
        let profile = response.profile(matching: profileName) ?? fallbackProfile

        if activeProfileName != profileName {
            activeProfileEpoch &+= 1
            archivedCountRequestGeneration &+= 1
            archivedCount = nil
            // A response for the previous profile must never repopulate a
            // same-query search after a profile switch.
            remoteSearchGeneration &+= 1
            activeRemoteSearchQuery = nil
            activeRemoteSearchProfile = nil
            remoteContentSearchSessionIDs = []
            orderedRemoteIDs = []
            remoteResolvedRows = [:]
            isSearchingRemoteSessions = false
            do {
                projects = try organizerStore.groups(server: server, profile: Self.nonEmpty(profileName) ?? "default")
            } catch {
                projects = []
                actionErrorMessage = error.localizedDescription
            }
        }
        activeProfileName = profileName
        activeProfileDisplayName = response.displayName(for: profileName)
            ?? profile?.displayName
        activeProfileModel = Self.nonEmpty(profile?.model) ?? Self.nonEmpty(fallbackDefaultModel)
        activeProfileProvider = Self.nonEmpty(profile?.provider)
    }
}
