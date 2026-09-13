import Foundation
import XCTest
@testable import HermesMobile

final class BirdAvatarIdentityTests: XCTestCase {
    func testIdentityRequiresRealSourceAndProfile() {
        let server = URL(string: "https://fixture.example")!
        XCTAssertNil(BirdAvatarIdentity(server: nil, profile: "research"))
        XCTAssertNil(BirdAvatarIdentity(server: server, profile: nil))
        XCTAssertNil(BirdAvatarIdentity(server: server, profile: " \n"))
    }

    func testProfileIdentityIsSourceQualifiedAndStable() {
        let a = BirdAvatarIdentity(server: URL(string: "https://a.example"), profile: "research")!
        let same = BirdAvatarIdentity(server: URL(string: "https://a.example"), profile: "research")!
        let b = BirdAvatarIdentity(server: URL(string: "https://b.example"), profile: "research")!
        XCTAssertEqual(a, same)
        XCTAssertEqual(a.presetIndex, same.presetIndex)
        XCTAssertNotEqual(a, b)
        // Six visual presets can collide; source identity must not.
        XCTAssertTrue((0..<6).contains(b.presetIndex))
    }

    func testProfileNamesAreNotCaseFoldedOrReplaced() {
        let server = URL(string: "https://fixture.example")!
        XCTAssertNotEqual(BirdAvatarIdentity(server: server, profile: "Research"),
                          BirdAvatarIdentity(server: server, profile: "research"))
    }
}
