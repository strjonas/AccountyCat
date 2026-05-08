#!/usr/bin/env swift

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("""
    usage:
      swift ac-debug-runner.swift chat --message "..." [--state state.json] [--fake-runtime]
      swift ac-debug-runner.swift monitor [--context context.json] [--state state.json] [--screenshot shot.png] [--fake-runtime]
      swift ac-debug-runner.swift golden --runtime local|online
      swift ac-debug-runner.swift test --only ACTests/<TestName>
      swift ac-debug-runner.swift summarize /path/to/agent-debug-bundle

    Notes:
      Chat and monitor run through ACTests/FakeRuntimeFixture-backed harnesses, not the native UI.
    """)
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}

func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = repo
    if !environment.isEmpty {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            merged[key] = value
        }
        process.environment = merged
    }
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        fail(error.localizedDescription)
    }
}

switch command {
case "chat":
    var env: [String: String] = [
        "AC_DEBUG_RUNNER_COMMAND": "chat",
        "AC_DEBUG_RUNNER_MESSAGE": option("--message") ?? "Help me focus for the next 30 minutes."
    ]
    if let state = option("--state") {
        env["AC_DEBUG_RUNNER_STATE"] = state
    }
    let status = run("/usr/bin/xcodebuild", [
        "test",
        "-project", "AC.xcodeproj",
        "-scheme", "AC",
        "-destination", "platform=macOS",
        "-only-testing:ACTests/AgentHeadlessRunnerTests",
        "CODE_SIGNING_ALLOWED=NO"
    ], environment: env)
    exit(status)

case "monitor":
    var env: [String: String] = ["AC_DEBUG_RUNNER_COMMAND": "monitor"]
    if let state = option("--state") {
        env["AC_DEBUG_RUNNER_STATE"] = state
    }
    if let context = option("--context") {
        env["AC_DEBUG_RUNNER_CONTEXT"] = context
    }
    if let screenshot = option("--screenshot") {
        env["AC_DEBUG_RUNNER_SCREENSHOT"] = screenshot
    }
    let status = run("/usr/bin/xcodebuild", [
        "test",
        "-project", "AC.xcodeproj",
        "-scheme", "AC",
        "-destination", "platform=macOS",
        "-only-testing:ACTests/AgentHeadlessRunnerTests",
        "CODE_SIGNING_ALLOWED=NO"
    ], environment: env)
    exit(status)

case "golden":
    let runtime = option("--runtime") ?? "local"
    guard runtime == "local" || runtime == "online" else {
        fail("--runtime must be local or online")
    }
    print("Running AC golden/debug test path for runtime=\(runtime)")
    let status = run("/usr/bin/xcodebuild", [
        "test",
        "-project", "AC.xcodeproj",
        "-scheme", "AC",
        "-destination", "platform=macOS",
        "-only-testing:ACTests",
        "CODE_SIGNING_ALLOWED=NO"
    ])
    exit(status)

case "test":
    let onlyIndex = args.firstIndex(of: "--only")
    let only = onlyIndex.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "ACTests"
    let status = run("/usr/bin/xcodebuild", [
        "test",
        "-project", "AC.xcodeproj",
        "-scheme", "AC",
        "-destination", "platform=macOS",
        "-only-testing:\(only)",
        "CODE_SIGNING_ALLOWED=NO"
    ])
    exit(status)

case "summarize":
    guard args.count >= 2 else { fail("usage: swift ac-debug-runner.swift summarize /path/to/bundle") }
    let script = "dev/agents/accountycat-debugger/scripts/summarize-bundle.swift"
    let status = run("/usr/bin/swift", [script, args[1]])
    exit(status)

default:
    fail("unknown command: \(command)")
}
