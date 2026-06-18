import SwiftUI
import AVFoundation

struct QRScannerView: View {
    var onScanned: (String) -> Void
    var onCancel: () -> Void

    @State private var isTorchOn = false
    @State private var statusMessage = "Point the camera at the QR code from the Mac companion."

    var body: some View {
        ZStack {
            QRScannerRepresentable(
                onCodeScanned: { code in
                    onScanned(code)
                },
                onError: { message in
                    statusMessage = message
                }
            )
            .ignoresSafeArea()

            // Overlay UI
            VStack {
                HStack {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.6), in: Capsule())
                    Spacer()
                    Button {
                        toggleTorch()
                    } label: {
                        Image(systemName: isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.6), in: Circle())
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)

                Spacer()

                VStack(spacing: 8) {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.bottom, 40)
            }
        }
        .onDisappear {
            // Ensure torch is off when view leaves
            if isTorchOn {
                toggleTorch(forceOff: true)
            }
        }
    }

    private func toggleTorch(forceOff: Bool = false) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if forceOff {
                device.torchMode = .off
                isTorchOn = false
            } else {
                device.torchMode = isTorchOn ? .off : .on
                isTorchOn.toggle()
            }
            device.unlockForConfiguration()
        } catch {
            // Ignore torch errors
        }
    }
}

struct QRScannerRepresentable: UIViewRepresentable {
    var onCodeScanned: (String) -> Void
    var onError: (String) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black

        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            setupCaptureSession(in: view, context: context)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.setupCaptureSession(in: view, context: context)
                    } else {
                        self.onError("Camera permission denied. Enable it in Settings.")
                    }
                }
            }
        case .denied, .restricted:
            onError("Camera permission denied. Enable it in Settings → Privacy & Security.")
        @unknown default:
            onError("Camera unavailable")
        }

        return view
    }

    private func setupCaptureSession(in view: UIView, context: Context) {
        let session = AVCaptureSession()
        context.coordinator.session = session

        guard let videoDevice = AVCaptureDevice.default(for: .video) else {
            onError("No camera available")
            return
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }
        } catch {
            onError("Failed to access camera")
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(context.coordinator, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer

        DispatchQueue.global(qos: .userInitiated).async {
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let preview = context.coordinator.previewLayer {
            DispatchQueue.main.async {
                preview.frame = uiView.bounds
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned, onError: onError)
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onCodeScanned: (String) -> Void
        var onError: (String) -> Void
        var session: AVCaptureSession?
        var previewLayer: AVCaptureVideoPreviewLayer?
        private var hasScanned = false

        init(onCodeScanned: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
            self.onError = onError
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !hasScanned else { return }

            if let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
               metadataObject.type == .qr,
               let stringValue = metadataObject.stringValue,
               !stringValue.isEmpty {

                hasScanned = true

                // Stop scanning
                DispatchQueue.global().async {
                    self.session?.stopRunning()
                }

                onCodeScanned(stringValue)
            }
        }
    }
}
