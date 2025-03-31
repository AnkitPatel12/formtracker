//
//  ContentView.swift
//  formtracker
//
//  Created by Ankit Patel on 3/30/25.
//

import SwiftUI
import AVKit
import PhotosUI

struct GolfRecording: Identifiable {
    let id = UUID()
    let date: Date
    let videoURL: URL
    var analysis: String?
    var isAnalyzing: Bool = false
}

class RecordingManager: ObservableObject {
    @Published var recordings: [GolfRecording] = []
    @Published var isRecording = false
    private let analysisService = VisionAnalysisService()
    
    func addRecording(url: URL) {
        let recording = GolfRecording(date: Date(), videoURL: url, isAnalyzing: true)
        recordings.append(recording)
        
        // Start analysis
        Task {
            do {
                let analysis = try await analysisService.analyzeVideo(url: url)
                await MainActor.run {
                    if let index = recordings.firstIndex(where: { $0.videoURL == url }) {
                        recordings[index].analysis = analysis
                        recordings[index].isAnalyzing = false
                    }
                }
            } catch {
                print("Analysis failed: \(error.localizedDescription)")
                await MainActor.run {
                    if let index = recordings.firstIndex(where: { $0.videoURL == url }) {
                        recordings[index].isAnalyzing = false
                    }
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var recordingManager = RecordingManager()
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            RecordingsListView(recordingManager: recordingManager)
                .tabItem {
                    Label("Recordings", systemImage: "video.fill")
                }
                .tag(0)
            
            CameraTabView(recordingManager: recordingManager)
                .tabItem {
                    Label("Record", systemImage: "camera.fill")
                }
                .tag(1)
            
            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.fill")
                }
                .tag(2)
        }
    }
}

struct RecordingsListView: View {
    @ObservedObject var recordingManager: RecordingManager
    @State private var showingImagePicker = false
    @State private var selectedItem: PhotosPickerItem?
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        Label("Import from Camera Roll", systemImage: "photo.on.rectangle")
                    }
                }
                
                Section {
                    ForEach(recordingManager.recordings) { recording in
                        NavigationLink(destination: RecordingDetailView(recording: recording)) {
                            RecordingRow(recording: recording)
                        }
                    }
                }
            }
            .navigationTitle("My Recordings")
            .onChange(of: selectedItem) { newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        let videoName = "golf_swing_\(Date().timeIntervalSince1970).mov"
                        let videoPath = documentsPath.appendingPathComponent(videoName)
                        
                        try? data.write(to: videoPath)
                        recordingManager.addRecording(url: videoPath)
                    }
                }
            }
        }
    }
}

struct RecordingRow: View {
    let recording: GolfRecording
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoPlayer(player: AVPlayer(url: recording.videoURL))
                .frame(height: 200)
                .cornerRadius(12)
            
            Text(recording.date.formatted())
                .font(.headline)
            
            if recording.isAnalyzing {
                ProgressView("Analyzing...")
                    .progressViewStyle(CircularProgressViewStyle())
            } else if let analysis = recording.analysis {
                Text(analysis)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 8)
    }
}

struct RecordingDetailView: View {
    let recording: GolfRecording
    @State private var showingVideo = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VideoPlayer(player: AVPlayer(url: recording.videoURL))
                    .frame(height: 300)
                    .cornerRadius(12)
                
                Text("Date: \(recording.date.formatted())")
                    .font(.headline)
                
                if recording.isAnalyzing {
                    ProgressView("Analyzing...")
                        .progressViewStyle(CircularProgressViewStyle())
                } else if let analysis = recording.analysis {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Analysis")
                            .font(.title2)
                            .bold()
                        
                        Text(analysis)
                            .font(.body)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Swing Analysis")
    }
}

struct CameraTabView: View {
    @ObservedObject var recordingManager: RecordingManager
    @State private var isRecording = false
    
    var body: some View {
        NavigationView {
            CameraViewControllerRepresentable(recordingManager: recordingManager, isRecording: $isRecording)
                .navigationTitle("Record Swing")
        }
    }
}

struct ProfileView: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Account")) {
                    Text("Name")
                    Text("Email")
                    Text("Handicap")
                }
                
                Section(header: Text("Settings")) {
                    Toggle("Enable Analysis", isOn: .constant(true))
                    Toggle("Auto-upload", isOn: .constant(true))
                }
            }
            .navigationTitle("Profile")
        }
    }
}

#Preview {
    ContentView()
}

