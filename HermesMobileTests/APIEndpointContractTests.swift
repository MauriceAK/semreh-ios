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
                name: "raw file",
                method: "GET",
                endpoint: .rawFile(sessionID: "session-123", path: "Assets/icon.png"),
                path: "/api/file/raw",
                query: ["session_id": "session-123", "path": "Assets/icon.png"]
            ),
            .init(
                name: "media",
                method: "GET",
                endpoint: .media(sessionID: "session-123", path: "Assets/icon.png"),
                path: "/api/media",
                query: ["session_id": "session-123", "path": "Assets/icon.png"]
            ),
            .init(name: "personalities", method: "GET", endpoint: .personalities, path: "/api/personalities"),
            .init(name: "set personality", method: "POST", endpoint: .setPersonality, path: "/api/personality/set"),
            .init(name: "skills", method: "GET", endpoint: .skills, path: "/api/skills"),
            .init(
                name: "skill content",
                method: "GET",
                endpoint: .skillContent(name: "swiftui-ui-patterns", file: nil),
                path: "/api/skills/content",
                query: ["name": "swiftui-ui-patterns"]
            ),
            .init(
                name: "skill linked file",
                method: "GET",
                endpoint: .skillContent(name: "swiftui-ui-patterns", file: "references/navigation.md"),
                path: "/api/skills/content",
                query: ["name": "swiftui-ui-patterns", "file": "references/navigation.md"]
            ),
            .init(name: "upload", method: "POST", endpoint: .upload, path: "/api/upload")
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

    func testMultipartPostRequestsOmitBrowserCSRFHeaders() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)

            return apiTestJSONResponse("""
            {
              "filename": "contract.txt",
              "path": "/tmp/workspace/contract.txt",
              "size": 8,
              "mime": "text/plain",
              "is_image": false
            }
            """, for: request)
        }

        let response = try await client.uploadFile(sessionID: "abc123", data: Data("contract".utf8), filename: "contract.txt")

        XCTAssertEqual(response.filename, "contract.txt")
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
