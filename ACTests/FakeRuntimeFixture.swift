import Foundation

struct FakeRuntimeOutputSet {
    var titlePerception = """
    {"activity_summary":"Reviewing a work tab","focus_guess":"focused","reason_tags":["title"],"notes":["Title suggests focused work."]}
    """

    var visionPerception = """
    {"activity_summary":"Watching a distracting feed","focus_guess":"distracted","reason_tags":["feed"],"notes":[]}
    """

    var decision = """
    {"assessment":"distracted","suggested_action":"nudge","confidence":0.91,"reason_tags":["scrolling"],"nudge":"Inline nudge"}
    """

    var nudgeCopy = """
    {"nudge":"Back to the build."}
    """

    var appealReview = """
    {"decision":"allow","message":"That sounds aligned with your goals."}
    """

    var policyMemory = """
    {"operations":[]}
    """

    var memoryExtraction = """
    {"memory":"Keep social media blocked during the focus sessions."}
    """

    var memoryCompression = """
    {"memory":"- Focus on coding\\n- Keep social breaks short"}
    """
}

struct FakeRuntimeFixture {
    let runtimePath: String

    init(outputs: FakeRuntimeOutputSet = FakeRuntimeOutputSet()) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-fake-runtime-\(UUID().uuidString)", isDirectory: true)
        let binURL = rootURL
            .appendingPathComponent("llama.cpp", isDirectory: true)
            .appendingPathComponent("build/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let scriptURL = binURL.appendingPathComponent("llama-cli")
        let script = Self.makeScript(outputs: outputs)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        runtimePath = scriptURL.path
    }

    private static func makeScript(outputs: FakeRuntimeOutputSet) -> String {
        """
        #!/bin/bash
        set -euo pipefail

        prompt=""
        sysfile=""
        has_image=0

        while [[ $# -gt 0 ]]; do
          case "$1" in
            -sysf)
              sysfile="$2"
              shift 2
              ;;
            -p)
              prompt="$2"
              shift 2
              ;;
            --image)
              has_image=1
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done

        system_prompt=""
        if [[ -n "$sysfile" ]]; then
          system_prompt="$(cat "$sysfile" 2>/dev/null || true)"
        fi

        title_output=$(cat <<'EOF_AC_TITLE'
        \(outputs.titlePerception)
        EOF_AC_TITLE
        )
        vision_output=$(cat <<'EOF_AC_VISION'
        \(outputs.visionPerception)
        EOF_AC_VISION
        )
        decision_output=$(cat <<'EOF_AC_DECISION'
        \(outputs.decision)
        EOF_AC_DECISION
        )
        nudge_output=$(cat <<'EOF_AC_NUDGE'
        \(outputs.nudgeCopy)
        EOF_AC_NUDGE
        )
        appeal_output=$(cat <<'EOF_AC_APPEAL'
        \(outputs.appealReview)
        EOF_AC_APPEAL
        )
        policy_memory_output=$(cat <<'EOF_AC_POLICY'
        \(outputs.policyMemory)
        EOF_AC_POLICY
        )
        memory_extraction_output=$(cat <<'EOF_AC_MEMORY_EXTRACT'
        \(outputs.memoryExtraction)
        EOF_AC_MEMORY_EXTRACT
        )
        memory_compression_output=$(cat <<'EOF_AC_MEMORY_COMPRESS'
        \(outputs.memoryCompression)
        EOF_AC_MEMORY_COMPRESS
        )

        if [[ "$system_prompt" == *'update structured policy memory'* ]]; then
          printf '%s\n' "$policy_memory_output"
        elif [[ "$system_prompt" == *'typed appeal'* ]]; then
          printf '%s\n' "$appeal_output"
        elif [[ "$prompt" == *'Memory to compress:'* ]] || [[ "$system_prompt" == *'compressing a focus companion'* ]]; then
          printf '%s\n' "$memory_compression_output"
        elif [[ "$prompt" == *'User message:'* ]] || [[ "$system_prompt" == *'memory extractor for a focus companion app'* ]]; then
          printf '%s\n' "$memory_extraction_output"
        elif [[ "$system_prompt" == *'Write one short nudge'* ]]; then
          printf '%s\n' "$nudge_output"
        elif [[ "$system_prompt" == *'decision stage'* ]] || [[ "$system_prompt" == *'suggested_action'* && "$system_prompt" == *'assessment'* ]]; then
          printf '%s\n' "$decision_output"
        elif [[ "$has_image" -eq 1 ]] || [[ "$system_prompt" == *'screenshot perception stage'* ]]; then
          printf '%s\n' "$vision_output"
        else
          printf '%s\n' "$title_output"
        fi
        """
    }
}
