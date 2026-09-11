import Foundation

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
}

enum URLScheme: String {
    case http, https, data

    func matches(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare(rawValue) == .orderedSame
    }

    var isHTTP: Bool {
        switch self {
        case .http, .https: true
        case .data: false
        }
    }
}

enum OAuthGrantType: String, Encodable {
    case authorizationCode = "authorization_code"
    case refreshToken = "refresh_token"
}
