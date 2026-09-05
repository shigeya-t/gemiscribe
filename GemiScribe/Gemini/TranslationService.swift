import Foundation
import OSLog

/// Translation through the ordinary `generateContent` endpoint.
///
/// Requests carry several blocks at once. One call per block is the obvious design and
/// the one that gets rate-limited within minutes — a talkative meeting finalizes a block
/// every few seconds, and the free tier counts requests, not tokens. Batching keeps a
/// long recording comfortably inside the quota.
///
/// Each block is translated on its own. Two attempts at giving the model surrounding
/// context — first the neighbouring source text, then its own earlier output — both
/// ended the same way: the context came back as part of the answer, so every block's
/// translation restated the ones before it and grew without bound. No wording of the
/// instruction stopped it. Whole blocks (see `BlockAssembler`) carry enough of their
/// own grammar to translate well; a running commentary of the previous minute does not
/// earn the risk.
struct TranslationService {

    /// Failures are logged unconditionally at `.error`, so `log show` can explain a
    /// "translation failed" badge after the fact without the user having reproduced it
    /// with debug logging switched on.
    private static let logger = Logger(subsystem: "jp.namio.GemiScribe", category: "translation")

    struct BatchRequest {
        var apiKey: String
        var model: String
        /// Blocks to translate, in transcript order.
        var texts: [String]
        var target: AppLanguage
        /// Mirrors the Settings toggle; also logs the prompt and the raw response.
        var debugLogging: Bool = false
    }

    enum TranslationError: LocalizedError {
        case missingAPIKey
        case badResponse(String)
        case http(Int, String)
        /// HTTP 429. `retryAfter` comes from the service's own RetryInfo when present.
        case rateLimited(retryAfter: TimeInterval?, message: String)
        case countMismatch(expected: Int, received: Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "No Gemini API key is set."
            case .badResponse(let message): return message
            case .http(let code, let message):
                return message.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(message)"
            case .rateLimited(_, let message):
                return message.isEmpty ? "HTTP 429: rate limit exceeded" : "HTTP 429: \(message)"
            case .countMismatch(let expected, let received):
                return "The model returned \(received) translations for \(expected) blocks."
            case .empty: return "The model returned no text."
            }
        }
    }

    // MARK: - Translation

    static func translate(_ request: BatchRequest) async throws -> [String] {
        guard !request.apiKey.isEmpty else { throw TranslationError.missingAPIKey }
        guard !request.texts.isEmpty else { return [] }

        let instruction = """
        You are a translation engine inside a live transcription app.
        Translate each numbered entry below into \(request.target.englishName). \
        Translate only what is given; add nothing.
        The text is speech as it was spoken, so entries may start or end mid-sentence. \
        Translate the fragment as it stands rather than completing it.
        Preserve each speaker's tone and keep proper nouns intact. If an entry is already \
        in \(request.target.englishName), repeat it unchanged.
        Answer with a JSON array of exactly \(request.texts.count) \
        \(request.texts.count == 1 ? "string: the translation of entry 1" : "strings: the translations of entries 1…\(request.texts.count), in order"). \
        Nothing else — no labels, no notes, no numbering.
        """

        let prompt = request.texts.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instruction]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            // A response schema keeps entry N of the reply aligned with block N of the
            // request; a free-form numbered list silently misaligns when the model
            // merges or splits an entry.
            "generationConfig": [
                "candidateCount": 1,
                "responseMimeType": "application/json",
                "responseSchema": ["type": "ARRAY", "items": ["type": "STRING"]],
            ],
        ]

        if request.debugLogging {
            logger.notice("→ translate model=\(request.model, privacy: .public) target=\(request.target.rawValue, privacy: .public) count=\(request.texts.count, privacy: .public)")
        }

        let data = try await post(model: request.model,
                                  apiKey: request.apiKey,
                                  body: body,
                                  debugLogging: request.debugLogging)

        guard let text = firstText(in: data) else {
            logger.error("Translation returned no text (model=\(request.model, privacy: .public)): \(String(decoding: data.prefix(500), as: UTF8.self), privacy: .public)")
            throw TranslationError.empty
        }
        guard let translations = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else {
            logger.error("Translation was not a JSON array: \(text.prefix(500), privacy: .public)")
            throw TranslationError.badResponse("The model did not return a JSON array.")
        }
        guard translations.count == request.texts.count else {
            logger.error("Translation count mismatch: expected \(request.texts.count), got \(translations.count)")
            throw TranslationError.countMismatch(expected: request.texts.count,
                                                 received: translations.count)
        }
        return translations
    }

    /// Cheap round-trip used by the Settings "Test connection" button.
    static func verify(apiKey: String, model: String) async throws {
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": "Reply with: ok"]]]],
            "generationConfig": ["maxOutputTokens": 16],
        ]
        _ = try await post(model: model, apiKey: apiKey, body: body, debugLogging: false)
    }

    // MARK: - Transport

    private static func post(model: String,
                             apiKey: String,
                             body: [String: Any],
                             debugLogging: Bool) async throws -> Data {
        let name = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        guard var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent"
        ) else {
            throw TranslationError.badResponse("Could not build the request URL.")
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw TranslationError.badResponse("Could not build the request URL.")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 60

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            logger.error("Translation request failed (model=\(name, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            logger.error("Translation got a non-HTTP response (model=\(name, privacy: .public))")
            throw TranslationError.badResponse("Unexpected response from the API.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = apiErrorMessage(in: data)
            logger.error("Translation HTTP \(http.statusCode, privacy: .public) (model=\(name, privacy: .public)): \(message, privacy: .public)")
            if http.statusCode == 429 {
                throw TranslationError.rateLimited(retryAfter: retryDelay(in: data, header: http),
                                                   message: message)
            }
            throw TranslationError.http(http.statusCode, message)
        }
        if debugLogging {
            logger.notice("← \(String(decoding: data.prefix(2000), as: UTF8.self), privacy: .public)")
        }
        return data
    }

    private static func firstText(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { return nil }

        let text = parts.compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func apiErrorMessage(in data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return String(decoding: data.prefix(300), as: UTF8.self) }
        return message
    }

    /// The wait the service itself asks for, so a retry does not simply fail again.
    /// Prefers `google.rpc.RetryInfo`, then `Retry-After`, then the prose in the message.
    static func retryDelay(in data: Data, header: HTTPURLResponse?) -> TimeInterval? {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let details = error["details"] as? [[String: Any]] {
            for detail in details {
                if let delay = detail["retryDelay"] as? String,
                   let seconds = protobufDuration(delay) {
                    return seconds
                }
            }
        }
        if let retryAfter = header?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(retryAfter) {
            return seconds
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            return retrySecondsInMessage(message)
        }
        return nil
    }

    /// e.g. "23s", "1.5s"
    static func protobufDuration(_ value: String) -> TimeInterval? {
        Double(value.hasSuffix("s") ? String(value.dropLast()) : value)
    }

    /// e.g. "Please retry in 23.794836036s."
    static func retrySecondsInMessage(_ message: String) -> TimeInterval? {
        guard let range = message.range(of: #"retry in ([0-9.]+)s"#,
                                        options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let digits = message[range].filter { $0.isNumber || $0 == "." }
        return Double(digits)
    }
}
