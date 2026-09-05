import Foundation
import CoreFoundation

public struct PiJSONParser {
    public private(set) var text = ""
    public private(set) var completed = false
    public private(set) var failed = false
    public private(set) var toolCalls: [String] = []
    public var inputTokens: Int? { usageKnown && assistantMessages > 0 ? totalInput : nil }
    public var outputTokens: Int? { usageKnown && assistantMessages > 0 ? totalOutput : nil }
    private var assistantMessages = 0
    private var usageKnown = true
    private var totalInput = 0
    private var totalOutput = 0
    private var pending = ""
    private let maxBytes: Int

    public init(maxBytes: Int = 5_000_000) { self.maxBytes = max(1, maxBytes) }

    public mutating func parse(_ chunk: String) -> [String] {
        pending += chunk
        guard pending.utf8.count <= max(maxBytes, 1_048_576) else {
            failed = true; pending = ""; return []
        }
        var deltas: [String] = []
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            if let delta = consume(line) { deltas.append(delta) }
        }
        return deltas
    }

    public mutating func finish() {
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { _ = consume(pending) }
        pending = ""
    }

    private mutating func consume(_ line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { failed = true; return nil }
        if type == "message_update", let event = json["assistantMessageEvent"] as? [String: Any],
           event["type"] as? String == "text_delta", let delta = event["delta"] as? String {
            guard text.utf8.count + delta.utf8.count <= maxBytes else { failed = true; return nil }
            text += delta
            return delta
        }
        if type == "tool_execution_start", let name = json["toolName"] as? String { toolCalls.append(name) }
        if type == "message_end", let message = json["message"] as? [String: Any],
           message["role"] as? String == "assistant" {
            recordUsage(message)
            if ["error", "aborted"].contains(message["stopReason"] as? String ?? "") { failed = true }
        }
        if type == "agent_end" {
            let messages = json["messages"] as? [[String: Any]] ?? []
            let final = messages.last { $0["role"] as? String == "assistant" }
            if assistantMessages == 0 {
                for message in messages where message["role"] as? String == "assistant" { recordUsage(message) }
            }
            completed = final?["stopReason"] as? String == "stop"
            if !completed { failed = true }
            if text.isEmpty, let content = final?["content"] as? [[String: Any]] {
                let finalText = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                guard finalText.utf8.count <= maxBytes else { failed = true; return nil }
                text = finalText
                return finalText.isEmpty ? nil : finalText
            }
        }
        return nil
    }

    private mutating func recordUsage(_ message: [String: Any]) {
        assistantMessages += 1
        guard let usage = message["usage"] as? [String: Any],
              let input = Self.tokenCount(usage["input"]), let output = Self.tokenCount(usage["output"]),
              let cacheRead = Self.tokenCount(usage["cacheRead"] ?? 0),
              let cacheWrite = Self.tokenCount(usage["cacheWrite"] ?? 0) else { usageKnown = false; return }
        // Pi initializes absent provider usage to zero; do not call that measured zero consumption.
        guard input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 else { usageKnown = false; return }
        for count in [input, cacheRead, cacheWrite] {
            let (sum, overflow) = totalInput.addingReportingOverflow(count)
            guard !overflow else { usageKnown = false; return }
            totalInput = sum
        }
        let (sum, overflow) = totalOutput.addingReportingOverflow(output)
        guard !overflow else { usageKnown = false; return }
        totalOutput = sum
    }

    private static func tokenCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let count = Int(exactly: number.doubleValue), count >= 0 else { return nil }
        return count
    }
}
