import Foundation

/// Patient content and credentials must never follow a server redirect or enter disk caches.
public final class PrivateHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: PrivateHTTP(), delegateQueue: nil)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    public static func clinicURL(_ base: String, route: String, query: [URLQueryItem] = []) throws -> URL {
        guard let root = URL(string: base), let host = root.host, !host.isEmpty,
              root.scheme == "https" || (root.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)),
              root.user == nil, root.password == nil, root.query == nil, root.fragment == nil,
              route.hasPrefix("/v1/"), !route.contains(".."), !route.contains("?"), !route.contains("#"),
              var parts = URLComponents(url: root.appendingPathComponent(route), resolvingAgainstBaseURL: false) else { throw RadError.message("The clinic backend needs HTTPS or a local loopback address, without embedded credentials.") }
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw RadError.message("Invalid clinic API address.") }; return url
    }
}
