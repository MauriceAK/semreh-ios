import XCTest
@testable import HermesMobile

final class DirectHermesManagedFileTests: APIClientTestCase {
    func testDirectReadManagedFileBuildsAuthenticatedReadRequestAndDecodesDataURL() async throws {
        let expectedBytes = Data([0x00, 0x01, 0xFE, 0xFF])
        let dataURL = "data:application/octet-stream;base64,\(expectedBytes.base64EncodedString())"
        let client = makeAuthenticatedClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/files/read")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            XCTAssertEqual(query["path"], "/profile/attachments/notes with space.txt")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Test-Session"), "authenticated")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer must-not-be-read")

            return apiTestJSONResponse(
                #"{"name":"notes.txt","path":"/profile/attachments/notes with space.txt","size":4,"mime_type":"application/octet-stream","data_url":"\#(dataURL)"}"#,
                for: request
            )
        }

        let result = try await client.directReadManagedFile(path: " /profile/attachments/notes with space.txt ")

        XCTAssertEqual(result.data, expectedBytes)
        XCTAssertEqual(result.name, "notes.txt")
        XCTAssertEqual(result.path, "/profile/attachments/notes with space.txt")
        XCTAssertEqual(result.mimeType, "application/octet-stream")
        XCTAssertEqual(result.size, expectedBytes.count)
    }

    func testDirectReadManagedFileToleratesOptionalMetadataTypes() async throws {
        let client = makeAuthenticatedClient { request in
            apiTestJSONResponse(
                #"{"data_url":"data:text/plain;base64,SGk=","name":true,"path":42,"mime_type":7,"size":"2"}"#,
                for: request
            )
        }

        let result = try await client.directReadManagedFile(path: "/profile/attachments/note.txt")

        XCTAssertEqual(result.data, Data("Hi".utf8))
        XCTAssertEqual(result.name, "true")
        XCTAssertEqual(result.path, "42")
        XCTAssertEqual(result.mimeType, "7")
        XCTAssertEqual(result.size, 2)
    }

    func testDirectReadManagedFileRejectsEmptyRelativeAndExternalPathsBeforeRequest() async {
        let client = makeAuthenticatedClient { _ in
            XCTFail("Invalid managed-file paths must not issue a request")
            return apiTestJSONResponse(#"{}"#, for: URLRequest(url: URL(string: "https://example.test")!))
        }

        for path in ["", "   ", "attachments/note.txt", "https://other.example/note.txt"] {
            do {
                _ = try await client.directReadManagedFile(path: path)
                XCTFail("Expected invalid path to be rejected: \(path)")
            } catch APIError.invalidServerURL {
                // The client rejects path shape; the server remains responsible
                // for managed-root and sensitive-file policy.
            } catch {
                XCTFail("Expected invalidServerURL for \(path), got \(error)")
            }
        }
    }

    func testDirectReadManagedFileRejectsMalformedOrNonBase64DataURL() async throws {
        let responses = [
            #"{"data_url":"https://other.example/file.txt"}"#,
            #"{"data_url":"data:text/plain;base64,not valid"}"#,
            #"{"name":"missing-data-url"}"#
        ]

        for body in responses {
            let client = makeAuthenticatedClient { request in
                apiTestJSONResponse(body, for: request)
            }

            do {
                _ = try await client.directReadManagedFile(path: "/profile/attachments/note.txt")
                XCTFail("Expected managed-file data URL rejection")
            } catch APIError.decoding {
                // External URLs, malformed base64, and missing data_url values
                // are decoding failures, never downloads.
            } catch {
                XCTFail("Expected APIError.decoding, got \(error)")
            }
        }
    }

    func testDirectReadManagedFileAllowsEmptyGenericPayload() async throws {
        let client = makeAuthenticatedClient { request in
            apiTestJSONResponse(
                #"{"data_url":"data:text/plain;base64,","name":"empty.txt","size":0}"#,
                for: request
            )
        }

        let result = try await client.directReadManagedFile(path: "/profile/attachments/empty.txt")

        XCTAssertEqual(result.data, Data())
        XCTAssertEqual(result.size, 0)
    }

    func testDirectReadManagedFileBoundsJSONBeforeDecoding() async throws {
        let maximumDecodedBytes = 25 * 1_024 * 1_024
        let maximumEncodedBytes = ((maximumDecodedBytes + 2) / 3) * 4 + 512
        let client = makeAuthenticatedClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Content-Length": String(maximumEncodedBytes + 1)
                ]
            )!
            return (response, Data(#"{"data_url":"data:text/plain;base64,SGk="}"#.utf8))
        }

        do {
            _ = try await client.directReadManagedFile(path: "/profile/attachments/large.bin")
            XCTFail("Expected managed-file response limit")
        } catch let PreviewDownloadError.responseTooLarge(maximumBytes) {
            XCTAssertEqual(maximumBytes, maximumEncodedBytes)
        } catch {
            XCTFail("Expected PreviewDownloadError.responseTooLarge, got \(error)")
        }
    }

    func testDirectReadManagedFilePreservesUnauthorizedClassification() async throws {
        let client = makeAuthenticatedClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"detail":"Unauthorized"}"#.utf8))
        }

        do {
            _ = try await client.directReadManagedFile(path: "/profile/attachments/note.txt")
            XCTFail("Expected unauthorized response")
        } catch APIError.unauthorized {
            // Protected stock route keeps the existing auth distinction.
        } catch {
            XCTFail("Expected APIError.unauthorized, got \(error)")
        }
    }

    private func makeAuthenticatedClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: session,
            customHeaderProvider: {
                [
                    CustomHeader(name: "X-Hermes-Test-Session", value: "authenticated"),
                    CustomHeader(name: "Authorization", value: "Bearer must-not-be-read")
                ]
            }
        )
    }
}
