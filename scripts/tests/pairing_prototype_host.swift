import Foundation

@main struct PairingPrototypeHostTests {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool) {
            precondition(value(), "Pairing assertion failed")
            count += 1
        }
        func payload(_ origin: String, version: Int = 1) -> String {
            let data = try! JSONSerialization.data(withJSONObject: ["type": "semreh-pairing", "version": version, "origin": origin])
            return String(decoding: data, as: UTF8.self)
        }
        let valid = payload("https://hermes.example.ts.net:8443/")
        let imported = try PairingImport.parse(valid)
        check(imported.origin.absoluteString == "https://hermes.example.ts.net:8443")
        for address in [
            "http://hermes.ts.net", "file:///tmp/example", "javascript:alert(1)",
            "https://user:secret@hermes.ts.net", "https://hermes.ts.net@evil.example",
            "https://hermes.ts.net?token=secret", "https://hermes.ts.net?", "https://hermes.ts.net#", "https://hermes.ts.net/#secret",
            "https://hermes.ts.net/path", "https://hermes.ts.net/%2e", "https://hermes.ts.net\\@evil.example",
            "https://hermes.ts.net\n", "https://hérmes.ts.net", "https://xn--hermes-example.ts.net",
            "https://hermes\u{202E}.ts.net", "https://hermes..ts.net", "https://-hermes.ts.net",
            "https://hermes.ts.net.", "https://hermes.ts.net:0", "https://hermes.ts.net:65536", "https://hermes.ts.net:",
            "https://", "https://hermes.ts.net:000443"
        ] { check((try? PairingImport.parse(payload(address))) == nil) }
        for invalid in ["{}", "[]", "not json", payload("https://hermes.ts.net", version: 2),
                        String(repeating: "a", count: 2049),
                        "{\"type\":\"semreh-pairing\",\"version\":true,\"origin\":\"https://hermes.ts.net\"}",
                        "{\"type\":\"semreh-pairing\",\"version\":1,\"origin\":\"https://hermes.ts.net\",\"token\":\"secret\"}"] {
            check((try? PairingImport.parse(invalid)) == nil)
        }
        let defaultPort = try PairingImport.validateOrigin("https://hermes.ts.net:443/")
        check(defaultPort.origin.absoluteString == "https://hermes.ts.net")
        var session = PairingSession()
        check(session.confirm() == nil)
        try session.importCode(valid)
        check(session.stage == .review(imported))
        let attempt = session.confirm()!
        check(session.confirm() == nil)
        session.discovered(.passwordSignIn, attempt: UUID())
        check(session.stage == .checking(imported, attempt))
        session.cancel()
        session.discovered(.passwordSignIn, attempt: attempt)
        check(session.stage == .introduction)
        try session.importCode(valid)
        let next = session.confirm()!
        session.discovered(.passwordSignIn, attempt: next)
        check(session.stage == .signIn(imported))
        check(session.confirm() == nil)
        do { try session.importCode("bad") } catch {}
        check(session.stage == .introduction)
        for result in [PairingSession.Discovery.unsupported, .unreachable] {
            try session.enterManually("https://hermes.example.ts.net:8443")
            let token = session.confirm()!
            session.discovered(result, attempt: token)
            check(session.stage == (result == .unsupported ? .unsupported(imported) : .unreachable(imported)))
        }
        var scanner = PairingScanPolicy()
        let inactive = scanner.generation
        let ignoredInactive = try scanner.admit(valid, generation: inactive)
        check(ignoredInactive == nil)
        scanner.setActive(true)
        let active = scanner.generation
        check(active != inactive)
        let stale = try scanner.admit(valid, generation: inactive)
        check(stale == nil)
        do { _ = try scanner.admit("bad", generation: active); preconditionFailure("Invalid QR accepted") }
        catch { check(!scanner.consumed) }
        scanner.setActive(false)
        let background = try scanner.admit(valid, generation: active)
        check(background == nil)
        scanner.setActive(true)
        let resumed = scanner.generation
        let late = try scanner.admit(valid, generation: active)
        check(late == nil)
        scanner.setActive(true)
        check(scanner.generation == resumed)
        let accepted = try scanner.admit(valid, generation: resumed)
        check(accepted == imported)
        let duplicate = try scanner.admit(valid, generation: resumed)
        check(duplicate == nil)
        scanner.setActive(false)
        scanner.setActive(true)
        let afterResume = try scanner.admit(valid, generation: scanner.generation)
        check(afterResume == nil)
        scanner = PairingScanPolicy()
        scanner.setActive(true)
        let nextPresentation = try scanner.admit(valid, generation: scanner.generation)
        check(nextPresentation == imported)
        print("Pairing host checks: \(count) passed; 0 failed")
    }
}
