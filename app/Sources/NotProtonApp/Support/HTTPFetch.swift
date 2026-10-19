// One HTTP GET helper: body and status. Each use picks its timeout and
// User-Agent; tests inject their own closure of the same shape.

import Foundation

enum HTTPFetch {

    typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    static func download(
        timeout: TimeInterval,
        resourceTimeout: TimeInterval? = nil,
        userAgent: String? = nil
    ) -> Fetch {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        if let resourceTimeout { config.timeoutIntervalForResource = resourceTimeout }
        if let userAgent { config.httpAdditionalHeaders = ["User-Agent": userAgent] }
        let session = URLSession(configuration: config)
        return { url in
            let (data, response) = try await session.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}
