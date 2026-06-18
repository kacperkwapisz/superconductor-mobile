import Foundation

enum HostDetector {
    /// Returns the best host for pairing.
    /// Prefers Tailscale IPv4 if available, otherwise the first non-internal LAN IPv4.
    static func bestHost() -> String {
        if let ts = tailscaleIPv4() {
            return ts
        }
        return lanIPv4() ?? "127.0.0.1"
    }

    private static func tailscaleIPv4() -> String? {
        // Try common full paths first (homebrew, local), then fall back to PATH via `which`.
        let candidates = [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale"
        ]

        var tailscalePath: String?
        for p in candidates {
            if FileManager.default.fileExists(atPath: p) {
                tailscalePath = p
                break
            }
        }
        if tailscalePath == nil {
            if let which = runCommandOutput("/usr/bin/which", args: ["tailscale"])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !which.isEmpty, FileManager.default.fileExists(atPath: which) {
                tailscalePath = which
            }
        }

        guard let exe = tailscalePath else { return nil }

        guard let output = runCommandOutput(exe, args: ["ip", "-4"]) else { return nil }
        let ip = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Simple IPv4 shape check
        let parts = ip.split(separator: ".")
        if parts.count == 4 && parts.allSatisfy({ Int($0) != nil }) {
            return ip
        }
        return nil
    }

    private static func lanIPv4() -> String? {
        // Use shell `ifconfig` to stay simple and avoid header/flag interop issues.
        // Matches the spirit of the original Node `os.networkInterfaces()` logic.
        guard let output = runCommandOutput("/sbin/ifconfig", args: []) else {
            // Fallback: try ipconfig getifaddr (may return en0)
            if let en0 = runCommandOutput("/usr/sbin/ipconfig", args: ["getifaddr", "en0"])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !en0.isEmpty, !en0.hasPrefix("127.") {
                return en0
            }
            return nil
        }

        // Parse for lines containing "inet " and not 127.
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("inet ") {
                let components = trimmed.split(separator: " ")
                if components.count >= 2 {
                    let candidate = String(components[1])
                    if candidate.contains(".") && !candidate.hasPrefix("127.") && !candidate.hasPrefix("169.254.") {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    private static func runCommandOutput(_ launchPath: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args.isEmpty ? nil : args

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}