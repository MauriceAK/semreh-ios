import Foundation
import SwiftUI
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

    func testDefaultProfileUsesSkyPaletteAndNamedProfilesKeepTheirBuckets() {
        let server = URL(string: "https://fixture.example")!
        let defaultIdentity = BirdAvatarIdentity(server: server, profile: "default")!
        let appearancePreviewIdentity = BirdAvatarIdentity(server: server, profile: "appearance-preview")!
        let namedIdentity = BirdAvatarIdentity(server: server, profile: "research")!
        let decorativeIdentity = BirdAvatarIdentity(server: server, profile: "onboarding-2")!

        XCTAssertEqual(BirdPalette.assignment(for: defaultIdentity), .sky)
        XCTAssertEqual(BirdPalette.assignment(for: appearancePreviewIdentity), .sky)
        XCTAssertEqual(BirdPalette.sky.colors.0, 0xF6F8FF)
        XCTAssertEqual(BirdPalette.sky.colors.1, 0xBDD3FF)
        XCTAssertEqual(BirdPalette.sky.colors.2, 0x82ACF5)

        let existingAssignments: [BirdPalette] = [.yellow, .orange, .mint, .pink, .sky, .violet]
        for identity in [namedIdentity, decorativeIdentity] {
            XCTAssertEqual(BirdPalette.assignment(for: identity), existingAssignments[identity.presetIndex])
        }
    }

    func testAvatarSilhouetteUsesLowerWiderReferenceProportions() {
        let bounds = BirdArtworkGeometry.bodyPath.boundingRect

        XCTAssertEqual(Int(bounds.minY.rounded()), 16)
        XCTAssertEqual(Int(bounds.maxY.rounded()), 89)
        XCTAssertGreaterThanOrEqual(bounds.width / bounds.height, 1.25)
        XCTAssertEqual(Int(BirdArtworkGeometry.leftEyeCenter.y.rounded()), 43)
        XCTAssertEqual(Int(BirdArtworkGeometry.rightEyeCenter.y.rounded()), 41)
    }
}
