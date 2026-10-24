import Foundation

enum RetryAfter {

    static let longest: TimeInterval = 24 * 3600

    // RFC 9110: delay-seconds or an HTTP-date (IMF-fixdate, RFC 850, asctime)
    static func seconds(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return Int(value).map { min(TimeInterval($0), longest) } ?? longest
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return min(max(0, date.timeIntervalSince(now)), longest)
            }
        }
        return nil
    }
}

struct HTTPBackoff: Sendable {

    var base: TimeInterval = 30
    var cap: TimeInterval = 3600

    static func throttles(_ status: Int) -> Bool { status == 429 || status == 503 }

    // Equal jitter: half the doubled delay fixed, half random; a later Retry-After wins
    func delay(attempt: Int, retryAfter: TimeInterval? = nil, jitter: Double = .random(in: 0..<1)) -> TimeInterval {
        let doubled = min(cap, base * pow(2, Double(max(0, min(attempt - 1, 30)))))
        let backoff = doubled / 2 + doubled / 2 * min(max(jitter, 0), 1)
        return max(backoff, retryAfter ?? 0)
    }
}

// A host that answered 429 or 503 is left alone until its delay is over
actor HTTPCooldown {

    static let shared = HTTPCooldown()

    private struct Pause {
        var until: Date
        var strikes: Int
    }

    private let backoff: HTTPBackoff
    private var paused: [String: Pause] = [:]

    init(backoff: HTTPBackoff = HTTPBackoff()) {
        self.backoff = backoff
    }

    private static func key(_ url: URL) -> String { url.host()?.lowercased() ?? url.absoluteString }

    func isPaused(_ url: URL, now: Date = Date()) -> Bool {
        guard let pause = paused[Self.key(url)] else { return false }
        return now < pause.until
    }

    @discardableResult
    func note(_ url: URL, status: Int, retryAfter: String?, now: Date = Date(),
              jitter: Double = .random(in: 0..<1)) -> TimeInterval? {
        let key = Self.key(url)
        guard HTTPBackoff.throttles(status) else {
            paused[key] = nil
            return nil
        }
        let strikes = (paused[key]?.strikes ?? 0) + 1
        let delay = backoff.delay(attempt: strikes, retryAfter: RetryAfter.seconds(retryAfter, now: now), jitter: jitter)
        paused[key] = Pause(until: now.addingTimeInterval(delay), strikes: strikes)
        return delay
    }
}
