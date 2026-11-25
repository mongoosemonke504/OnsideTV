import Foundation
import UIKit
import AVFoundation

/// One recording in progress: the download, and the background audio that
/// lets it carry on with the app away.
class StreamRecorder: NSObject {
    private let streamURL: URL
    private let download: RecordingDownload
    private var isRecording = false

    /// Runs when the file is complete and closed.
    var onCompletion: (() -> Void)?

    private var silentAudioPlayer: AVAudioPlayer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(streamURL: URL, outputURL: URL) {
        self.streamURL = streamURL
        download = RecordingDownload(source: streamURL, output: outputURL)
        super.init()
        setupLifecycleObservers()
        setupSilentAudio()
    }

    /// Whether video reached the file in the last `seconds`.
    func received(within seconds: TimeInterval) async -> Bool {
        await download.lastWrite.map { Date().timeIntervalSince($0) < seconds } ?? false
    }

    /// The disk filled up.
    func outOfSpace() async -> Bool { await download.writeFailed }

    /// The background audio may have been stopped by a call or another app.
    func resumeAudioIfNeeded() {
        guard isRecording, silentAudioPlayer?.isPlaying == false else { return }
        silentAudioPlayer?.play()
    }

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    
    private func beginBackgroundTask() {
        if backgroundTask != .invalid { return }
        print("🛡️ [StreamRecorder] Beginning Background Task assertion.")
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NebuloRecording") { [weak self] in
            print("⚠️ [StreamRecorder] System forcing expiration of background task!")
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            print("🛡️ [StreamRecorder] Ending Background Task assertion.")
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    /// 10 seconds of silent 16-bit mono WAV. Looped at near-zero volume it
    /// keeps the process alive in the background (the app declares the
    /// `audio` background mode) — shared by the recorder and the
    /// RecordingManager's scheduled-recording keep-alive.
    static func makeSilentWAV() -> Data {
        let sampleRate: Int32 = 44100
        let duration = 10
        let numSamples = sampleRate * Int32(duration)
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let blockAlign = numChannels * bitsPerSample / 8
        let byteRate = sampleRate * Int32(blockAlign)
        let dataSize = numSamples * Int32(blockAlign)
        let chunkSize = 36 + dataSize

        var data = Data()

        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        data.append(withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Data($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])

        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        data.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        data.append(Data(count: Int(dataSize)))

        return data
    }

    private func setupSilentAudio() {
        let data = Self.makeSilentWAV()
        do {
            // Only reconfigure the shared session when the player is idle —
            // its NON-mixable session is what keeps the app as the system's
            // Now Playing app, and flipping it to mixable mid-playback
            // knocked the lock-screen media card out.
            if !PlayerEngine.shared.isPlaying {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowAirPlay])
                try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            }

            silentAudioPlayer = try AVAudioPlayer(data: data)
            silentAudioPlayer?.numberOfLoops = -1 
            silentAudioPlayer?.volume = 0.01 
            silentAudioPlayer?.prepareToPlay()
            print("✅ [StreamRecorder] Silent Audio Player Ready")
        } catch {
            print("⚠️ [StreamRecorder] Silent Audio Setup Failed: \(error)")
        }
    }
    
    @objc private func handleDidEnterBackground() { resumeAudioIfNeeded() }
    
    func start() {
        guard !isRecording else { return }
        isRecording = true
        beginBackgroundTask()
        
        
        do {
            // Same rule as setupSilentAudio: never demote the player's
            // non-mixable session to mixable while a stream is playing.
            if !PlayerEngine.shared.isPlaying {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowAirPlay])
                try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            }
            silentAudioPlayer?.play()
        } catch {
            print("⚠️ [StreamRecorder] Failed to activate audio session: \(error)")
        }
        
        print("🔴 [StreamRecorder] Recording \(streamURL.host ?? "")")

        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.endBackgroundTask()
        }

        Task { await download.start() }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        NotificationCenter.default.removeObserver(self)
        Task {
            await download.stop()
            silentAudioPlayer?.stop()
            endBackgroundTask()
            onCompletion?()
        }
    }
}
