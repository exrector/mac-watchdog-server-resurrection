import Foundation
import FoundationModels

struct TerminalTool: Tool {
    let name = "terminal"
    let description = "Runs one unrestricted zsh command locally on this Mac and returns exit status, stdout, and stderr. Use it to inspect files, processes, services, and network state, and to repair problems."

    @Generable
    struct Arguments {
        @Guide(description: "One complete zsh command line")
        var command: String
    }

    func call(arguments: Arguments) async throws -> String {
        let command = arguments.command
        fputs("TOOL> \(command)\n", stderr)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            var text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if text.count > 2_500 { text = String(text.prefix(2_500)) + "\n[truncated]" }
            let result = "exit=\(process.terminationStatus)\n\(text)"
            fputs("RESULT> \(result.prefix(500))\n", stderr)
            return result
        } catch {
            return "launch_error=\(error.localizedDescription)"
        }
    }
}

@main
enum RecoveryAgent {
    static let instructions = """
    You are an autonomous local macOS recovery engineer. You have an unrestricted terminal tool on this Mac.
    Inspect the actual state before acting. Continue using the tool until the requested condition is healthy.
    Verify every repair with a separate command. Never report success unless verification output proves it.
    Prefer reversible changes. Keep the final answer short and state commands run and verified result.
    """

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
        let args = CommandLine.arguments
        print("MODEL=\(SystemLanguageModel.default.availability)")
        guard SystemLanguageModel.default.isAvailable else { exit(2) }
        switch args.dropFirst().first ?? "help" {
        case "ask":
            await ask(args.dropFirst(2).joined(separator: " "), withTool: false)
        case "agent":
            await ask(args.dropFirst(2).joined(separator: " "), withTool: true)
        case "selftest":
            await selftest()
        default:
            print("usage: recovery-agent ask|agent <prompt> | selftest")
        }
    }

    static func ask(_ prompt: String, withTool: Bool) async {
        let session = withTool
            ? LanguageModelSession(tools: [TerminalTool()], instructions: instructions)
            : LanguageModelSession(instructions: "Answer directly and concisely.")
        let started = Date()
        do {
            let response = try await session.respond(to: prompt)
            let calls = session.transcript.reduce(0) { total, entry in
                if case .toolCalls(let values) = entry { return total + values.count }
                return total
            }
            print("ANSWER=\(response.content)")
            // NOTE: token counts are omitted for SDK compatibility.
            // `response.usage` exists only in newer Foundation Models SDKs
            // (macOS 27 / Xcode 27); older SDKs (macOS 26 runners) do not
            // have it and the build fails. The Watcher does not depend on
            // these numbers — they are diagnostic only.
            print(String(format: "SECONDS=%.2f TOOL_CALLS=%d TOKENS_IN=%d TOKENS_OUT=%d", Date().timeIntervalSince(started), calls, 0, 0))
        } catch {
            print("ERROR=\(String(reflecting: error))")
            exit(3)
        }
    }

    static func selftest() async {
        let marker = "/tmp/apple-ai-recovery-lab/state.txt"
        try? FileManager.default.removeItem(atPath: "/tmp/apple-ai-recovery-lab")
        await ask("Use terminal commands to create \(marker) containing exactly WATCHDOG_SELFTEST_OK, then read it back and verify the exact value.", withTool: true)
        let value = (try? String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "MISSING"
        print("SELFTEST_FILE=\(value)")
        if value != "WATCHDOG_SELFTEST_OK" { exit(4) }
    }
}
