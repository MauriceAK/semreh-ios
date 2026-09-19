import Foundation

/// Read-only projections of the pinned hosted-room JSON-RPC responses.
///
/// These models intentionally do not create local identities or infer member
/// profiles.  A room is eligible for a future directory row only when the
/// server supplied a non-empty `room_id`; all other fields remain optional so
/// additive or partially populated backend responses cannot break decoding.
struct HostedBotGroupListResponse: Decodable, Equatable, Sendable {
    let rooms: [HostedBotGroup]?
    let nextOffset: Int?

    /// The display boundary for a future Groups directory.  This filters only
    /// the durable room identity; it does not synthesize a name or membership.
    var displayableRooms: [HostedBotGroup] {
        (rooms ?? []).filter { $0.stableRoomID != nil }
    }

    private enum CodingKeys: String, CodingKey {
        case rooms
        case nextOffset = "next_offset"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rooms = try? container.decodeIfPresent([HostedBotGroup].self, forKey: .rooms)
        nextOffset = container.decodeLossyIntIfPresent(forKey: .nextOffset)
    }
}

/// `groups.state` result.  `driver_status` is absent for disbanded or
/// otherwise inactive rooms, so it must not be treated as a required proof of
/// room existence.
struct HostedBotGroupStateResponse: Decodable, Equatable, Sendable {
    let room: HostedBotGroup?
    let driverStatus: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case room
        case driverStatus = "driver_status"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        room = try? container.decodeIfPresent(HostedBotGroup.self, forKey: .room)
        driverStatus = try? container.decodeIfPresent(JSONValue.self, forKey: .driverStatus)
    }
}

/// `groups.log` result.  Event payloads are retained as JSON values because
/// the backend's typed-event vocabulary is extensible and room replay is not
/// yet a mobile mutation or rendering surface.
struct HostedBotGroupLogResponse: Decodable, Equatable, Sendable {
    let events: [HostedBotGroupEvent]?
    let cursor: Int?
    let latestSeq: Int?
    let hasMore: Bool?
    let authority: HostedBotGroupAuthority?

    private enum CodingKeys: String, CodingKey {
        case events
        case cursor
        case latestSeq = "latest_seq"
        case hasMore = "has_more"
        case authority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try? container.decodeIfPresent([HostedBotGroupEvent].self, forKey: .events)
        cursor = container.decodeLossyIntIfPresent(forKey: .cursor)
        latestSeq = container.decodeLossyIntIfPresent(forKey: .latestSeq)
        hasMore = container.decodeLossyBoolIfPresent(forKey: .hasMore)
        authority = try? container.decodeIfPresent(HostedBotGroupAuthority.self, forKey: .authority)
    }
}

/// One durable hosted-room row returned by `groups.list` or nested in
/// `groups.state`.
struct HostedBotGroup: Decodable, Equatable, Sendable {
    let roomID: String?
    let name: String?
    let members: [HostedBotGroupMember]?
    let authorityGatewayID: String?
    let authorityEpoch: Int?
    let revision: Int?
    let createdAt: Double?
    let updatedAt: Double?
    let idempotent: Bool?
    let disbandedAt: Double?
    let latestSeq: Int?

    /// The only identity that is safe to use for a Groups row or navigation.
    /// There is deliberately no UUID, profile, handle, or name fallback.
    var stableRoomID: String? {
        guard let roomID else { return nil }
        let trimmed = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : roomID
    }

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case name
        case members
        case authorityGatewayID = "authority_gateway_id"
        case authorityEpoch = "authority_epoch"
        case revision
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case idempotent
        case disbandedAt = "disbanded_at"
        case latestSeq = "latest_seq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roomID = try? container.decodeIfPresent(String.self, forKey: .roomID)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        members = try? container.decodeIfPresent([HostedBotGroupMember].self, forKey: .members)
        authorityGatewayID = try? container.decodeIfPresent(String.self, forKey: .authorityGatewayID)
        authorityEpoch = container.decodeLossyIntIfPresent(forKey: .authorityEpoch)
        revision = container.decodeLossyIntIfPresent(forKey: .revision)
        createdAt = container.decodeLossyDoubleIfPresent(forKey: .createdAt)
        updatedAt = container.decodeLossyDoubleIfPresent(forKey: .updatedAt)
        idempotent = container.decodeLossyBoolIfPresent(forKey: .idempotent)
        disbandedAt = container.decodeLossyDoubleIfPresent(forKey: .disbandedAt)
        latestSeq = container.decodeLossyIntIfPresent(forKey: .latestSeq)
    }
}

/// A persisted same-gateway or peer member.  Backend roster validation is not
/// repeated here; in particular, an absent `profile` stays absent rather than
/// being guessed from `handle`, `member_id`, or `display_name`.
struct HostedBotGroupMember: Decodable, Equatable, Sendable {
    let memberID: String?
    let profile: String?
    let handle: String?
    let displayName: String?
    let target: JSONValue?

    var stableMemberID: String? {
        guard let memberID else { return nil }
        let trimmed = memberID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : memberID
    }

    private enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case profile
        case handle
        case displayName = "display_name"
        case target
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memberID = try? container.decodeIfPresent(String.self, forKey: .memberID)
        profile = try? container.decodeIfPresent(String.self, forKey: .profile)
        handle = try? container.decodeIfPresent(String.self, forKey: .handle)
        displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        target = try? container.decodeIfPresent(JSONValue.self, forKey: .target)
    }
}

/// One replayable typed event from `groups.log`.
struct HostedBotGroupEvent: Decodable, Equatable, Sendable {
    let roomID: String?
    let seq: Int?
    let eventID: String?
    let kind: String?
    let actor: JSONValue?
    let authorityEpoch: Int?
    let payload: JSONValue?
    let createdAt: Double?
    let idempotent: Bool?

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case seq
        case eventID = "event_id"
        case kind
        case actor
        case authorityEpoch = "authority_epoch"
        case payload
        case createdAt = "created_at"
        case idempotent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roomID = try? container.decodeIfPresent(String.self, forKey: .roomID)
        seq = container.decodeLossyIntIfPresent(forKey: .seq)
        eventID = try? container.decodeIfPresent(String.self, forKey: .eventID)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        actor = try? container.decodeIfPresent(JSONValue.self, forKey: .actor)
        authorityEpoch = container.decodeLossyIntIfPresent(forKey: .authorityEpoch)
        payload = try? container.decodeIfPresent(JSONValue.self, forKey: .payload)
        createdAt = container.decodeLossyDoubleIfPresent(forKey: .createdAt)
        idempotent = container.decodeLossyBoolIfPresent(forKey: .idempotent)
    }
}

struct HostedBotGroupAuthority: Decodable, Equatable, Sendable {
    let gatewayID: String?
    let epoch: Int?

    private enum CodingKeys: String, CodingKey {
        case gatewayID = "gateway_id"
        case epoch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gatewayID = try? container.decodeIfPresent(String.self, forKey: .gatewayID)
        epoch = container.decodeLossyIntIfPresent(forKey: .epoch)
    }
}
