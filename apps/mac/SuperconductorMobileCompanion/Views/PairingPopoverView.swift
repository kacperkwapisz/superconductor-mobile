import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

struct PairingPopoverView: View {
    @EnvironmentObject var manager: BridgeProcessManager
    @State private var config = CompanionConfigManager.loadOrCreate()
    @State private var host: String = HostDetector.bestHost()

    private let popoverWidth: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            qrSection

            Text("Scan this QR with the Superconductor iOS app camera, or copy values.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusLine

            actions

            Divider()

            footer
        }
        .padding(16)
        .frame(width: popoverWidth)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.gen2")
                .font(.title3)
            Text("Superconductor Mobile")
                .font(.headline)
            Spacer()
        }
    }

    private var qrSection: some View {
        VStack(spacing: 8) {
            if let qr = generateQRImage() {
                Image(nsImage: qr)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 180, height: 180)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 180, height: 180)
                    .overlay {
                        ProgressView()
                    }
            }

            HStack(spacing: 8) {
                Button {
                    copyPairingJSON()
                } label: {
                    Label("Copy JSON", systemImage: "doc.on.doc")
                }

                Button {
                    copyToken()
                } label: {
                    Label("Copy Token", systemImage: "key")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(manager.isRunning ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(manager.isRunning ? "Bridge running" : "Bridge stopped")
                .font(.caption)
            if let err = manager.lastError {
                Text("· \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                if manager.isRunning {
                    manager.stop()
                } else {
                    manager.start(config: config)
                }
            } label: {
                Text(manager.isRunning ? "Stop Bridge" : "Start Bridge")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(manager.isRunning ? .red : .accentColor)

            HStack(spacing: 8) {
                Button("Regenerate Token") {
                    regenerateToken()
                }

                Button("Open Config") {
                    showConfigInFinder()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Host: \(host)   Port: \(config.port)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)

            Text("Config: \(CompanionConfigManager.currentPath())")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Actions

    private func regenerateToken() {
        config = CompanionConfigManager.regenerate()
        // Restart bridge with fresh config
        if manager.isRunning {
            manager.stop()
            // Small delay to let port free
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                manager.start(config: config)
            }
        }
    }

    private func copyToken() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(config.token, forType: .string)
    }

    private func copyPairingJSON() {
        let payload = PairingPayload(
            version: 1,
            host: host,
            port: config.port,
            token: config.token,
            fingerprint: config.fingerprint,
            tls: false
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(json, forType: .string)
    }

    private func showConfigInFinder() {
        let url = URL(fileURLWithPath: CompanionConfigManager.currentPath())
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - QR

    private func generateQRImage() -> NSImage? {
        let payload = PairingPayload(
            version: 1,
            host: host,
            port: config.port,
            token: config.token,
            fingerprint: config.fingerprint,
            tls: false
        )

        guard let jsonData = try? JSONEncoder().encode(payload) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = jsonData
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }

        // Scale up for crispness
        let scale: CGFloat = 6.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaled = outputImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}