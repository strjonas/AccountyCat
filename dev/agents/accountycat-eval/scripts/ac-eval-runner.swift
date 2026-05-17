#!/usr/bin/env swift

import Darwin
import Foundation

struct Arguments {
    var command: String = "list"
    var json = false
    var kind: String?
    var importances: Set<String> = []
    var categories: Set<String> = []
    var ids: [String] = []
    var backend = "local"
    var onlineModel: String?
    var limit: Int?
    var root: String?
    var supportDir: String?
    var runtimePath: String?

    init(_ raw: [String]) {
        var index = 0
        if let first = raw.first, !first.hasPrefix("--") {
            command = first
            index = 1
        }

        while index < raw.count {
            let token = raw[index]
            switch token {
            case "--json":
                json = true
                index += 1
            case "--kind":
                kind = Self.value(after: token, raw: raw, index: &index)
            case "--importance":
                importances = Self.csv(Self.value(after: token, raw: raw, index: &index))
            case "--category":
                categories = Self.csv(Self.value(after: token, raw: raw, index: &index))
            case "--backend":
                backend = Self.value(after: token, raw: raw, index: &index) ?? backend
            case "--online-model":
                onlineModel = Self.value(after: token, raw: raw, index: &index)
            case "--limit":
                limit = Self.value(after: token, raw: raw, index: &index).flatMap(Int.init)
            case "--root":
                root = Self.value(after: token, raw: raw, index: &index)
            case "--support-dir":
                supportDir = Self.value(after: token, raw: raw, index: &index)
            case "--runtime-path":
                runtimePath = Self.value(after: token, raw: raw, index: &index)
            case "--ids":
                index += 1
                while index < raw.count, !raw[index].hasPrefix("--") {
                    ids.append(contentsOf: Self.csv(raw[index]))
                    index += 1
                }
            default:
                if token.hasPrefix("--") {
                    fail("Unknown option: \(token)")
                } else {
                    ids.append(contentsOf: Self.csv(token))
                    index += 1
                }
            }
        }
    }

    private static func value(after option: String, raw: [String], index: inout Int) -> String? {
        guard index + 1 < raw.count else {
            fail("Missing value after \(option)")
        }
        index += 2
        return raw[index - 1]
    }

