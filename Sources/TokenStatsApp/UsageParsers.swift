import Foundation

private enum JSONValue {
    static func dictionary(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func int(_ dictionary: [String: Any], _ key: String) -> Int {
        if let value = dictionary[key] as? Int { return value }
        if let value = dictionary[key] as? NSNumber { return value.intValue }
        return 0
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return isoDate(string)
    }
}

/// Logs hold hundreds of thousands of timestamps, so the parse styles are made once.
private let fractionalISO = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
private let wholeSecondISO = Date.ISO8601FormatStyle()

func isoDate(_ string: String) -> Date? {
    (try? fractionalISO.parse(string)) ?? (try? wholeSecondISO.parse(string))
}

enum CodexUsageParser {
    static func parse(lines: [String], sourceID: String) -> [UsageRecord] {
        var records: [UsageRecord] = []
        var currentModel = "unknown-codex-model"
        var previous: [String: Int] = [:]

        for (index, line) in lines.enumerated() {
            let root = JSONValue.dictionary(line)
            if line.contains(#""type":"turn_context""#) {
                if let payload = root?["payload"] as? [String: Any],
                   let model = payload["model"] as? String {
                    currentModel = model
                } else if let model = capture(#""model":"([^"]+)""#, in: line) {
                    // The streaming reader intentionally caps turn_context
                    // lines. The model lives near the start, while the rest can
                    // contain megabytes of instructions that are irrelevant.
                    currentModel = model
                }
                continue
            }
            guard let root else { continue }
            guard root["type"] as? String == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let date = JSONValue.date(root["timestamp"]) else {
                continue
            }

            let totalInput = JSONValue.int(total, "input_tokens")
            let cached = JSONValue.int(total, "cached_input_tokens")
            let write = JSONValue.int(total, "cache_write_input_tokens")
            let output = JSONValue.int(total, "output_tokens")
            let deltaInput = max(0, totalInput - (previous["input"] ?? 0))
            let deltaCached = max(0, cached - (previous["cached"] ?? 0))
            let deltaWrite = max(0, write - (previous["write"] ?? 0))
            let deltaOutput = max(0, output - (previous["output"] ?? 0))
            previous = ["input": totalInput, "cached": cached, "write": write, "output": output]

            // Codex input_tokens includes cached input. Split it so cost math
            // cannot accidentally charge cached tokens at the full rate.
            records.append(UsageRecord(
                id: "\(sourceID):\(index)",
                date: date,
                provider: .codex,
                model: currentModel,
                inputTokens: max(0, deltaInput - deltaCached),
                cachedInputTokens: deltaCached,
                cacheWriteTokens: deltaWrite,
                outputTokens: deltaOutput
            ))
        }
        return records
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[range])
    }
}

enum ClaudeUsageParser {
    /// Only assistant lines carry usage, and they're a fraction of a session log.
    static let marker = #""type":"assistant""#

    static func parse(fileAt url: URL) -> [UsageRecord] {
        var parser = Accumulator(sourceID: url.path)
        JSONLReader.forEachLine(at: url, containing: marker) { parser.add($0) }
        return parser.records
    }

    static func parse(lines: [String], sourceID: String) -> [UsageRecord] {
        var parser = Accumulator(sourceID: sourceID)
        for line in lines where line.contains(marker) { parser.add(Data(line.utf8)) }
        return parser.records
    }

    /// Claude Code writes a streamed message several times as it grows, so each message ID
    /// keeps its biggest version.
    struct Accumulator {
        let sourceID: String
        private var best: [String: UsageRecord] = [:]
        private var index = 0
        private let decoder = JSONDecoder()

        init(sourceID: String) { self.sourceID = sourceID }

