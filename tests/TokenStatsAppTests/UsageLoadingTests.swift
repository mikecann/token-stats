import XCTest
@testable import TokenStatsApp

final class UsageLoadingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ lines: [String], trailingNewline: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8).write(to: url)
        return url
    }

    private func assistant(_ id: String, output: Int, at time: String = "2026-07-25T02:00:00.123Z") -> String {
        #"{"parentUuid":null,"message":{"model":"claude-opus-4-8","id":"\#(id)","type":"message","role":"assistant","content":[{"type":"tool_use","input":{"model":"haiku","usage":{"output_tokens":999}}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":200,"output_tokens":\#(output)}},"type":"assistant","timestamp":"\#(time)"}"#
    }

    func testLineReaderOnlyKeepsMatchingLinesAcrossChunkBoundaries() throws {
        let long = String(repeating: "x", count: 5_000)
        let url = try write("session.jsonl", [
            #"{"type":"user","text":"\#(long)"}"#,
            #"{"type":"assistant","text":"\#(long)"}"#,
            #"{"type":"assistant","n":2}"#
        ], trailingNewline: false)

        var lines: [String] = []
        JSONLReader.forEachLine(at: url, containing: #""type":"assistant""#, chunkSize: 1_024) {
            lines.append(String(decoding: $0, as: UTF8.self))
        }

        XCTAssertEqual(lines, [#"{"type":"assistant","text":"\#(long)"}"#, #"{"type":"assistant","n":2}"#])
    }

    func testClaudeFileParserReadsUsageFromMessageNotToolInput() throws {
        let url = try write("session.jsonl", [
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            assistant("msg_1", output: 2),
            assistant("msg_1", output: 52, at: "2026-07-25T02:00:01Z"),
            "not json but mentions \"type\":\"assistant\"",
            assistant("msg_2", output: 7, at: "2026-07-25T02:00:02.5Z")
        ])

        let records = ClaudeUsageParser.parse(fileAt: url)

        XCTAssertEqual(records.map(\.id), ["\(url.path):msg_1", "\(url.path):msg_2"])
        XCTAssertEqual(records[0].model, "claude-opus-4-8")
        XCTAssertEqual(records[0].outputTokens, 52)
        XCTAssertEqual(records[0].cacheWriteTokens, 100)
        XCTAssertEqual(records[0].cachedInputTokens, 200)
        XCTAssertEqual(records[0].date.timeIntervalSince1970, 1_784_944_801, accuracy: 0.001)
        XCTAssertEqual(records[1].date.timeIntervalSince1970, 1_784_944_802.5, accuracy: 0.001)
    }

    func testIndexOnlyReparsesChangedFilesAndForgetsDeletedOnes() throws {
        let indexURL = directory.appendingPathComponent("index.json")
        let first = try write("a.jsonl", [assistant("msg_a", output: 1)])
        let second = try write("b.jsonl", [assistant("msg_b", output: 2)])
        var parsed: [String] = []
        let parse: ([URL]) -> [String: [UsageRecord]] = { urls in
            parsed += urls.map(\.lastPathComponent)
            return Dictionary(uniqueKeysWithValues: urls.map { ($0.path, ClaudeUsageParser.parse(fileAt: $0)) })
        }

        let index = UsageFileIndex(url: indexURL, provider: .claude)
        XCTAssertEqual(index.load(files: [first, second], parse: parse).count, 2)
        XCTAssertEqual(parsed.sorted(), ["a.jsonl", "b.jsonl"])

        // A fresh index reads what the last one saved, so nothing is parsed again.
        parsed = []
        let reopened = UsageFileIndex(url: indexURL, provider: .claude)
        let cached = reopened.load(files: [first, second], parse: parse)
        XCTAssertEqual(parsed, [])
        XCTAssertEqual(
            cached.sorted { $0.id < $1.id },
            (ClaudeUsageParser.parse(fileAt: first) + ClaudeUsageParser.parse(fileAt: second)).sorted { $0.id < $1.id }
        )

        _ = try write("b.jsonl", [assistant("msg_b", output: 2), assistant("msg_c", output: 3)])
        try FileManager.default.removeItem(at: first)
        let updated = reopened.load(files: [second], parse: parse)
        XCTAssertEqual(parsed, ["b.jsonl"])
        XCTAssertEqual(updated.map(\.id).sorted(), ["\(second.path):msg_b", "\(second.path):msg_c"])
    }
}