    private static func csv(_ value: String?) -> Set<String> {
        guard let value else { return [] }
        return Set(value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }
}

struct Manifest: Codable {
    var version: Int?
    var generatedAt: String?
    var caseCount: Int?
    var cases: [ManifestEntry]
}

struct ManifestEntry: Codable {
    var id: String
    var name: String
    var kind: String
    var importance: String
    var categories: [String]
    var sourceEpisodeID: String?
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var hasScreenshot: Bool
    var expectedOutcomeSummary: String
    var recommendedBackend: String
    var updatedAt: String?
}

struct ListOutput: Codable {
    var root: String
    var caseCount: Int
    var cases: [ManifestEntry]
}

struct RunRequest: Codable {
    var root: String
    var backend: String
    var ids: [String]
    var kind: String?
    var importances: [String]
    var categories: [String]
    var limit: Int?
    var onlineModel: String?
    var runtimePath: String?
    var resultPath: String
}

let args = Arguments(Array(CommandLine.arguments.dropFirst()))

switch args.command {
case "list":
    runList(args)
case "run":
    runEval(args)
case "help", "--help", "-h":
    printUsage()
default:
    fail("Unknown command: \(args.command)")
}

func runList(_ args: Arguments) {
    let root = evalRootURL(args)
    let manifestURL = root.appendingPathComponent("manifest.json")
    let manifest = loadManifest(manifestURL)
    let cases = filtered(manifest.cases, args: args)
    let output = ListOutput(root: root.path, caseCount: cases.count, cases: cases)

    if args.json {
        print(jsonString(output))
    } else {
        if cases.isEmpty {
            print("No eval cases found at \(root.path)")
        } else {
            for entry in cases {
                let categories = entry.categories.joined(separator: ",")
                print("\(entry.id)  \(entry.kind)  \(entry.importance)  \(categories)  \(entry.name)")
                print("  expected: \(entry.expectedOutcomeSummary)")
                print("  backend: \(entry.recommendedBackend), screenshot: \(entry.hasScreenshot)")
            }
        }
    }
}

func runEval(_ args: Arguments) {
    if args.backend == "online",
       ProcessInfo.processInfo.environment["AC_EVAL_OPENROUTER_API_KEY", default: ""].isEmpty,
       ProcessInfo.processInfo.environment["AC_EVAL_OPENAI_API_KEY", default: ""].isEmpty {
        fail("online backend requires AC_EVAL_OPENROUTER_API_KEY or AC_EVAL_OPENAI_API_KEY")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "xcodebuild",
        "test",
        "-project", "AC.xcodeproj",
        "-scheme", "AC",
        "-destination", "platform=macOS",
        "-only-testing:ACTests/AgentEvalCommandRunnerTests",
        "CODE_SIGNING_ALLOWED=NO",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    var environment = ProcessInfo.processInfo.environment
    environment["AC_EVAL_RUNNER_COMMAND"] = "run"
    environment["AC_EVAL_BACKEND"] = args.backend
    environment["AC_EVAL_ROOT"] = evalRootURL(args).path
    if !args.ids.isEmpty { environment["AC_EVAL_IDS"] = args.ids.joined(separator: ",") }
    if let kind = args.kind { environment["AC_EVAL_KIND"] = kind }
    if !args.importances.isEmpty { environment["AC_EVAL_IMPORTANCE"] = args.importances.joined(separator: ",") }
    if !args.categories.isEmpty { environment["AC_EVAL_CATEGORY"] = args.categories.joined(separator: ",") }
    if let limit = args.limit { environment["AC_EVAL_LIMIT"] = String(limit) }
    if let onlineModel = args.onlineModel { environment["AC_EVAL_ONLINE_MODEL"] = onlineModel }
    if let runtimePath = args.runtimePath { environment["AC_EVAL_RUNTIME_PATH"] = runtimePath }
    let handoffID = UUID().uuidString
    let requestURL = URL(fileURLWithPath: "/tmp/ac-eval-runner-request.json")
    let resultURL = URL(fileURLWithPath: "/tmp/ac-eval-runner-\(handoffID)-result.json")
    try? FileManager.default.removeItem(at: requestURL)
    try? FileManager.default.removeItem(at: resultURL)
    let request = RunRequest(
        root: evalRootURL(args).path,
        backend: args.backend,
        ids: args.ids,
        kind: args.kind,
        importances: Array(args.importances).sorted(),
        categories: Array(args.categories).sorted(),
        limit: args.limit,
        onlineModel: args.onlineModel,
        runtimePath: args.runtimePath,
        resultPath: resultURL.path
    )
    let requestData = (try? JSONEncoder().encode(request)) ?? Data("{}".utf8)
    do {
        try requestData.write(to: requestURL, options: .atomic)
    } catch {
        fail("Could not write runner request: \(error.localizedDescription)")
    }
    environment["AC_EVAL_REQUEST_PATH"] = requestURL.path
    environment["AC_EVAL_RESULT_PATH"] = resultURL.path
    process.environment = environment

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
    } catch {
        fail("Could not start xcodebuild: \(error.localizedDescription)")
    }
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    if let resultData = try? Data(contentsOf: resultURL),
       let resultJSON = String(data: resultData, encoding: .utf8) {
        print(resultJSON)
        try? FileManager.default.removeItem(at: resultURL)
        try? FileManager.default.removeItem(at: requestURL)
        if process.terminationStatus == 0 {
            exit(0)
        }
        exit(Int32(process.terminationStatus))
    }

    let marker = "AC_EVAL_RUNNER_RESULT "
    let resultLine = output
        .components(separatedBy: .newlines)
        .last { $0.hasPrefix(marker) }

    if let resultLine {
        print(String(resultLine.dropFirst(marker.count)))
        if process.terminationStatus == 0 {
            exit(0)
        }
        exit(Int32(process.terminationStatus))
    }

    fputs(output, stderr)
    try? FileManager.default.removeItem(at: requestURL)
    exit(process.terminationStatus == 0 ? 0 : Int32(process.terminationStatus))
}

func filtered(_ entries: [ManifestEntry], args: Arguments) -> [ManifestEntry] {
    var entries = entries
    if let kind = args.kind {
        entries = entries.filter { $0.kind == kind }
    }
    if !args.importances.isEmpty {
        entries = entries.filter { args.importances.contains($0.importance) }
    }
    if !args.categories.isEmpty {
        let categories = Set(args.categories.map(normalizeCategory))
        entries = entries.filter { entry in
            !Set(entry.categories.map(normalizeCategory)).isDisjoint(with: categories)
        }
    }
    if !args.ids.isEmpty {
        let ids = Set(args.ids)
        entries = entries.filter { ids.contains($0.id) }
    }
    if let limit = args.limit, limit > 0 {
        entries = Array(entries.prefix(limit))
    }
    return entries
}

func loadManifest(_ url: URL) -> Manifest {
    guard let data = try? Data(contentsOf: url) else {
        return Manifest(version: 1, generatedAt: nil, caseCount: 0, cases: [])
    }
    let decoder = JSONDecoder()
    return (try? decoder.decode(Manifest.self, from: data))
        ?? Manifest(version: 1, generatedAt: nil, caseCount: 0, cases: [])
}

func evalRootURL(_ args: Arguments) -> URL {
    if let root = args.root ?? ProcessInfo.processInfo.environment["AC_EVAL_ROOT"], !root.isEmpty {
        return URL(fileURLWithPath: root, isDirectory: true)
    }
    if let support = args.supportDir ?? ProcessInfo.processInfo.environment["AC_APPLICATION_SUPPORT_DIR"], !support.isEmpty {
        return URL(fileURLWithPath: support, isDirectory: true)
            .appendingPathComponent("evals", isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AC/evals", isDirectory: true)
}

func normalizeCategory(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: " ", with: "_")
        .replacingOccurrences(of: "-", with: "_")
}

func jsonString<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
}

func printUsage() {
    print("""
    Usage:
      ac-eval-runner.swift list [--json] [--kind focus|chat|chat-action] [--importance high,critical] [--category false_positive]
      ac-eval-runner.swift run --backend local [--ids id1 id2 | --importance critical,high --limit 30] [--json]
      ac-eval-runner.swift run --backend online --online-model <model> --ids <id> [--json]

    Optional:
      --root <eval-root>          Defaults to ~/Library/Application Support/AC/evals
      --support-dir <support-dir> Uses <support-dir>/evals
      --runtime-path <llama-cli>  Overrides local runtime for local runs
    """)
}

func fail(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(2)
}
