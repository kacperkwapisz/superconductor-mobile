import SwiftUI

struct PairingView: View {
    @Environment(AppSession.self) private var session
    @State private var host = ""
    @State private var port = "9477"
    @State private var token = ""
    @State private var showScanner = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    // Primary actions for the new Mac companion flow
                    VStack(spacing: 12) {
                        Button {
                            errorMessage = nil
                            showScanner = true
                        } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)

                        Button {
                            pasteFromClipboard()
                        } label: {
                            Label("Paste JSON from Clipboard", systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }

                    Text("or enter manually")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)

                    VStack(spacing: 0) {
                        pairingField("Host", placeholder: "100.x.x.x or 192.168.x.x", text: $host)
                        Divider().padding(.leading, 16)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Port")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("9477", text: $port)
                                .keyboardType(.numberPad)
                        }
                        .padding(16)
                        Divider().padding(.leading, 16)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Token")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            SecureField("Paste from bridge.json", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .padding(16)
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))

                    Button(action: savePairing) {
                        Text("Connect")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(!canConnect)

                    helpCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background { AppTheme.screenBackground }
            .navigationTitle("Superconductor")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showScanner) {
                QRScannerView(
                    onScanned: { scanned in
                        showScanner = false
                        handleScannedPayload(scanned)
                    },
                    onCancel: {
                        showScanner = false
                    }
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Mac companion", systemImage: "desktopcomputer")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Scan the QR code shown in the Superconductor Mobile menu bar app on your Mac.")
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pairingField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(16)
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to pair")
                .font(.subheadline.weight(.semibold))
            Text("1. Launch the Superconductor Mobile companion on your Mac (menu bar icon).\n2. Click it to reveal the QR code.\n3. Tap Scan above and point your camera at it, or copy the JSON and use Paste JSON.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port) != nil
            && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func savePairing() {
        guard let portNum = Int(port) else { return }
        session.savePairing(
            host: host.trimmingCharacters(in: .whitespaces),
            port: portNum,
            token: token.trimmingCharacters(in: .whitespaces),
            useTLS: false
        )
    }

    // MARK: - QR / Paste handling

    private func pasteFromClipboard() {
        guard let string = UIPasteboard.general.string, !string.isEmpty else {
            errorMessage = "Clipboard is empty."
            return
        }
        errorMessage = nil
        handleScannedPayload(string)
    }

    private func handleScannedPayload(_ raw: String) {
        if session.applyPairingString(raw) {
            // Success — RootView switches automatically
            return
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fallback: raw token pasted
        if trimmed.count > 20 && !trimmed.contains(" ") && !trimmed.contains("{") {
            token = trimmed
            errorMessage = "Pasted token. Fill in the host and port manually, then tap Connect."
            return
        }

        errorMessage = "Could not parse QR code or clipboard content as pairing data."
    }
}