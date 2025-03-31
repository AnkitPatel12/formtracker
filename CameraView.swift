import SwiftUI
import AVFoundation

struct CameraViewControllerRepresentable: UIViewControllerRepresentable {
    @ObservedObject var recordingManager: RecordingManager
    @Binding var isRecording: Bool
    
    func makeUIViewController(context: Context) -> CameraViewController {
        let controller = CameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {
        if isRecording {
            uiViewController.startRecording()
        } else {
            uiViewController.stopRecording()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, CameraViewControllerDelegate {
        let parent: CameraViewControllerRepresentable
        
        init(_ parent: CameraViewControllerRepresentable) {
            self.parent = parent
        }
        
        func didFinishRecording(url: URL) {
            parent.recordingManager.addRecording(url: url)
            parent.isRecording = false
        }
    }
}

protocol CameraViewControllerDelegate: AnyObject {
    func didFinishRecording(url: URL)
}

class CameraViewController: UIViewController {
    weak var delegate: CameraViewControllerDelegate?
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureMovieFileOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var recordButton: UIButton?
    private var timerLabel: UILabel?
    private var recordingTimer: Timer?
    private var recordingDuration: TimeInterval = 0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
        setupUI()
    }
    
    private func setupCamera() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        
        session.addInput(input)
        
        let movieOutput = AVCaptureMovieFileOutput()
        session.addOutput(movieOutput)
        videoOutput = movieOutput
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
        
        captureSession = session
    }
    
    private func setupUI() {
        // Record Button
        let button = UIButton(type: .system)
        button.setTitle("Record", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 25
        button.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            button.widthAnchor.constraint(equalToConstant: 100),
            button.heightAnchor.constraint(equalToConstant: 50)
        ])
        
        recordButton = button
        
        // Timer Label
        let label = UILabel()
        label.textColor = .white
        label.font = .systemFont(ofSize: 24, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20)
        ])
        
        timerLabel = label
    }
    
    @objc private func toggleRecording() {
        if videoOutput?.isRecording == true {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    func startRecording() {
        guard let videoOutput = videoOutput else { return }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoName = "golf_swing_\(Date().timeIntervalSince1970).mov"
        let videoPath = documentsPath.appendingPathComponent(videoName)
        
        videoOutput.startRecording(to: videoPath, recordingDelegate: self)
        recordButton?.setTitle("Stop", for: .normal)
        recordButton?.backgroundColor = .systemRed
        
        // Start timer
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recordingDuration += 1
            self?.updateTimerLabel()
        }
    }
    
    func stopRecording() {
        videoOutput?.stopRecording()
        recordButton?.setTitle("Record", for: .normal)
        recordButton?.backgroundColor = .systemBlue
        
        // Stop timer
        recordingTimer?.invalidate()
        recordingTimer = nil
        timerLabel?.text = ""
    }
    
    private func updateTimerLabel() {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        timerLabel?.text = String(format: "%02d:%02d", minutes, seconds)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        captureSession?.startRunning()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }
}

extension CameraViewController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            print("Error recording video: \(error.localizedDescription)")
            return
        }
        
        delegate?.didFinishRecording(url: outputFileURL)
    }
} 