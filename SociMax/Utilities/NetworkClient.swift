import Foundation

enum NetworkError: LocalizedError {
    case invalidURL
    case requestFailed(Int)
    case decodingError(Error)
    case noData
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid URL"
        case .requestFailed(let code): "Request failed with status \(code)"
        case .decodingError(let error): "Decoding error: \(error.localizedDescription)"
        case .noData: "No data received"
        case .unknown(let error): "Unknown error: \(error.localizedDescription)"
        }
    }
}

final class NetworkClient {
    static let shared = NetworkClient()
    private let session: URLSession
    private let limiter = ConcurrencyLimiter(maxConcurrent: 5)

    // MARK: - User-Agent Rotation

    private static let userAgents: [String] = [
        // Chrome (Windows)
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
        // Chrome (macOS)
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
        // Firefox (Windows)
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 Firefox/131.0",
        // Firefox (macOS)
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:133.0) Gecko/20100101 Firefox/133.0",
        // Safari (macOS)
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
        // Edge (Windows)
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0",
        // Chrome (Linux)
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        // Chrome (Android)
        "Mozilla/5.0 (Linux; Android 14; SM-S928B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
    ]

    private static func randomUserAgent() -> String {
        userAgents.randomElement()!
    }

    private init() {
        let config = URLSessionConfiguration.ephemeral   // no disk/memory cache
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.urlCache = nil                             // fully disable caching
        config.httpMaximumConnectionsPerHost = 2          // limit per-host connections
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func fetch(url urlString: String, retryPolicy: RetryPolicy = .default) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(Self.randomUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        var lastError: Error = NetworkError.noData
        for attempt in 0..<retryPolicy.maxAttempts {
            do {
                let (data, response) = try await limiter.withLimit {
                    try await self.session.data(for: request)
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.noData
                }
                if (200...299).contains(httpResponse.statusCode) {
                    // Limit response size to 512KB to prevent memory explosion
                    let limitedData = data.count > 512_000 ? data.prefix(512_000) : data
                    guard let html = String(data: limitedData, encoding: .utf8) else {
                        throw NetworkError.noData
                    }
                    return html
                }
                if retryPolicy.shouldRetry(statusCode: httpResponse.statusCode, attempt: attempt) {
                    let delay = retryPolicy.delay(for: attempt)
                    FileLogger.shared.log("HTTP \(httpResponse.statusCode) from \(urlString), retry in \(String(format: "%.1f", delay))s (\(attempt+1)/\(retryPolicy.maxAttempts))")
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw NetworkError.requestFailed(httpResponse.statusCode)
            } catch let error as NetworkError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < retryPolicy.maxAttempts - 1 {
                    let delay = retryPolicy.delay(for: attempt)
                    FileLogger.shared.log("Network error from \(urlString): \(error.localizedDescription), retry in \(String(format: "%.1f", delay))s")
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw NetworkError.unknown(lastError)
    }

    func postJSON<T: Decodable>(
        url urlString: String,
        headers: [String: String] = [:],
        body: [String: Any],
        retryPolicy: RetryPolicy = .default
    ) async throws -> T {
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error = NetworkError.noData
        for attempt in 0..<retryPolicy.maxAttempts {
            do {
                let (data, response) = try await limiter.withLimit {
                    try await self.session.data(for: request)
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.noData
                }
                if (200...299).contains(httpResponse.statusCode) {
                    do {
                        return try JSONDecoder().decode(T.self, from: data)
                    } catch {
                        throw NetworkError.decodingError(error)
                    }
                }
                let responseBody = String(data: data, encoding: .utf8) ?? "no body"
                if retryPolicy.shouldRetry(statusCode: httpResponse.statusCode, attempt: attempt) {
                    let delay = retryPolicy.delay(for: attempt)
                    FileLogger.shared.log("HTTP \(httpResponse.statusCode) from \(urlString): \(responseBody), retry in \(String(format: "%.1f", delay))s (\(attempt+1)/\(retryPolicy.maxAttempts))")
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                FileLogger.shared.log("HTTP \(httpResponse.statusCode) from \(urlString): \(responseBody)")
                throw NetworkError.requestFailed(httpResponse.statusCode)
            } catch let error as NetworkError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < retryPolicy.maxAttempts - 1 {
                    let delay = retryPolicy.delay(for: attempt)
                    FileLogger.shared.log("Network error from \(urlString): \(error.localizedDescription), retry in \(String(format: "%.1f", delay))s")
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw NetworkError.unknown(lastError)
    }
}
