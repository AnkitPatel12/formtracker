import Vision
import CoreML
import AVFoundation
import UIKit

class VisionAnalysisService: ObservableObject {
    @Published var isAnalyzing = false
    @Published var analysisProgress: Double = 0
    
    private let poseRequest: VNDetectHumanBodyPoseRequest
    private let handPoseRequest: VNDetectHumanHandPoseRequest
    
    // Constants for swing analysis
    private let backswingAngleThreshold: CGFloat = 85
    private let downswingAngleThreshold: CGFloat = 45
    private let followThroughAngleThreshold: CGFloat = 15
    private let minConfidence: Float = 0.1  // Lowered confidence threshold
    
    init() {
        poseRequest = VNDetectHumanBodyPoseRequest()
        handPoseRequest = VNDetectHumanHandPoseRequest()
        
        // Configure requests for best available detection
        poseRequest.revision = VNDetectHumanBodyPoseRequestRevision1
        handPoseRequest.revision = VNDetectHumanHandPoseRequestRevision1
    }
    
    func analyzeVideo(url: URL) async throws -> String {
        isAnalyzing = true
        analysisProgress = 0
        
        print("Starting video analysis...")
        
        // Create asset and generator
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)  // Increased size for better detection
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        // Get video duration and frame rate
        let duration = try await asset.load(.duration)
        let frameRate: Float64 = 30
        let totalFrames = Int(duration.seconds * frameRate)
        let frameInterval = max(1, totalFrames / 30)  // Analyze more frames (every 30th frame)
        
        print("Starting analysis of video: \(url.lastPathComponent)")
        print("Video duration: \(duration.seconds) seconds")
        print("Total frames: \(totalFrames)")
        print("Analyzing every \(frameInterval) frames")
        
        var swingPhases: [SwingPhase] = []
        var keyPoints: [KeyPoint] = []
        var spineAngles: [CGFloat] = []
        var hipRotations: [CGFloat] = []
        var shoulderRotations: [CGFloat] = []
        
        // Get video orientation
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw NSError(domain: "VisionAnalysis", code: -1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }
        
        let transform = try await track.load(.preferredTransform)
        let size = try await track.load(.naturalSize)
        
        // Calculate video orientation
        var videoAngle: CGFloat = 0
        if transform.b == 1.0 && transform.c == -1.0 {
            videoAngle = 90
        } else if transform.b == -1.0 && transform.c == 1.0 {
            videoAngle = -90
        } else if transform.a == -1.0 && transform.d == -1.0 {
            videoAngle = 180
        }
        
        print("Video orientation angle: \(videoAngle)°")
        print("Video size: \(size)")
        
