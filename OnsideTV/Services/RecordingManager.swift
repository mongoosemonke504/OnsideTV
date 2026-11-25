import Foundation
import Combine
import AVFoundation
import UIKit

class RecordingManager: NSObject, ObservableObject {
    static let shared = RecordingManager()

    @Published var recordings: [Recording] = []


    private var activeRecorders: [UUID: StreamRecorder] = [:]

    private let recordingsKey = "saved_recordings_v1"

    /// Silent looped audio that holds the process open while backgrounded.
    /// Without it, iOS suspends the app ~20-30s after backgrounding: pending
    /// schedule timers freeze (the recording "just never starts") and an
    /// in-flight recording's URLSession stops (~20s captured, then nothing).
    /// Armed on every background transition while ANY recording is active or
    /// still scheduled ahead; torn down on foreground and when idle.
    private var keepAlivePlayer: AVAudioPlayer?

    /// Starts, stops and watches over recordings while any are under way or
    /// ahead. A repeating check against the clock rather than a timer per
    /// recording: one of those is lost with the app, and stands still while
    /// the phone sleeps.
    private var clock: Timer?
    private var lastHeartbeat = Date.distantPast

    override init() {
        super.init()
        loadRecordings()
        checkSchedules()
        // Recordings scheduled before these existed.
        for rec in recordings where rec.status == .scheduled { RecordingAlerts.schedule(for: rec) }

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    /// A call or another app's audio stops the silent loop that keeps the app
    /// running; when it's over, the loop has to be started again by hand.
    @objc private func audioInterrupted(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
        holdBackground()
    }

    /// Makes sure the app is still being kept awake, if it is in the
    /// background with something to record.
    private func holdBackground() {
        guard needsBackgroundRuntime, UIApplication.shared.applicationState == .background else { return }
        startKeepAliveAudio()
        for recorder in activeRecorders.values { recorder.resumeAudioIfNeeded() }
    }

    /// When the next scheduled recording starts, for the background refresh to
    /// be asked for around then.
    var nextScheduledStart: Date? {
        recordings.filter { $0.status == .scheduled && $0.endTime > Date() }.map(\.startTime).min()
    }

    private func updateClock() {
        guard needsBackgroundRuntime else {
            clock?.invalidate()
            clock = nil
            return
        }
        guard clock == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { RecordingManager.shared.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func tick() {
        checkSchedules()
        holdBackground()

        let now = Date()
        for rec in recordings where rec.status == .scheduled
            && rec.startTime.timeIntervalSince(now) <= RecordingAlerts.headsUpLead + 45 {
            // Still here, and about to start it: no need to ask for the app.
            RecordingAlerts.clearHeadsUp(rec.id)
        }

        guard now.timeIntervalSince(lastHeartbeat) >= 30 else { return }
        lastHeartbeat = now
        for (id, recorder) in activeRecorders {
            Task {
                if await recorder.outOfSpace() {
                    guard activeRecorders[id] === recorder else { return }
                    if let rec = recordings.first(where: { $0.id == id }) { RecordingAlerts.storageFull(rec) }
                    stopRecording(id)
                } else if await recorder.received(within: 45), activeRecorders[id] === recorder,
                          let rec = recordings.first(where: { $0.id == id }) {
                    RecordingAlerts.stillRecording(rec)
                }
            }
        }
    }

    // MARK: - Background keep-alive

    private var needsBackgroundRuntime: Bool {
        let now = Date()
        return recordings.contains {
            $0.status == .recording || ($0.status == .scheduled && $0.endTime > now)
        }
    }

    @objc private func appDidEnterBackground() {
        guard needsBackgroundRuntime else { return }
        startKeepAliveAudio()
    }

    @objc private func appDidBecomeActive() {
        // Foregrounded — the process can't suspend, so the loop is dead
        // weight (active StreamRecorders manage their own audio session).
        stopKeepAliveAudio()
        // Catch anything that slipped while we were suspended: overdue
        // scheduled recordings start now, fully-missed windows are failed.
        checkSchedules()
    }

    private func startKeepAliveAudio() {
        if keepAlivePlayer?.isPlaying == true { return }
        do {
            // Don't reconfigure the session while the player is active: the
            // player's NON-mixable session is what keeps the app as the
            // system's Now Playing app (lock-screen media card), and it
            // already holds the process open. The mixable category is only
            // for the recording-with-nothing-playing case.
            if !PlayerEngine.shared.isPlaying {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
            }
            if keepAlivePlayer == nil {
                keepAlivePlayer = try AVAudioPlayer(data: StreamRecorder.makeSilentWAV())
                keepAlivePlayer?.numberOfLoops = -1
                keepAlivePlayer?.volume = 0.01
            }
            keepAlivePlayer?.prepareToPlay()
            keepAlivePlayer?.play()
            print("🛡️ [RecordingManager] Background keep-alive audio started.")
        } catch {
            print("⚠️ [RecordingManager] Keep-alive audio failed: \(error)")
        }
    }

    private func stopKeepAliveAudio() {
        guard keepAlivePlayer?.isPlaying == true else { return }
        keepAlivePlayer?.stop()
        print("🛡️ [RecordingManager] Background keep-alive audio stopped.")
    }

    /// A recording just finished or failed — drop the keep-alive if nothing
    /// else needs background runtime, so the silent loop never outlives its
    /// purpose and drains the battery.
    private func reassessKeepAlive() {
        if UIApplication.shared.applicationState == .background, needsBackgroundRuntime {
            startKeepAliveAudio()
        } else {
            stopKeepAliveAudio()
        }
    }

    /// Brings every recording in line with the clock: starts what is due,
    /// ends what is over, picks up what the app died in the middle of, and
    /// fails what was missed entirely.
    func checkSchedules() {
        let now = Date()
        for rec in recordings {
            switch rec.status {
            case .recording:
                if activeRecorders[rec.id] != nil {
                    if rec.endTime <= now { stopRecording(rec.id) }
                } else if rec.endTime > now {
                    // The process died mid-recording: add to what it got.
                    startRecording(rec)
                } else if let i = recordings.firstIndex(where: { $0.id == rec.id }) {
                    finalizeStaleRecording(index: i)
                }
            case .scheduled:
                if rec.endTime <= now {
                    if let i = recordings.firstIndex(where: { $0.id == rec.id }) {
                        recordings[i].status = .failed
                        saveRecordings()
                    }
                    RecordingAlerts.clear(rec.id)
                } else if rec.startTime <= now {
                    startRecording(rec)
                }
            default:
                break
            }
        }
        updateClock()
    }

    private func finalizeStaleRecording(index: Int) {
        let rec = recordings[index]
        RecordingAlerts.clear(rec.id)
        let filename = "\(rec.id.uuidString).ts"
        let url = getDocumentsDirectory().appendingPathComponent(filename)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        if size > 1024 * 1024 {
            recordings[index].status = .completed
            recordings[index].localFileName = filename
            saveRecordings()
            measure(filename: filename, recordingID: rec.id)
            // Remux any stale .ts left from a previous crash so it gets a
            // seek table and switches to KSPlayer on next playback.
            remuxToMP4(tsFilename: filename, recordingID: rec.id)
        } else {
            recordings[index].status = .failed
            saveRecordings()
        }
    }
    
    func scheduleRecording(channel: StreamChannel, startTime: Date, endTime: Date, programTitle: String? = nil, programDescription: String? = nil, category: Recording.RecordingCategory = .other) {
        let recording = Recording(
            id: UUID(),
            channelName: channel.name,
            channelIcon: channel.icon,
            streamURL: channel.streamURL,
            hasArchive: channel.hasArchive,
            startTime: startTime,
            endTime: endTime,
            createdAt: Date(),
            programTitle: programTitle,
            programDescription: programDescription,
            status: .scheduled,
            localFileName: nil,
            category: category
        )
        
        recordings.append(recording)
        saveRecordings()
        
        
        RecordingAlerts.requestPermission()
        if startTime > Date() { RecordingAlerts.schedule(for: recording) }
        checkSchedules()
    }

    private func startRecording(_ recording: Recording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        
        
        if activeRecorders[recording.id] != nil { return }
        
        recordings[index].status = .recording
        saveRecordings()
        RecordingAlerts.recordingStarted(recording)
        
        guard let url = URL(string: recording.streamURL) else {
            failRecording(recording, reason: "Invalid URL")
            return
        }

        let filename = "\(recording.id.uuidString).ts"
        let outputURL = getDocumentsDirectory().appendingPathComponent(filename)

        // ── No hijack ──────────────────────────────────────────────────────────
        // The recorder downloads HLS segments via its own URLSession; the player
        // can continue streaming the same channel in parallel without conflict.
        // Stopping the player here was the root cause of "stream stops on record".
        // ──────────────────────────────────────────────────────────────────────

        let recorder = StreamRecorder(streamURL: url, outputURL: outputURL)

        recorder.onCompletion = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.activeRecorders.removeValue(forKey: recording.id)
                RecordingAlerts.clear(recording.id)
                defer {
                    self.reassessKeepAlive()
                    self.updateClock()
                }
                // Deleted while it was recording: nothing to keep.
                guard let idx = self.recordings.firstIndex(where: { $0.id == recording.id }) else { return }

                let fileURL = self.getDocumentsDirectory().appendingPathComponent(filename)
                let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

                if size > 1024 * 1024 {
                    // Mark completed with the .ts file first so the recording is
                    // immediately playable (via VLC) while the remux runs.
                    self.recordings[idx].status = .completed
                    self.recordings[idx].localFileName = filename
                    // Capture the actual recorded length. A recording stopped
                    // early runs far shorter than its scheduled window, so the
                    // wall-clock elapsed since start is the real seekable length
                    // (clamped so it can never exceed the scheduled end). The
                    // exact value is refined from the MP4 once the remux runs.
                    let wall = Date().timeIntervalSince(recording.startTime)
                    let scheduled = recording.endTime.timeIntervalSince(recording.startTime)
                    self.recordings[idx].recordedDuration = max(1, min(wall, scheduled))
                    self.saveRecordings()
                    self.measure(filename: filename, recordingID: recording.id)

                    // Remux to MP4 in the background.  KSPlayer/AVPlayer will then
                    // give perfectly accurate scrubbing via the moov seek table.
                    self.remuxToMP4(tsFilename: filename, recordingID: recording.id)
                } else {
                    print("⚠️ Recording too small (\(size) bytes), marking as failed.")
                    self.recordings[idx].status = .failed
                    try? FileManager.default.removeItem(at: fileURL)
                    self.saveRecordings()
                }
            }
        }

        activeRecorders[recording.id] = recorder
        recorder.start()

    }

    /// The length of what was actually recorded, read from the file. The time
    /// between start and end overstates it for a recording that started late
    /// or had a gap in the middle.
    private func measure(filename: String, recordingID: UUID) {
        let url = getDocumentsDirectory().appendingPathComponent(filename)
        Task {
            guard let length = await RecordingHLSServer.index(file: url)?.duration, length > 1,
                  let idx = recordings.firstIndex(where: { $0.id == recordingID }),
                  recordings[idx].localFileName == filename else { return }
            recordings[idx].recordedDuration = length
            saveRecordings()
        }
    }
    
    func stopRecording(_ id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        
        if let recorder = activeRecorders[id] {
            recorder.stop() 
        } else {
            
            if recordings[index].status == .recording {
                recordings[index].status = .completed
                saveRecordings()
            }
        }
    }
    
    func renameRecording(_ recording: Recording, newName: String) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index].customTitle = newName
            saveRecordings()
        }
    }
    
    func deleteRecording(_ recording: Recording) {
        
        if activeRecorders[recording.id] != nil {
            stopRecording(recording.id)
        }
        RecordingAlerts.clear(recording.id)

        // One still recording has no name on it yet, only its file.
        let path = recording.localFileName ?? "\(recording.id.uuidString).ts"
        try? FileManager.default.removeItem(at: getDocumentsDirectory().appendingPathComponent(path))

        recordings.removeAll { $0.id == recording.id }
        saveRecordings()
        updateClock()
    }
    
    private func failRecording(_ recording: Recording, reason: String) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index].status = .failed
            saveRecordings()
        }
        print("Recording failed: \(reason)")
    }
    
    func isRecording(channelName: String) -> Bool {
        // No log line here: the player controls ask this from their body, so
        // it ran on every render of the player.
        recordings.contains(where: { $0.channelName == channelName && $0.status == .recording })
    }
    
    private func loadRecordings() {
        if let data = UserDefaults.standard.data(forKey: recordingsKey),
           let decoded = try? JSONDecoder().decode([Recording].self, from: data) {
            recordings = decoded
        }
    }
    
    private func saveRecordings() {
        if let encoded = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(encoded, forKey: recordingsKey)
        }
    }
    
    // MARK: - MP4 remux

    /// Remuxes a completed .ts recording into .mp4 without re-encoding.
    ///
    /// Why: MPEG-TS doesn't carry a seek index.  The MP4 container has a moov
    /// atom that AVPlayer (KSPlayer) can use to seek instantly and accurately.
    /// No re-encoding means zero quality loss and a fast operation — typically
    /// 5-20 seconds for a 1-hour recording.
    ///
    /// On success:  localFileName is updated to the .mp4 path; the .ts is deleted.
    /// On failure:  the .ts is kept as-is and VLC continues to play it.
    private func remuxToMP4(tsFilename: String, recordingID: UUID) {
        let docsDir = getDocumentsDirectory()
        let tsURL   = docsDir.appendingPathComponent(tsFilename)
        let mp4Filename = tsFilename.replacingOccurrences(of: ".ts", with: ".mp4")
        let mp4URL  = docsDir.appendingPathComponent(mp4Filename)

        // Clean up any stale file from a previous failed attempt.
        try? FileManager.default.removeItem(at: mp4URL)

        let asset = AVURLAsset(url: tsURL)

        // Prefer passthrough (no transcode).  Fall back to high-quality preset
        // if the container or codec isn't compatible with passthrough.
        let supportedPresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let preset: String
        if supportedPresets.contains(AVAssetExportPresetPassthrough) {
            preset = AVAssetExportPresetPassthrough
        } else if supportedPresets.contains(AVAssetExportPresetHighestQuality) {
            preset = AVAssetExportPresetHighestQuality
        } else {
            print("⚠️ [RecordingManager] No compatible export preset for \(tsFilename). Keeping .ts.")
            return
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            print("⚠️ [RecordingManager] Could not create export session for \(tsFilename).")
            return
        }
        session.outputURL      = mp4URL
        session.outputFileType = .mp4

        print("🔄 [RecordingManager] Remuxing \(tsFilename) → \(mp4Filename) …")
        session.exportAsynchronously { [weak self] in
            guard let self else { return }
            switch session.status {
            case .completed:
                // Probe the remuxed MP4's real duration — reliable now that the
                // container has a moov atom — and store it as the seekable
                // truth, replacing the wall-clock estimate. This is what stops
                // the scrubber from running past the end of the recording.
                Task { [weak self] in
                    guard let self else { return }
                    let probed = (try? await AVURLAsset(url: mp4URL).load(.duration))?.seconds
                    await MainActor.run {
                        if let idx = self.recordings.firstIndex(where: { $0.id == recordingID }) {
                            self.recordings[idx].localFileName = mp4Filename
                            if let d = probed, d.isFinite, d > 0 {
                                self.recordings[idx].recordedDuration = d
                            }
                            self.saveRecordings()
                        }
                        try? FileManager.default.removeItem(at: tsURL)
                        print("✅ [RecordingManager] Remux complete: \(mp4Filename)")
                    }
                }
            case .failed:
                print("⚠️ [RecordingManager] Remux failed (\(session.error?.localizedDescription ?? "?")). Keeping .ts file.")
            default:
                break
            }
        }
    }

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func getPlaybackURL(for recording: Recording) -> URL? {
        if let filename = recording.localFileName {
            let url = getDocumentsDirectory().appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return resolveFallbackURL(for: recording)
    }
    
    private func resolveFallbackURL(for recording: Recording) -> URL? {
        guard recording.hasArchive, let original = URL(string: recording.streamURL) else { return nil }
        let urlString = original.absoluteString
        
        
        if urlString.contains("/live/") {
            let durationMinutes = Int(recording.duration / 60)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd:HH-mm"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let startString = formatter.string(from: recording.startTime)
            
            let newString = urlString.replacingOccurrences(of: "/live/", with: "/timeshift/")
            if let lastSlash = newString.lastIndex(of: "/") {
                let prefix = newString[..<lastSlash]
                let idPart = newString[newString.index(after: lastSlash)...]
                let streamID = idPart.components(separatedBy: ".").first ?? String(idPart)
                
                
                let finalURLString = "\(prefix)/\(durationMinutes)/\(startString)/\(streamID).m3u8"
                return URL(string: finalURLString)
            }
        }
        return nil
    }
}