        mutating func add(_ line: Data) {
            defer { index += 1 }
            guard let entry = try? decoder.decode(LogLine.self, from: line),
                  entry.type == "assistant",
                  let message = entry.message,
                  let usage = message.usage,
                  let date = entry.timestamp.flatMap(isoDate) else { return }
            let messageID = message.id ?? "\(sourceID):\(index)"
            let record = UsageRecord(
                id: "\(sourceID):\(messageID)",
                date: date,
                provider: .claude,
                model: message.model ?? "unknown-claude-model",
                inputTokens: usage.input_tokens ?? 0,
                cachedInputTokens: usage.cache_read_input_tokens ?? 0,
                cacheWriteTokens: usage.cache_creation_input_tokens ?? 0,
                outputTokens: usage.output_tokens ?? 0
            )
            if record.totalTokens >= best[messageID]?.totalTokens ?? -1 {
                best[messageID] = record
            }
        }

        var records: [UsageRecord] { best.values.sorted { $0.date < $1.date } }
    }

    /// Just the fields Token Stats reads. Everything else in the line, including message
    /// content, is skipped without being built.
    private struct LogLine: Decodable {
        let type: String?
        let timestamp: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let input_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let output_tokens: Int?
        }
    }
}

enum OpenRouterCSVError: LocalizedError {
    case missingHeaders

    var errorDescription: String? {
        "That CSV does not look like an OpenRouter Activity export."
    }
}

enum OpenRouterCSVParser {
    static func parse(csv: String, sourceID: String) throws -> [UsageRecord] {
        let rows = CSV.rows(csv)
        guard let rawHeaders = rows.first else { throw OpenRouterCSVError.missingHeaders }
        let headers = rawHeaders.map(normalize)
        guard let dateIndex = index(in: headers, matching: ["date", "time", "timestamp", "period"]),
              let modelIndex = index(in: headers, matching: ["model"]) else {
            throw OpenRouterCSVError.missingHeaders
        }
        let promptIndex = index(in: headers, matching: ["prompttokens", "inputtokens", "tokensprompt"])
        let completionIndex = index(in: headers, matching: ["completiontokens", "outputtokens", "tokenscompletion"])
        let totalTokensIndex = index(in: headers, matching: ["totaltokens", "tokens"])
        let costIndex = index(in: headers, matching: ["totalcost", "cost", "spend", "usage"])

        return rows.dropFirst().enumerated().compactMap { offset, row in
            guard row.indices.contains(dateIndex), row.indices.contains(modelIndex),
                  let date = parseDate(row[dateIndex]) else { return nil }
            let input = promptIndex.flatMap { row.indices.contains($0) ? parseInteger(row[$0]) : nil } ?? 0
            let output = completionIndex.flatMap { row.indices.contains($0) ? parseInteger(row[$0]) : nil } ?? 0
            let total = totalTokensIndex.flatMap { row.indices.contains($0) ? parseInteger(row[$0]) : nil } ?? 0
            let adjustedInput = input == 0 && output == 0 ? total : input
            let cost = costIndex.flatMap { row.indices.contains($0) ? parseDouble(row[$0]) : nil }
            return UsageRecord(
                id: "\(sourceID):\(offset)",
                date: date,
                provider: .openRouter,
                model: row[modelIndex],
                inputTokens: adjustedInput,
                cachedInputTokens: 0,
                cacheWriteTokens: 0,
                outputTokens: output,
                exactCostUSD: cost
            )
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func index(in headers: [String], matching candidates: [String]) -> Int? {
        candidates.compactMap { headers.firstIndex(of: $0) }.first
    }

    private static func parseInteger(_ value: String) -> Int? {
        Int(value.filter { $0.isNumber || $0 == "-" })
    }

    private static func parseDouble(_ value: String) -> Double? {
        Double(value.filter { $0.isNumber || $0 == "." || $0 == "-" })
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = JSONValue.date(value) { return date }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "MMM d, yyyy", "d MMM yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

private enum CSV {
    static func rows(_ text: String) -> [[String]] {
        var result: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    quoted.toggle()
                }
            } else if character == ",", !quoted {
                row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else if character == "\n", !quoted {
                row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                if row.contains(where: { !$0.isEmpty }) { result.append(row) }
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
            index += 1
        }
        row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        if row.contains(where: { !$0.isEmpty }) { result.append(row) }
        return result
    }
}
