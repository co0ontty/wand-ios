import SwiftUI
import AVFoundation

/// 扫码连接：扫 wand 设置页「连接 App」的二维码（内容是连接码 base64(url#token)
/// 或裸地址），命中后回调原始字符串，交给 WandAuth.resolve 统一解析。
struct QRScannerSheet: View {
    /// 扫到二维码后回调（已 dismiss）。
    let onScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var authState: AuthState = .checking
    @State private var handled = false
    @State private var scanProgress: CGFloat = 0

    private enum AuthState {
        case checking
        case granted
        case denied
        case failed(String)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                switch authState {
                case .checking:
                    ProgressView().tint(.white)
                case .denied:
                    deniedView
                case .failed(let message):
                    scannerFailureView(message)
                case .granted:
                    CameraPreview(
                        onCode: { code in
                            guard !handled else { return }
                            handled = true
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            dismiss()
                            onScanned(code)
                        },
                        onFailure: { message in
                            authState = .failed(message)
                        }
                    )
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { checkPermission() }
        }
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
        GeometryReader { proxy in
            let side = min(230, max(180, proxy.size.width - 48))
            let left = (proxy.size.width - side) / 2
            let top = max(96, proxy.size.height * 0.38 - side / 2)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.65)
                    .frame(width: proxy.size.width, height: top)
                Color.black.opacity(0.65)
                    .frame(width: left, height: side)
                    .offset(y: top)
                Color.black.opacity(0.65)
                    .frame(width: left, height: side)
                    .offset(x: left + side, y: top)
                Color.black.opacity(0.65)
                    .frame(width: proxy.size.width, height: max(0, proxy.size.height - top - side))
                    .offset(y: top + side)

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.43), lineWidth: 1.5)
                    .frame(width: side, height: side)
                    .offset(x: left, y: top)

                QRCornerMarks()
                    .stroke(Theme.brand, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: side, height: side)
                    .offset(x: left, y: top)

                Capsule()
                    .fill(Theme.brand.opacity(0.82))
                    .frame(width: side - 44, height: 1.5)
                    .offset(
                        x: left + 22,
                        y: top + 26 + (reduceMotion ? (side - 52) / 2 : (side - 52) * scanProgress)
                    )

                Text("对准电脑端 Wand「设置 → 连接 App」的二维码")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(width: min(proxy.size.width - 48, 360))
                    .position(x: proxy.size.width / 2, y: top + side + 42)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            scanProgress = 0
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                scanProgress = 1
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            scanProgress = 0
            guard !reduced else { return }
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                scanProgress = 1
            }
        }
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
            }
            .buttonStyle(WandPrimaryButtonStyle())
            .padding(.top, 6)
        }
        .padding(32)
    }

    private func scannerFailureView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 34))
                .foregroundColor(.white.opacity(0.7))
            Text("无法启动扫码相机")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("重试") {
                handled = false
                authState = .granted
            }
            .buttonStyle(WandPrimaryButtonStyle())
            Button("返回手动输入") { dismiss() }
                .foregroundColor(.white.opacity(0.8))
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

private struct QRCornerMarks: Shape {
    func path(in rect: CGRect) -> Path {
        let length: CGFloat = 26
        let inset: CGFloat = 2
        var path = Path()
        path.move(to: CGPoint(x: inset, y: inset + length))
        path.addLine(to: CGPoint(x: inset, y: inset))
        path.addLine(to: CGPoint(x: inset + length, y: inset))
        path.move(to: CGPoint(x: rect.maxX - inset - length, y: inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: inset + length))
        path.move(to: CGPoint(x: inset, y: rect.maxY - inset - length))
        path.addLine(to: CGPoint(x: inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: inset + length, y: rect.maxY - inset))
        path.move(to: CGPoint(x: rect.maxX - inset - length, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset - length))
        return path
    }
}

// MARK: - 相机预览 + QR 识别

/// AVCaptureSession 包装：后台队列配置/启停，主队列回调识别结果。
private struct CameraPreview: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onCode = onCode
        vc.onFailure = onFailure
        return vc
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {}

    static func dismantleUIViewController(_ vc: ScannerController, coordinator: ()) {
        vc.shutdown()
    }

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        var onFailure: ((String) -> Void)?

        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "wand.qr.session")
        private var previewLayer: AVCaptureVideoPreviewLayer?

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
            shutdown()
        }

        func shutdown() {
            onCode = nil
            onFailure = nil
            let session = session
            sessionQueue.async {
                if session.isRunning { session.stopRunning() }
            }
        }

        private func configureAndStart() {
            guard let device = AVCaptureDevice.default(for: .video) else {
                reportFailure("当前设备没有可用相机，请返回手动粘贴连接码。")
                return
            }
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                reportFailure("无法打开相机：\(error.localizedDescription)")
                return
            }
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                reportFailure("无法配置相机输入，请关闭其他占用相机的 App 后重试。")
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                reportFailure("当前设备无法配置二维码识别输出。")
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            guard output.availableMetadataObjectTypes.contains(.qr) else {
                session.commitConfiguration()
                reportFailure("当前相机不支持二维码识别。")
                return
            }
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            session.startRunning()
        }

        private func reportFailure(_ message: String) {
            DispatchQueue.main.async { [weak self] in
                self?.onFailure?(message)
            }
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
