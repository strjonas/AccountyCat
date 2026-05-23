import Foundation
import Testing
@testable import AC

/// Writes the curated synthetic eval suite (`SyntheticEvalCases.all`) into the
/// eval root so `ac-eval-runner.swift run` can evaluate it against the live
/// algorithm + prompts.
///
/// Gating mirrors `AgentEvalCommandRunnerTests`: a normal `xcodebuild test` must
/// never seed. Because `xcodebuild` does not forward the runner process's
/// environment to the test host, the trigger is a short-lived handoff file at a
/// fixed `/tmp` path carrying `allowTestHostRun: true` + an expiry. No handoff
/// file → the test returns without writing anything.
@MainActor
struct ACEvalSeedTests {

    @Test
    func seed() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let request = Self.loadRequest(environment: env) else {
            return
        }

        let store: ACEvalStore
        if let root = request.root, !root.isEmpty {
            store = ACEvalStore(rootURL: URL(fileURLWithPath: root, isDirectory: true))
        } else {
            store = ACEvalStore()
        }

        var seeded = 0
        var skipped: [String] = []
        for evalCase in SyntheticEvalCases.all {
            // A vision case whose source screenshot is missing would silently become a
            // title-only case. Skip + report instead, so the suite stays honest.
            if let path = evalCase.focusInput?.screenshotPath ?? evalCase.source.screenshotPath,
               !path.isEmpty,
               !FileManager.default.fileExists(atPath: path) {
                skipped.append(evalCase.id)
                continue
            }
            try store.save(evalCase)
            seeded += 1
        }
        try store.regenerateManifest()

        let skippedJSON = skipped.map { "\"\($0)\"" }.joined(separator: ",")
        let json = "{\"seeded\":\(seeded),\"skipped\":[\(skippedJSON)],\"root\":\"\(store.rootURL.path)\"}"
        if !request.resultPath.isEmpty {
            try? json.write(to: URL(fileURLWithPath: request.resultPath), atomically: true, encoding: .utf8)
        }
        print("AC_EVAL_SEED_RESULT \(json)")
        #expect(seeded > 0)
    }

    private struct SeedFileRequest: Codable {
        var root: String?
        var resultPath: String
        var allowTestHostRun: Bool
        var expiresAt: TimeInterval?
    }

    private static func loadRequest(environment: [String: String]) -> SeedFileRequest? {
        var urls: [URL] = []
        if let path = environment["AC_EVAL_SEED_REQUEST_PATH"], !path.isEmpty {
            urls.append(URL(fileURLWithPath: path))
        } else {
            urls.append(URL(fileURLWithPath: "/tmp/ac-eval-seed-request.json"))
        }

        for url in urls {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  abs(modifiedAt.timeIntervalSinceNow) < 1_200,
                  let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(SeedFileRequest.self, from: data),
                  request.allowTestHostRun == true,
                  request.resultPath.hasPrefix("/tmp/ac-eval-seed-"),
                  request.resultPath.hasSuffix("-result.json") else {
                continue
            }
            if let expiresAt = request.expiresAt,
               Date().timeIntervalSince1970 > expiresAt {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            try? FileManager.default.removeItem(at: url)
            return request
        }
        return nil
    }
}
