import SwiftUI
import AVFoundation

/// 扫码连接：扫 wand 设置页「连接 App」的二维码（内容是连接码 base64(url#token)
/// 或裸地址），命中后回调原始字符串，交给 WandAuth.resolve 统一解析。
struct QRScannerSheet: View {
    /// 扫到二维码后回调（已 dismiss）。
    let onScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authState: AuthState = .checking
    @State private var handled = false

    private enum AuthState { case checking, granted, denied }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                switch authState {
                case .checking:
                    ProgressView().tint(.white)
                case .denied:
                    deniedView
                case .granted:
                    CameraPreview { code in
                        guard !handled else { return }
                        handled = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                        onScanned(code)
                    }
                    .ignoresSafeArea()
                    scanOverlay
                }
            }
            .navigationTitle("扫码连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.white)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { checkPermission() }
        .wandKeyboardShortcuts(scannerKeyboardShortcuts)
    }

    private var scannerKeyboardShortcuts: [WandKeyboardShortcutAction] {
        [
            WandKeyboardShortcutAction(
                id: "dismiss-scanner",
                title: "取消扫码",
                key: .escape,
                modifiers: []
            ) {
                dismiss()
            },
        ]
    }

    // MARK: - 取景框 + 提示

    private var scanOverlay: some View {
        VStack(spacing: 18) {
            Spacer()
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: 2.5)
                .frame(width: 230, height: 230)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            Text("对准电脑端 Wand「设置 → 连接 App」的二维码")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var deniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash")
                .font(.system(size: 34))
                .foregroundColor(.white.opacity(0.7))
            Text("需要相机权限才能扫码")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            Text("请到 设置 → Wand 里允许访问相机，\n或返回手动粘贴连接码。")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("打开系统设置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Theme.brand))
            }
            .padding(.top, 6)
        }
        .padding(32)
    }

    // MARK: - 权限

    private func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authState = .granted
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    authState = granted ? .granted : .denied
                }
            }
        default:
            authState = .denied
        }
    }
}

// MARK: - 相机预览 + QR 识别

/// AVCaptureSession 包装：后台队列配置/启停，主队列回调识别结果。
private struct CameraPreview: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?

        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "wand.qr.session")
        private var previewLayer: AVCaptureVideoPreviewLayer?

        deinit {
            // viewWillDisappear 已停 session，但极端时序（直接 dealloc）可能漏；
            // deinit 兜底，确保摄像头硬件释放、不耗电、不阻塞其他 App 用摄像头。
            if session.isRunning { session.stopRunning() }
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            previewLayer = layer
            sessionQueue.async { [weak self] in self?.configureAndStart() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            sessionQueue.async { [weak self] in
                guard let self, self.session.isRunning else { return }
                self.session.stopRunning()
            }
        }

        private func configureAndStart() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                if output.availableMetadataObjectTypes.contains(.qr) {
                    output.metadataObjectTypes = [.qr]
                }
            }
            session.commitConfiguration()
            session.startRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr,
                  let value = obj.stringValue,
                  !value.isEmpty else { return }
            onCode?(value)
        }
    }
}
