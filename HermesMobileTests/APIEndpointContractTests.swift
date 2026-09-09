import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class ContractReadinessTests: XCTestCase {
    func testEndpointContractMatrixMatchesPinnedUpstreamPaths() throws {
        let contracts: [EndpointContract] = [
            .init(
                name: "media",
                method: "GET",
                endpoint: .media(sessionID: "session-123", path: "Assets/icon.png"),
                path: "/api/media",
                query: ["session_id": "session-123", "path": "Assets/icon.png"]
            ),
        ]

        let baseURL = URL(string: "https://example.test")!

        for contract in contracts {
            let url = contract.endpoint.url(relativeTo: baseURL)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false), contract.name)

            XCTAssertEqual(components.path, contract.path, contract.name)
            XCTAssertEqual(queryDictionary(from: components), contract.query, contract.name)
            XCTAssertTrue(["GET", "POST"].contains(contract.method), contract.name)
        }
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return APIClient(baseURL: URL(string: "https://example.test")!, session: session)
    }

    private func queryDictionary(from components: URLComponents) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

private struct EndpointContract {
    let name: String
    let method: String
    let endpoint: Endpoint
    let path: String
    let query: [String: String]

    init(name: String, method: String, endpoint: Endpoint, path: String, query: [String: String] = [:]) {
        self.name = name
        self.method = method
        self.endpoint = endpoint
        self.path = path
        self.query = query
    }
}
