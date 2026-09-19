import XCTest
@testable import HermesMobile

final class HostedBotGroupTests: XCTestCase {
    func testListDecodesPinnedRoomShapeAndIgnoresUnknownFields() throws {
        let response = try decode(
            HostedBotGroupListResponse.self,
            """
            {
              "rooms": [
                {
                  "room_id": "room-1",
                  "name": "Planning",
                  "members": [
                    {
                      "member_id": "human-1",
                      "profile": "default",
                      "handle": "maurice",
                      "display_name": "Maurice",
                      "target": {"kind": "local", "profile": "default"},
                      "future_member_field": "ignored"
                    },
                    {
                      "member_id": "peer-1",
                      "profile": "research",
                      "handle": "research-bot",
                      "target": {
                        "kind": "peer",
                        "peer_id": "peer-a",
                        "installation_id": "install-a",
                        "profile": "research",
                        "capability_digest": "digest-a"
                      }
                    }
                  ],
                  "authority_gateway_id": "gateway-a",
                  "authority_epoch": 2,
                  "revision": 7,
                  "created_at": 1700000000.5,
                  "updated_at": 1700000010.5,
                  "idempotent": false,
                  "latest_seq": 3,
                  "future_room_field": {"ignored": true}
                }
              ],
              "next_offset": 100,
              "future_response_field": true
            }
            """
        )

        let room = try XCTUnwrap(response.rooms?.first)
        XCTAssertEqual(response.nextOffset, 100)
        XCTAssertEqual(room.stableRoomID, "room-1")
        XCTAssertEqual(room.name, "Planning")
        XCTAssertEqual(room.authorityGatewayID, "gateway-a")
        XCTAssertEqual(room.authorityEpoch, 2)
        XCTAssertEqual(room.revision, 7)
        XCTAssertEqual(room.createdAt, 1_700_000_000.5)
        XCTAssertEqual(room.updatedAt, 1_700_000_010.5)
        XCTAssertEqual(room.latestSeq, 3)
        XCTAssertEqual(room.members?.count, 2)
        XCTAssertEqual(room.members?.first?.profile, "default")
        XCTAssertEqual(room.members?.first?.stableMemberID, "human-1")
        XCTAssertEqual(
            room.members?.first?.target,
            .object(["kind": .string("local"), "profile": .string("default")])
        )
    }

    func testStateDecodesOptionalDriverStatusWithoutRequiringIt() throws {
        let response = try decode(
            HostedBotGroupStateResponse.self,
            """
            {
              "room": {
                "room_id": "room-1",
                "name": "Planning",
                "members": [],
                "authority_gateway_id": "gateway-a",
                "authority_epoch": 2,
                "revision": 7,
                "created_at": 1700000000,
                "updated_at": 1700000010,
                "idempotent": false,
                "latest_seq": 3
              },
              "driver_status": {
                "running": true,
                "working": false,
                "blocked": false,
                "counts": {"settled": 1},
                "pending_actions": [{"kind": "retry", "task_id": "task-1"}],
                "peer_routes": [],
                "future_status_field": "ignored"
              },
              "future_state_field": null
            }
            """
        )

        XCTAssertEqual(response.room?.stableRoomID, "room-1")
        XCTAssertEqual(response.room?.latestSeq, 3)
        XCTAssertEqual(
            response.driverStatus,
            .object([
                "running": .bool(true),
                "working": .bool(false),
                "blocked": .bool(false),
                "counts": .object(["settled": .number(1)]),
                "pending_actions": .array([
                    .object(["kind": .string("retry"), "task_id": .string("task-1")])
                ]),
                "peer_routes": .array([]),
                "future_status_field": .string("ignored")
            ])
        )
    }

    func testLogDecodesTypedEventsAuthorityAndJSONPayloads() throws {
        let response = try decode(
            HostedBotGroupLogResponse.self,
            """
            {
              "events": [
                {
                  "room_id": "room-1",
                  "seq": 1,
                  "event_id": "event-1",
                  "kind": "message.user",
                  "actor": {"kind": "user", "id": "desktop"},
                  "authority_epoch": 2,
                  "payload": {"text": "hello", "thread_id": "thread-1"},
                  "created_at": 1700000011.25,
                  "idempotent": false,
                  "future_event_field": [1, 2, 3]
                }
              ],
              "cursor": 1,
              "latest_seq": 3,
              "has_more": true,
              "authority": {
                "gateway_id": "gateway-a",
                "epoch": 2,
                "future_authority_field": "ignored"
              }
            }
            """
        )

        let event = try XCTUnwrap(response.events?.first)
        XCTAssertEqual(event.roomID, "room-1")
        XCTAssertEqual(event.seq, 1)
        XCTAssertEqual(event.eventID, "event-1")
        XCTAssertEqual(event.kind, "message.user")
        XCTAssertEqual(event.authorityEpoch, 2)
        XCTAssertEqual(event.createdAt, 1_700_000_011.25)
        XCTAssertEqual(event.actor, .object(["kind": .string("user"), "id": .string("desktop")]))
        XCTAssertEqual(
            event.payload,
            .object(["text": .string("hello"), "thread_id": .string("thread-1")])
        )
        XCTAssertEqual(response.cursor, 1)
        XCTAssertEqual(response.latestSeq, 3)
        XCTAssertEqual(response.hasMore, true)
        XCTAssertEqual(response.authority?.gatewayID, "gateway-a")
        XCTAssertEqual(response.authority?.epoch, 2)
    }

    func testMissingRoomIdentityIsRejectedAtDisplayBoundaryWithoutFabrication() throws {
        let response = try decode(
            HostedBotGroupListResponse.self,
            """
            {
              "rooms": [
                {
                  "room_id": "  room-1  ",
                  "name": "Valid",
                  "members": [{"handle": "unresolved-member"}]
                },
                {"name": "Missing identity", "members": []},
                {"room_id": "   ", "name": "Blank identity", "members": []},
                {"room_id": 42, "name": "Numeric identity", "members": []}
            ]
            }
            """
        )

        XCTAssertEqual(response.rooms?.count, 4)
        XCTAssertEqual(response.displayableRooms.map(\.stableRoomID), ["  room-1  "])
        XCTAssertNil(response.rooms?[1].stableRoomID)
        XCTAssertNil(response.rooms?[2].stableRoomID)
        XCTAssertNil(response.rooms?[3].roomID)
        XCTAssertNil(response.rooms?[3].stableRoomID)

        let member = try XCTUnwrap(response.rooms?.first?.members?.first)
        XCTAssertEqual(member.handle, "unresolved-member")
        XCTAssertNil(member.memberID)
        XCTAssertNil(member.profile)
        XCTAssertNil(member.stableMemberID)
    }

    func testPaginationFieldsRemainDistinctFromRoomAndLogIdentity() throws {
        let list = try decode(
            HostedBotGroupListResponse.self,
            #"{"rooms":[],"next_offset":"200"}"#
        )
        let log = try decode(
            HostedBotGroupLogResponse.self,
            #"{"events":[],"cursor":"4","latest_seq":"9","has_more":"false","authority":{"gateway_id":"gateway-a","epoch":"2"}}"#
        )

        XCTAssertEqual(list.nextOffset, 200)
        XCTAssertEqual(log.cursor, 4)
        XCTAssertEqual(log.latestSeq, 9)
        XCTAssertEqual(log.hasMore, false)
        XCTAssertEqual(log.authority?.epoch, 2)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
