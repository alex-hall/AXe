import ArgumentParser
import Darwin
import Foundation

/// Long-lived command server. Reads one command per line from stdin, executes
/// it against a simulator/HID session held open for the process lifetime, and
/// writes exactly one JSON line to stdout per command.
///
/// The point: a fresh `axe` invocation pays ~0.5s of private-framework loading
/// and session setup before doing any work. Serve pays it once, so a driver
/// issuing hundreds of commands (UI test harnesses) drops from ~1s per
/// operation to the operation's real cost.
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve commands over stdin/stdout using one long-lived simulator/HID session.",
        discussion: """
        Protocol — line-oriented and strictly serial (one response line per
        request line, in order):

          request:  any `axe batch` step line (tap, swipe, touch, type,
                    button, key, key-sequence, key-combo, gesture, sleep),
                    optionally with per-line `--wait-timeout` /
                    `--poll-interval` overrides, or:
                      describe-ui        dump the AX tree
                      ping               liveness probe

          response: one JSON line on stdout:
                      {"ok":true}                    interaction succeeded
                      {"ok":true,"tree":[...]}       describe-ui result
                      {"ok":true,"pong":true}        ping
                      {"ok":false,"error":"..."}     failure (loop continues)

        On startup, prints {"ready":true} once the session is live. Exits when
        stdin closes. Log noise goes to stderr only; stdout carries nothing
        but protocol lines.

        Example:
          mkfifo cmds && axe serve --udid SIM < cmds &
          echo "describe-ui" > cmds
        """
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Option(name: .customLong("type-submission"), help: "Type step submission mode.")
    var typeSubmissionMode: TypeSubmissionMode = .chunked

    @Option(name: .customLong("type-chunk-size"), help: "Maximum HID events per chunk when type-submission is chunked.")
    var typeChunkSize: Int = 200

    @Option(name: .customLong("tap-style"), help: "Default tap event style for tap steps.")
    var tapStyle: TapStyle = .automatic

    @Option(name: .customLong("wait-timeout"), help: "Default seconds to poll for selector-based elements (per-line --wait-timeout overrides).")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Default seconds between accessibility polls when waiting (per-line --poll-interval overrides).")
    var pollInterval: Double = 0.25

    @Flag(name: .customLong("verbose"), help: "Enable verbose logging to stderr.")
    var verbose: Bool = false

    func validate() throws {
        guard typeChunkSize > 0 else {
            throw ValidationError("--type-chunk-size must be greater than 0.")
        }
        guard waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }
        guard pollInterval > 0 else {
            throw ValidationError("--poll-interval must be greater than 0.")
        }
    }

    func run() async throws {
        let logger = AxeLogger(writeToStdErr: verbose)
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let session = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
        let runner = BatchPlanRunner(session: session, logger: logger)

        Self.emit(["ready": true])

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            do {
                try await handle(trimmed, runner: runner, logger: logger)
            } catch {
                Self.emit(["ok": false, "error": error.localizedDescription])
            }
        }
    }

    private func handle(_ line: String, runner: BatchPlanRunner, logger: AxeLogger) async throws {
        var tokens = try ShellTokenizer.tokenize(line)
        guard let verb = tokens.first else {
            Self.emit(["ok": false, "error": "empty command"])
            return
        }

        switch verb {
        case "ping":
            Self.emit(["ok": true, "pong": true])

        case "describe-ui":
            let data = try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(
                for: simulatorUDID,
                point: nil,
                logger: logger
            )
            // The fetcher pretty-prints; the protocol is one line per response,
            // so re-serialize compact and embed under "tree".
            let tree = try JSONSerialization.jsonObject(with: data)
            Self.emit(["ok": true, "tree": tree])

        default:
            // Per-line wait overrides ride the same step syntax; strip them
            // out and build this line's context from the remainder.
            let lineWaitTimeout = try Self.extractOption(&tokens, named: "--wait-timeout") ?? waitTimeout
            let linePollInterval = try Self.extractOption(&tokens, named: "--poll-interval") ?? pollInterval

            let context = await MainActor.run {
                BatchContext(
                    simulatorUDID: simulatorUDID,
                    axCachePolicy: .none,
                    typeSubmissionMode: typeSubmissionMode,
                    typeChunkSize: typeChunkSize,
                    tapStyle: tapStyle,
                    waitTimeout: lineWaitTimeout,
                    pollInterval: linePollInterval
                )
            }

            let primitives = try await BatchStepParser.parseStepTokens(
                tokens,
                globalUDID: simulatorUDID,
                context: context,
                logger: logger
            )
            try await runner.run(BatchPlan(primitives: primitives))
            Self.emit(["ok": true])
        }
    }

    /// Removes `--<name> <value>` from the tokens if present; returns the value.
    private static func extractOption(_ tokens: inout [String], named name: String) throws -> Double? {
        guard let index = tokens.firstIndex(of: name) else { return nil }
        guard index + 1 < tokens.count, let value = Double(tokens[index + 1]) else {
            throw ValidationError("\(name) requires a numeric value.")
        }
        tokens.removeSubrange(index...(index + 1))
        return value
    }

    /// One compact JSON line, written unbuffered — stdout may be a pipe, and
    /// the client blocks on each response, so buffering would deadlock.
    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            FileHandle.standardOutput.write(Data("{\"ok\":false,\"error\":\"unserializable response\"}\n".utf8))
            return
        }
        var out = data
        out.append(0x0A)
        FileHandle.standardOutput.write(out)
    }
}
