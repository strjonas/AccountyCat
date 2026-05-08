#!/usr/bin/env swift

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count >= 2 else {
    fail("usage: swift summarize-bundle.swift /path/to/agent-debug-bundle")
}

let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let summaryURL = bundleURL.appendingPathComponent("summary.json")
let indexURL = bundleURL.appendingPathComponent("inspector_index_summary.json")

func loadJSON(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url) else { fail("missing \(url.path)") }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fail("invalid JSON at \(url.path)")
    }
    return json
}

func dictionary(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
}

func array(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
}

func string(_ value: Any?) -> String {
    if let value = value as? String { return value }
    if let value { return "\(value)" }
    return ""
}

func printMap(_ title: String, _ map: [String: Any]) {
    print("\n## \(title)")
    if map.isEmpty {
        print("- none")
        return
    }
    for key in map.keys.sorted() {
        print("- \(key): \(map[key] ?? "")")
    }
}

let summary = loadJSON(summaryURL)
let index = loadJSON(indexURL)

print("# AC Agent Debug Bundle")
print("")
print("- Bundle: \(bundleURL.path)")
print("- Exported: \(string(summary["exportedAt"]))")
print("- Session: \(string(summary["sessionID"]))")
print("- Failures: \(string(summary["failureCount"]))")
print("- Episodes indexed: \(string(index["episodeCount"]))")

printMap("Event Counts", dictionary(summary["eventCounts"]))
printMap("LLM Calls", dictionary(summary["llmInteractionCounts"]))
printMap("Skip Reasons", dictionary(summary["skipReasons"]))
printMap("Decision Mix", dictionary(summary["decisionMix"]))
printMap("Actions", dictionary(summary["actionCounts"]))

print("\n## Recent Failures")
for item in array(summary["recentFailures"]).prefix(8) {
    let object = dictionary(item)
    print("- \(string(object["timestamp"])) \(string(object["kind"])) \(string(object["episodeID"])) :: \(string(object["message"]))")
}
if array(summary["recentFailures"]).isEmpty {
    print("- none")
}

print("\n## Recent LLM Interactions")
for item in array(summary["recentLLMInteractions"]).prefix(10) {
    let object = dictionary(item)
    let failure = string(object["failure"])
    let suffix = failure.isEmpty ? "" : " failure=\(failure)"
    print("- \(string(object["timestamp"])) \(string(object["kind"])) \(string(object["interactionID"])) :: \(string(object["summary"]))\(suffix)")
}

print("\n## Next Files")
print("- `inspector_index_summary.json` for episode rows and artifact paths")
print("- `current_state_redacted.json` for profile/rule/memory/config state")
print("- `activity.log` for human-readable breadcrumbs")
