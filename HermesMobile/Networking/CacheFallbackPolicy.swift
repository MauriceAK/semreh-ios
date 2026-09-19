import Foundation

enum CacheFallbackPolicy {
    static func shouldUseCache(for error: Error) -> Bool {
        switch classified(error) {
        case .url(let code):
            return isConnectivityCode(code)
        case .http(let statusCode):
            return isTransientUnavailableStatus(statusCode)
        case .other:
            return false
        }
    }

    /// A short-lived transport blip. Common on iOS + Tailscale + SSE.
    /// These must not paint the "server is down / check the tunnel" composer banner.
    static func isTransientBlip(_ error: Error) -> Bool {
        if shouldAnnounceAsServerOutage(error) {
            return false
        }

        switch classified(error) {
        case .url(let code):
            switch code {
            case .networkConnectionLost,
                 .cannotConnectToHost,
                 .timedOut,
                 .notConnectedToInternet,
                 .dataNotAllowed:
                return true
            default:
                return false
            }
        case .http(let statusCode):
            return [408, 429, 500].contains(statusCode)
        case .other:
            return false
        }
    }

    /// Only a real missing host or a gateway-level outage should lecture about
    /// the Hermes server or tunnel.
    static func shouldAnnounceAsServerOutage(_ error: Error) -> Bool {
        switch classified(error) {
        case .url(let code):
            return code == .cannotFindHost || code == .dnsLookupFailed
        case .http(let statusCode):
            return [502, 503, 504].contains(statusCode)
        case .other:
            return false
        }
    }

    static func composerBannerMessage(for error: Error) -> String? {
        if isTransientBlip(error) {
            return nil
        }

        return error.localizedDescription
    }

    static func sendBannerMessage(for error: Error) -> String {
        if isTransientBlip(error) {
            return String(localized: "Couldn't reach the server. Try again.")
        }

        return error.localizedDescription
    }

    private enum ClassifiedError {
        case url(URLError.Code)
        case http(Int)
        case other
    }

    private static func classified(_ error: Error) -> ClassifiedError {
        if case APIError.http(let statusCode, _) = error {
            return .http(statusCode)
        }

        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        if let urlError = underlying as? URLError {
            return .url(urlError.code)
        }

        return .other
    }

    private static func isConnectivityCode(_ code: URLError.Code) -> Bool {
        switch code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .cannotFindHost,
             .dataNotAllowed,
             .timedOut:
            return true
        default:
            return false
        }
    }

    private static func isTransientUnavailableStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 502, 503, 504:
            return true
        default:
            return false
        }
    }
}
