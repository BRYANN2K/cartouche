import Foundation

enum HTTPFetch {

    typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    static func download(
        timeout: TimeInterval,
        resourceTimeout: TimeInterval? = nil,
        userAgent: String? = nil,
        cooldown: HTTPCooldown = .shared
    ) -> Fetch {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        if let resourceTimeout { config.timeoutIntervalForResource = resourceTimeout }
        if let userAgent { config.httpAdditionalHeaders = ["User-Agent": userAgent] }
        let session = URLSession(configuration: config)
        return throttled(cooldown) { url in
            let (data, response) = try await session.data(from: url)
            let http = response as? HTTPURLResponse
            return (data, http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Retry-After"))
        }
    }

    // A paused host answers 429 locally, so callers keep their own "unavailable" path without a request going out
    static func throttled(
        _ cooldown: HTTPCooldown,
        _ send: @escaping @Sendable (URL) async throws -> (Data, Int, String?)
    ) -> Fetch {
        { url in
            if await cooldown.isPaused(url) { return (Data(), 429) }
            let (data, status, retryAfter) = try await send(url)
            if let delay = await cooldown.note(url, status: status, retryAfter: retryAfter) {
                AppLog.note("\(url.host() ?? "server") answered HTTP \(status): requests paused for \(Int(delay)) s")
            }
            return (data, status)
        }
    }
}