        // Analyze frames
        for frameNumber in stride(from: 0, to: totalFrames, by: frameInterval) {
            let time = CMTime(seconds: Double(frameNumber) / frameRate, preferredTimescale: 600)
            
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                print("Analyzing frame \(frameNumber): Image size \(cgImage.width)x\(cgImage.height)")
                
                let analysis = try await analyzeFrame(cgImage, videoAngle: videoAngle)
                
                if let phase = analysis.phase {
                    swingPhases.append(phase)
                    print("Frame \(frameNumber): Detected \(phase)")
                }
                
                if let spineAngle = analysis.spineAngle {
                    spineAngles.append(spineAngle)
                    print("Frame \(frameNumber): Spine angle \(spineAngle)°")
                }
                
                if let hipRotation = analysis.hipRotation {
                    hipRotations.append(hipRotation)
                }
                
                if let shoulderRotation = analysis.shoulderRotation {
                    shoulderRotations.append(shoulderRotation)
                }
                
                keyPoints.append(contentsOf: analysis.keyPoints)
                
                await MainActor.run {
                    analysisProgress = Double(frameNumber) / Double(totalFrames)
                }
            } catch {
                print("Error analyzing frame \(frameNumber): \(error)")
            }
        }
        
        print("Analysis complete. Found \(swingPhases.count) swing phases")
        print("Spine angles detected: \(spineAngles.count)")
        print("Hip rotations detected: \(hipRotations.count)")
        print("Shoulder rotations detected: \(shoulderRotations.count)")
        
        // Generate analysis report
        let report = generateAnalysisReport(
            swingPhases: swingPhases,
            keyPoints: keyPoints,
            spineAngles: spineAngles,
            hipRotations: hipRotations,
            shoulderRotations: shoulderRotations
        )
        
        isAnalyzing = false
        return report
    }
    
    private func analyzeFrame(_ cgImage: CGImage, videoAngle: CGFloat) async throws -> (phase: SwingPhase?, keyPoints: [KeyPoint], spineAngle: CGFloat?, hipRotation: CGFloat?, shoulderRotation: CGFloat?) {
        // Create oriented image
        let ciImage = CIImage(cgImage: cgImage)
        
        // For vertical videos, always use right orientation to analyze the side view
        let orientation: CGImagePropertyOrientation = .right
        
        let requestHandler = VNImageRequestHandler(ciImage: ciImage, orientation: orientation, options: [:])
        
        // Detect body pose
        try requestHandler.perform([poseRequest])
        guard let poseObservation = poseRequest.results?.first else {
            print("No pose detected in frame")
            return (nil, [], nil, nil, nil)
        }
        
        print("Pose detected with confidence: \(poseObservation.confidence)")
        
        // Print all available points for debugging
        var detectedPoints = 0
        try poseObservation.availableJointNames.forEach { joint in
            if let point = try? poseObservation.recognizedPoint(joint) {
                if point.confidence > minConfidence {
                    detectedPoints += 1
                    print("Joint \(joint): position (\(point.location.x), \(point.location.y)) confidence \(point.confidence)")
                }
            }
        }
        print("Total points detected with confidence > \(minConfidence): \(detectedPoints)")
        
        // Detect hand pose
        try requestHandler.perform([handPoseRequest])
        let handObservations = handPoseRequest.results ?? []
        
        // Extract key points
        let keyPoints = extractKeyPoints(from: poseObservation, handObservations: handObservations)
        
        // Calculate metrics
        let spineAngle = calculateSpineAngle(keyPoints: keyPoints)
        let hipRotation = calculateHipRotation(keyPoints: keyPoints)
        let shoulderRotation = calculateShoulderRotation(keyPoints: keyPoints)
        
        // Determine swing phase
        let phase = determineSwingPhase(spineAngle: spineAngle)
        
        if let spineAngle = spineAngle {
            print("Calculated spine angle: \(spineAngle)°")
        }
        if let hipRotation = hipRotation {
            print("Calculated hip rotation: \(hipRotation)°")
        }
        if let shoulderRotation = shoulderRotation {
            print("Calculated shoulder rotation: \(shoulderRotation)°")
        }
        
        return (phase, keyPoints, spineAngle, hipRotation, shoulderRotation)
    }
    
    private func extractKeyPoints(from poseObservation: VNHumanBodyPoseObservation, handObservations: [VNHumanHandPoseObservation]) -> [KeyPoint] {
        var keyPoints: [KeyPoint] = []
        
        // Helper function to normalize coordinates for vertical video
        func normalizePoint(_ point: CGPoint) -> CGPoint {
            // For vertical videos, swap x and y coordinates and adjust for orientation
            return CGPoint(x: 1 - point.y, y: point.x)
        }
        
        // Extract body key points with confidence check
        if let root = try? poseObservation.recognizedPoint(.root), root.confidence > minConfidence {
            keyPoints.append(KeyPoint(type: .root, position: normalizePoint(root.location)))
            print("Root point detected at: \(normalizePoint(root.location))")
        }
        
        if let leftHip = try? poseObservation.recognizedPoint(.leftHip), leftHip.confidence > minConfidence {
            keyPoints.append(KeyPoint(type: .leftHip, position: normalizePoint(leftHip.location)))
            print("Left hip detected at: \(normalizePoint(leftHip.location))")
        }
        
        if let rightHip = try? poseObservation.recognizedPoint(.rightHip), rightHip.confidence > minConfidence {
            keyPoints.append(KeyPoint(type: .rightHip, position: normalizePoint(rightHip.location)))
            print("Right hip detected at: \(normalizePoint(rightHip.location))")
        }
        
        if let leftShoulder = try? poseObservation.recognizedPoint(.leftShoulder), leftShoulder.confidence > minConfidence {
            keyPoints.append(KeyPoint(type: .leftShoulder, position: normalizePoint(leftShoulder.location)))
            print("Left shoulder detected at: \(normalizePoint(leftShoulder.location))")
        }
        
        if let rightShoulder = try? poseObservation.recognizedPoint(.rightShoulder), rightShoulder.confidence > minConfidence {
            keyPoints.append(KeyPoint(type: .rightShoulder, position: normalizePoint(rightShoulder.location)))
            print("Right shoulder detected at: \(normalizePoint(rightShoulder.location))")
        }
        
        // Extract hand key points
        for observation in handObservations {
            if let wrist = try? observation.recognizedPoint(.wrist), wrist.confidence > minConfidence {
                keyPoints.append(KeyPoint(type: .wrist, position: normalizePoint(wrist.location)))
                print("Wrist detected at: \(normalizePoint(wrist.location))")
            }
        }
        
        print("Extracted \(keyPoints.count) key points")
        return keyPoints
    }
    
    private func determineSwingPhase(spineAngle: CGFloat?) -> SwingPhase? {
        guard let angle = spineAngle else { return nil }
        
        print("Spine angle: \(angle)°")
        
        // Adjusted logic for golf swing phases
        if angle > backswingAngleThreshold {
            return .backswing
        } else if angle < followThroughAngleThreshold {
            return .followThrough
        } else if angle < downswingAngleThreshold {
            return .downswing
        }
        return nil
    }
    
    private func calculateSpineAngle(keyPoints: [KeyPoint]) -> CGFloat? {
        guard let root = keyPoints.first(where: { $0.type == .root }),
              let leftShoulder = keyPoints.first(where: { $0.type == .leftShoulder }),
              let rightShoulder = keyPoints.first(where: { $0.type == .rightShoulder }) else {
            return nil
        }
        
        // Calculate spine angle relative to vertical
        let shoulderCenter = CGPoint(
            x: (leftShoulder.position.x + rightShoulder.position.x) / 2,
            y: (leftShoulder.position.y + rightShoulder.position.y) / 2
        )
        
        let spineVector = CGPoint(
            x: shoulderCenter.x - root.position.x,
            y: shoulderCenter.y - root.position.y
        )
        
        // Calculate angle with vertical (90 degrees is vertical)
        let angle = abs(atan2(spineVector.x, spineVector.y) * 180 / .pi)
        return angle
    }
    
    private func calculateHipRotation(keyPoints: [KeyPoint]) -> CGFloat? {
        guard let leftHip = keyPoints.first(where: { $0.type == .leftHip }),
              let rightHip = keyPoints.first(where: { $0.type == .rightHip }) else {
            return nil
        }
        
        let vector = CGPoint(x: rightHip.position.x - leftHip.position.x,
                           y: rightHip.position.y - leftHip.position.y)
        return atan2(vector.y, vector.x) * 180 / .pi
    }
    
    private func calculateShoulderRotation(keyPoints: [KeyPoint]) -> CGFloat? {
        guard let leftShoulder = keyPoints.first(where: { $0.type == .leftShoulder }),
              let rightShoulder = keyPoints.first(where: { $0.type == .rightShoulder }) else {
            return nil
        }
        
        let vector = CGPoint(x: rightShoulder.position.x - leftShoulder.position.x,
                           y: rightShoulder.position.y - leftShoulder.position.y)
        return atan2(vector.y, vector.x) * 180 / .pi
    }
    
    private func generateAnalysisReport(
        swingPhases: [SwingPhase],
        keyPoints: [KeyPoint],
        spineAngles: [CGFloat],
        hipRotations: [CGFloat],
        shoulderRotations: [CGFloat]
    ) -> String {
        var report = "Swing Analysis:\n\n"
        
        // Analyze swing phases
        let backswingCount = swingPhases.filter { $0 == .backswing }.count
        let downswingCount = swingPhases.filter { $0 == .downswing }.count
        let followThroughCount = swingPhases.filter { $0 == .followThrough }.count
        
        let totalFrames = backswingCount + downswingCount + followThroughCount
        if totalFrames > 0 {
            let backswingPercentage = Double(backswingCount) / Double(totalFrames) * 100
            let downswingPercentage = Double(downswingCount) / Double(totalFrames) * 100
            let followThroughPercentage = Double(followThroughCount) / Double(totalFrames) * 100
            
            report += "Swing Phases:\n"
            report += "- Backswing: \(backswingCount) frames (\(String(format: "%.1f", backswingPercentage))%)\n"
            report += "- Downswing: \(downswingCount) frames (\(String(format: "%.1f", downswingPercentage))%)\n"
            report += "- Follow-through: \(followThroughCount) frames (\(String(format: "%.1f", followThroughPercentage))%)\n\n"
        } else {
            report += "No valid swing phases detected. Please ensure the video shows a clear view of your golf swing.\n\n"
        }
        
        // Analyze spine angle
        if !spineAngles.isEmpty {
            let avgSpineAngle = spineAngles.reduce(0, +) / CGFloat(spineAngles.count)
            let minSpineAngle = spineAngles.min() ?? 0
            let maxSpineAngle = spineAngles.max() ?? 0
            
            report += "Spine Angle Analysis:\n"
            report += "- Average angle: \(String(format: "%.1f", avgSpineAngle))°\n"
            report += "- Range: \(String(format: "%.1f", minSpineAngle))° to \(String(format: "%.1f", maxSpineAngle))°\n"
            
            if avgSpineAngle < 45 {
                report += "- Issue: Spine angle too shallow during backswing\n"
                report += "- Recommendation: Maintain a more upright spine angle for better rotation\n"
            } else if avgSpineAngle > 90 {
                report += "- Issue: Excessive spine tilt\n"
                report += "- Recommendation: Keep spine angle more neutral throughout the swing\n"
            }
            report += "\n"
        } else {
            report += "Spine angle analysis not available. Please ensure your spine is visible in the video.\n\n"
        }
        
        // Analyze hip rotation
        if !hipRotations.isEmpty {
            let avgHipRotation = hipRotations.reduce(0, +) / CGFloat(hipRotations.count)
            let maxHipRotation = hipRotations.max() ?? 0
            
            report += "Hip Rotation Analysis:\n"
            report += "- Average rotation: \(String(format: "%.1f", avgHipRotation))°\n"
            report += "- Maximum rotation: \(String(format: "%.1f", maxHipRotation))°\n"
            
            if maxHipRotation < 45 {
                report += "- Issue: Limited hip rotation\n"
                report += "- Recommendation: Focus on rotating hips more during backswing\n"
            } else if maxHipRotation > 90 {
                report += "- Issue: Excessive hip rotation\n"
                report += "- Recommendation: Maintain more stability in lower body\n"
            }
            report += "\n"
        } else {
            report += "Hip rotation analysis not available. Please ensure your hips are visible in the video.\n\n"
        }
        
        // Analyze shoulder rotation
        if !shoulderRotations.isEmpty {
            let avgShoulderRotation = shoulderRotations.reduce(0, +) / CGFloat(shoulderRotations.count)
            let maxShoulderRotation = shoulderRotations.max() ?? 0
            
            report += "Shoulder Rotation Analysis:\n"
            report += "- Average rotation: \(String(format: "%.1f", avgShoulderRotation))°\n"
            report += "- Maximum rotation: \(String(format: "%.1f", maxShoulderRotation))°\n"
            
            if maxShoulderRotation < 90 {
                report += "- Issue: Limited shoulder turn\n"
                report += "- Recommendation: Work on increasing shoulder rotation for more power\n"
            } else if maxShoulderRotation > 120 {
                report += "- Issue: Over-rotation of shoulders\n"
                report += "- Recommendation: Focus on maintaining better control during backswing\n"
            }
        } else {
            report += "Shoulder rotation analysis not available. Please ensure your shoulders are visible in the video.\n"
        }
        
        return report
    }
}

enum SwingPhase {
    case backswing
    case downswing
    case followThrough
}

struct KeyPoint {
    enum KeyPointType {
        case root
        case leftHip
        case rightHip
        case leftShoulder
        case rightShoulder
        case wrist
    }
    
    let type: KeyPointType
    let position: CGPoint
} 