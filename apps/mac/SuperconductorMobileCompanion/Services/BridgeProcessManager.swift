import Foundation

@MainActor
final class BridgeProcessManager: ObservableObject {
    static let shared = BridgeProcessManager()

    @Published var isRunning = false
    @Published var lastError: String?

    private var process: Process?
    private var stderrPipe: Pipe?

    func start(config: CompanionConfig) {
        stop()
        terminateListeners(onPort: config.port)

        let proc = Process()

        if let bundled = bundledBridgeExecutableURL(),
           FileManager.default.fileExists(atPath: bundled.path) {
            proc.executableURL = bundled
        } else if let bun = findBun() {
            proc.executableURL = bun
            let repoRoot = findRepoRoot() ?? FileManager.default.currentDirectoryPath
            proc.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
            proc.arguments = ["apps/bridge/src/server.ts"]
        } else {
            lastError = "Could not find bridge executable or bun."
            isRunning = false
            return
        }

        var env = ProcessInfo.processInfo.environment
        env["SC_MOBILE_BRIDGE_PORT"] = String(config.port)
        env["SC_MOBILE_BRIDGE_BIND"] = config.bind
        env["SC_MOBILE_MANAGED"] = "1"
        env["SC_MOBILE_BRIDGE_HOST"] = HostDetector.bestHost()
        env["PATH"] = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        stderrPipe = errPipe

        proc.terminationHandler = { [weak self] p in
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            Task { @MainActor in
                self?.isRunning = false
                guard p.terminationStatus != 0 else {
                    self?.lastError = nil
                    return
                }
                self?.lastError = Self.formatBridgeExit(status: p.terminationStatus, stderr: errText)
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            lastError = nil
        } catch {
            lastError = "Failed to launch bridge: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        if let proc = process, proc.isRunning {
            proc.terminate()
            usleep(200_000)
            if proc.isRunning {
                proc.interrupt()
            }
        }
        process = nil
        isRunning = false
    }

    // MARK: - Port cleanup

    /// Kills orphaned bridge listeners so restart does not hit EADDRINUSE.
    private func terminateListeners(onPort port: Int) {
        guard let pids = runCommandOutput("/usr/sbin/lsof", args: ["-ti", "tcp:\(port)"])?
            .split(whereSeparator: \.isNewline)
            .compactMap({ Int32(String($0).trimmingCharacters(in: .whitespaces)) }),
              !pids.isEmpty else { return }

        let myPid = ProcessInfo.processInfo.processIdentifier
        for pid in pids where pid != myPid {
            kill(pid, SIGTERM)
        }
        usleep(150_000)
        for pid in pids where pid != myPid {
            kill(pid, SIGKILL)
        }
    }

    private static func formatBridgeExit(status: Int32, stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("EADDRINUSE") || trimmed.contains("port") && trimmed.contains("in use") {
            return "Port is already in use. Quit other bridge copies or change port in bridge.json."
        }
        if trimmed.contains("Superconductor is not reachable") {
            return "Superconductor is not running. Open Superconductor.app on this Mac, then Start Bridge."
        }
        if !trimmed.isEmpty {
            let line = trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
            return "Bridge exited (\(status)): \(line)"
        }
        return "Bridge process exited with code \(status)"
    }

    // MARK: - Helpers

    private func bundledBridgeExecutableURL() -> URL? {
        if let url = Bundle.main.url(forResource: "bridge-server", withExtension: nil) {
            return url
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let candidate = execDir.appendingPathComponent("bridge-server")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func findBun() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
            "/usr/bin/bun",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let which = runCommandOutput("/usr/bin/which", args: ["bun"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !which.isEmpty, FileManager.default.fileExists(atPath: which) {
            return URL(fileURLWithPath: which)
        }
        return nil
    }

    private func findRepoRoot() -> String? {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("apps/bridge/package.json").path) {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private func runCommandOutput(_ launchPath: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            return nil
        }
    }
}