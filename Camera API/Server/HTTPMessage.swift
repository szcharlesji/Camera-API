import Foundation

// MARK: - Request

/// A parsed HTTP/1.1 request. Header names are normalised to lowercase.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// HTTP/1.1 defaults to persistent connections unless the client opts out.
    var wantsKeepAlive: Bool {
        guard let value = header("connection")?.lowercased() else { return true }
        return !value.contains("close")
    }

    func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
        guard !body.isEmpty else {
            throw APIError.badRequest("Request body is empty; expected a JSON object.")
        }
        do {
            return try JSONDecoder().decode(T.self, from: body)
        } catch {
            throw APIError.badRequest("Malformed JSON body: \(error.localizedDescription)")
        }
    }

    func queryString(_ name: String) -> String? { query[name] }
    func queryInt(_ name: String) -> Int? { query[name].flatMap { Int($0) } }
    func queryDouble(_ name: String) -> Double? { query[name].flatMap { Double($0) } }

    func queryBool(_ name: String) -> Bool? {
        guard let raw = query[name]?.lowercased() else { return nil }
        switch raw {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }
}

// MARK: - Byte ranges

/// A resolved `Range:` header, already clamped to the size of the target file.
struct HTTPByteRange {
    let start: UInt64
    let end: UInt64  // inclusive

    var length: UInt64 { end - start + 1 }

    /// Parses a single-range `bytes=` header. Multi-range requests are not supported
    /// and are reported as `nil` so the caller can fall back to a full-body response.
    static func parse(_ header: String, totalSize: UInt64) -> HTTPByteRange? {
        guard totalSize > 0 else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("bytes=") else { return nil }

        let spec = String(trimmed.dropFirst("bytes=".count))
        guard !spec.contains(",") else { return nil }

        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let lower = parts[0].trimmingCharacters(in: .whitespaces)
        let upper = parts[1].trimmingCharacters(in: .whitespaces)

        if lower.isEmpty {
            // Suffix form: "bytes=-500" means the final 500 bytes.
            guard let suffix = UInt64(upper), suffix > 0 else { return nil }
            let length = min(suffix, totalSize)
            return HTTPByteRange(start: totalSize - length, end: totalSize - 1)
        }

        guard let start = UInt64(lower), start < totalSize else { return nil }
        let end = upper.isEmpty ? totalSize - 1 : min(UInt64(upper) ?? (totalSize - 1), totalSize - 1)
        guard end >= start else { return nil }
        return HTTPByteRange(start: start, end: end)
    }
}

// MARK: - Response

/// Receives bytes for a response whose length is not known up front (MJPEG, SSE).
/// The connection hands one of these to a handler after the status line and headers
/// have been flushed.
protocol HTTPResponseWriter: AnyObject, Sendable {
    var isOpen: Bool { get }
    func write(_ data: Data, completion: (@Sendable (Bool) -> Void)?)
    func finish()
    /// Registers a callback fired once when the peer goes away or `finish()` is called.
    func onClose(_ handler: @escaping @Sendable () -> Void)
}

extension HTTPResponseWriter {
    func write(_ data: Data) { write(data, completion: nil) }
}

enum HTTPResponseBody {
    case empty
    case data(Data)
    /// Streams a file from disk, honouring an already-resolved byte range.
    case file(url: URL, range: HTTPByteRange?, totalSize: UInt64)
    /// Hands the connection to a handler for an open-ended response.
    case hijack(@Sendable (any HTTPResponseWriter) -> Void)
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: HTTPResponseBody

    init(status: Int = 200, headers: [String: String] = [:], body: HTTPResponseBody = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data(#"{"error":"encoding_failed"}"#.utf8)
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: .data(data)
        )
    }

    static func text(_ string: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": contentType], body: .data(Data(string.utf8)))
    }

    static func error(_ error: APIError) -> HTTPResponse {
        .json(APIErrorPayload(error: error.code, message: error.message), status: error.status)
    }

    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status \(status)"
        }
    }
}

// MARK: - Errors

struct APIErrorPayload: Encodable {
    let error: String
    let message: String
}

struct APIError: Error {
    let status: Int
    let code: String
    let message: String

    static func badRequest(_ message: String) -> APIError {
        APIError(status: 400, code: "bad_request", message: message)
    }
    static func unauthorized(_ message: String) -> APIError {
        APIError(status: 401, code: "unauthorized", message: message)
    }
    static func notFound(_ message: String) -> APIError {
        APIError(status: 404, code: "not_found", message: message)
    }
    static func methodNotAllowed(_ message: String) -> APIError {
        APIError(status: 405, code: "method_not_allowed", message: message)
    }
    static func conflict(_ message: String) -> APIError {
        APIError(status: 409, code: "conflict", message: message)
    }
    static func rangeNotSatisfiable(_ message: String) -> APIError {
        APIError(status: 416, code: "range_not_satisfiable", message: message)
    }
    static func internalError(_ message: String) -> APIError {
        APIError(status: 500, code: "internal_error", message: message)
    }
    static func unavailable(_ message: String) -> APIError {
        APIError(status: 503, code: "unavailable", message: message)
    }
}

// MARK: - Parsing

/// Incremental HTTP/1.1 request parser. Feed it bytes as they arrive; it yields a
/// request once the headers and the declared body have both been received.
struct HTTPRequestParser {
    enum ParseError: Error {
        case malformedRequestLine
        case headersTooLarge
        case bodyTooLarge
        case unsupportedTransferEncoding
    }

    /// Guards against a peer that opens a connection and never sends a blank line.
    static let maxHeaderBytes = 64 * 1024
    /// Every request body this API accepts is a small JSON object.
    static let maxBodyBytes = 4 * 1024 * 1024

    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete request, or `nil` if more bytes are needed.
    mutating func next() throws -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.firstRange(of: separator) else {
            if buffer.count > Self.maxHeaderBytes { throw ParseError.headersTooLarge }
            return nil
        }

        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw ParseError.malformedRequestLine
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw ParseError.malformedRequestLine }

        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { throw ParseError.malformedRequestLine }

        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if let encoding = headers["transfer-encoding"], encoding.lowercased().contains("chunked") {
            // Nothing in this API needs a streamed request body, and supporting chunked
            // decoding would add a parser for no benefit.
            throw ParseError.unsupportedTransferEncoding
        }

        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        guard contentLength >= 0 else { throw ParseError.malformedRequestLine }
        guard contentLength <= Self.maxBodyBytes else { throw ParseError.bodyTooLarge }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        let (path, query) = Self.splitTarget(target)
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let questionMark = target.firstIndex(of: "?") else {
            return (percentDecode(target), [:])
        }
        let path = percentDecode(String(target[target.startIndex..<questionMark]))
        let queryString = String(target[target.index(after: questionMark)...])

        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = percentDecode(String(parts[0]).replacingOccurrences(of: "+", with: " "))
            guard !key.isEmpty else { continue }
            let value = parts.count > 1
                ? percentDecode(String(parts[1]).replacingOccurrences(of: "+", with: " "))
                : ""
            query[key] = value
        }
        return (path, query)
    }

    private static func percentDecode(_ string: String) -> String {
        string.removingPercentEncoding ?? string
    }
}
