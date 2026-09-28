import Cocoa
import CryptoKit
import AVFoundation
import CoreMedia
import CoreAudio
import UserNotifications
import ServiceManagement
import Carbon.HIToolbox
import PDFKit
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════════════════
// NotchDrop v7 — Universal Now Playing + Live Audio Island + Native Alarms
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - Color Palette
private enum C {
    static let black = NSColor.black
    static let cardBg = NSColor(white: 0.10, alpha: 1.0)
    static let pillBg = NSColor(white: 0.14, alpha: 1.0)
    static let pillBorder = NSColor(white: 0.22, alpha: 1.0)
    static let spotifyGreen = NSColor(red: 0.11, green: 0.73, blue: 0.33, alpha: 1.0)
    static let airplayBlue = NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
    static let textPrimary = NSColor.white
    static let textSecondary = NSColor(white: 0.72, alpha: 1.0)
    static let textMuted = NSColor(white: 0.45, alpha: 1.0)
    static let dividerColor = NSColor(white: 0.20, alpha: 1.0)
}

// MARK: - MediaRemote (private framework for universal Now Playing)
enum MRCommand: Int32 { case play=0, pause=1, togglePlayPause=2, stop=3, nextTrack=4, previousTrack=5 }
private var mrHandle: UnsafeMutableRawPointer?
private var mrGetNowPlaying: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void)?
private var mrSendCommand: (@convention(c) (Int32, CFDictionary?) -> Bool)?
private var mrRegisterNotifs: (@convention(c) (DispatchQueue) -> Void)?
private var mrSetElapsedTime: (@convention(c) (Double) -> Void)?

func loadMediaRemote() {
    mrHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    guard let h = mrHandle else { return }
    if let s = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") {
        mrGetNowPlaying = unsafeBitCast(s, to: ((@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void)).self)
    }
    if let s = dlsym(h, "MRMediaRemoteSendCommand") {
        mrSendCommand = unsafeBitCast(s, to: ((@convention(c) (Int32, CFDictionary?) -> Bool)).self)
    }
    if let s = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications") {
        mrRegisterNotifs = unsafeBitCast(s, to: ((@convention(c) (DispatchQueue) -> Void)).self)
    }
    // Used for seeking when the Perl bridge isn't in play. Optional — if the
    // symbol is missing on this macOS version, seeking just falls back to a no-op
    // rather than taking the rest of Now Playing down with it.
    if let s = dlsym(h, "MRMediaRemoteSetElapsedTime") {
        mrSetElapsedTime = unsafeBitCast(s, to: ((@convention(c) (Double) -> Void)).self)
    }
}

// MARK: - Models
struct TrackInfo {
    var title = ""
    var artist = ""
    var album = ""
    var artworkData: Data? = nil
    var duration: Double = 0
    var position: Double = 0
    var isPlaying = false
    var isActive = false
}

// MARK: - Live waveform view (Dynamic Island right pill)
class WaveformAnimView: NSView {
    private var barLayers: [CALayer] = []
    private var displayedLevels = Array(repeating: CGFloat(0), count: 4)
    var isActive = false { didSet { if !isActive { updateLevels([]) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let barCount = 4
        let barW: CGFloat = 2.5
        let gap: CGFloat = 2.0
        let totalW = CGFloat(barCount) * barW + CGFloat(barCount - 1) * gap
        let startX = (frame.width - totalW) / 2
        for i in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.systemGreen.cgColor
            bar.cornerRadius = barW / 2
            let x = startX + CGFloat(i) * (barW + gap)
            bar.frame = CGRect(x: x, y: frame.height / 2 - 2, width: barW, height: 4)
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateLevels(_ levels: [CGFloat]) {
        let incoming = isActive && levels.count == barLayers.count ? levels : Array(repeating: 0, count: barLayers.count)
        guard incoming.count == barLayers.count else { return }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.07)
        for (index, bar) in barLayers.enumerated() {
            // Fast attack and slower release keeps the meter readable without inventing movement.
            let level = min(max(incoming[index], 0), 1)
            displayedLevels[index] = level > displayedLevels[index]
                ? level
                : (displayedLevels[index] * 0.72 + level * 0.28)
            let h = max(CGFloat(4), displayedLevels[index] * bounds.height * 0.9)
            var f = bar.frame; f.size.height = h; f.origin.y = (bounds.height - h) / 2; bar.frame = f
        }
        CATransaction.commit()
    }
}

// MARK: - Alarm tone
// macOS system sounds are all single short beeps. Replaying one every second
// still reads as a notification, not an alarm. This synthesizes a real
// alarm-clock pattern — a burst of alternating beeps, then a short rest — as
// PCM, wraps it in a WAV container, and hands it to NSSound with looping on, so
// it rings continuously and seamlessly until stopped.
enum AlarmTone {
    private static let sampleRate = 44100.0

    static func makeSound() -> NSSound? {
        guard let wav = renderWAV() else { return nil }
        let sound = NSSound(data: wav)
        sound?.loops = true
        return sound
    }

    private static func renderWAV() -> Data? {
        // Four beeps alternating between two pitches, then a rest — the cadence a
        // physical alarm clock uses, which is what makes it read as urgent.
        let beep = 0.14, gap = 0.09, rest = 0.70
        let beepCount = 4
        let patternSeconds = (beep + gap) * Double(beepCount) + rest
        let frameCount = Int(patternSeconds * sampleRate)
        guard frameCount > 0 else { return nil }

        let lowPitch = 880.0, highPitch = 1174.7
        var samples = [Int16](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let t = Double(frame) / sampleRate
            let slot = Int(t / (beep + gap))
            guard slot < beepCount else { continue }
            let offset = t - Double(slot) * (beep + gap)
            guard offset < beep else { continue }
            // Ramp each beep in and out over 12ms so the edges don't click.
            let envelope = min(1.0, min(offset, beep - offset) / 0.012)
            let pitch = slot % 2 == 0 ? lowPitch : highPitch
            let value = sin(2.0 * .pi * pitch * t) * envelope * 0.75
            samples[frame] = Int16(max(-1.0, min(1.0, value)) * 32767)
        }

        let bytesPerSample = 2, channels = 1
        let dataBytes = frameCount * bytesPerSample * channels
        var wav = Data()
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }

        wav.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataBytes))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        append32(16)                                   // PCM header size
        append16(1)                                    // format = PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * UInt32(channels * bytesPerSample)) // byte rate
        append16(UInt16(channels * bytesPerSample))    // block align
        append16(16)                                   // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataBytes))
        samples.withUnsafeBufferPointer { wav.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
        return wav
    }
}

// MARK: - System audio meter
// A Core Audio process tap receives only outgoing audio. Unlike ScreenCaptureKit,
// it never creates a screen-capture session or a screen-sharing menu-bar item.
final class SystemAudioMeter: NSObject {
    private let sampleQueue = DispatchQueue(label: "com.marcelo.notchdrop.audio-meter", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var isRunning = false
    private(set) var isUnavailable = false
    private var isPermanentlyUnsupported = false
    private var isStarting = false
    private var lastStartAttempt = Date.distantPast
    var onLevels: (([CGFloat]) -> Void)?

    func start(for screen: NSScreen?) {
        guard !isRunning, !isStarting, !isPermanentlyUnsupported else { return }
        // A failed attempt used to latch `isUnavailable` forever, so the meter
        // never tried again for the rest of the session. That made a recoverable
        // condition — most often the system-audio permission not being granted
        // yet, or being invalidated when the binary is re-signed — look permanent:
        // granting the permission had no effect until the app was relaunched, with
        // nothing on screen explaining why. Backing off instead of latching lets it
        // pick itself up on its own within a minute.
        let retryInterval: TimeInterval = isUnavailable ? 60 : 3
        guard Date().timeIntervalSince(lastStartAttempt) >= retryInterval else { return }
        lastStartAttempt = Date()

        guard #available(macOS 14.2, *) else {
            // This one genuinely can't change while running, so it stays latched.
            isPermanentlyUnsupported = true
            isUnavailable = true
            return
        }
        isStarting = true
        sampleQueue.async { [weak self] in
            self?.createAudioTap()
        }
    }

    func stop() {
        sampleQueue.async { [weak self] in
            self?.tearDownAudioTap()
        }
        DispatchQueue.main.async { [weak self] in self?.onLevels?([]) }
    }

    // `start()` permanently latches `isUnavailable` after any failure (a transient
    // permission race, for instance) and never retries on its own. This gives the
    // user an explicit way to clear that latch from Settings instead of needing to
    // relaunch the app.
    func retryAfterFailure() {
        isUnavailable = false
        lastStartAttempt = .distantPast
    }

    @available(macOS 14.2, *)
    private func createAudioTap() {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "NotchDrop Live Audio Meter"
        description.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else {
            failStart("create process tap", status)
            return
        }
        tapID = newTapID

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString>.stride)
        var tapUID: CFString = "" as CFString
        status = withUnsafeMutablePointer(to: &tapUID) {
            AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, $0)
        }
        guard status == noErr else {
            failStart("read tap UID", status)
            return
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchDrop Audio Meter",
            kAudioAggregateDeviceUIDKey: "com.marcelo.notchdrop.audio-meter.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]]
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else {
            failStart("create aggregate device", status)
            return
        }
        aggregateDeviceID = newAggregateID

        var newIOProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, sampleQueue) { [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            self.consume(inputData)
        }
        guard status == noErr, let newIOProcID else {
            failStart("create audio IO callback", status)
            return
        }
        ioProcID = newIOProcID

        status = AudioDeviceStart(aggregateDeviceID, newIOProcID)
        guard status == noErr else {
            failStart("start audio tap", status)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.isStarting = false
            self?.isRunning = true
            self?.isUnavailable = false
        }
    }

    private func consume(_ audioBufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        var sums = [Float](repeating: 0, count: 4)
        var counts = [Int](repeating: 0, count: 4)

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            guard sampleCount > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<sampleCount {
                let sample = samples[index]
                guard sample.isFinite else { continue }
                let bar = min(index * 4 / sampleCount, 3)
                sums[bar] += sample * sample
                counts[bar] += 1
            }
        }

        var levels = [CGFloat](repeating: 0, count: 4)
        for bar in 0..<4 {
            let rms = counts[bar] > 0 ? sqrt(sums[bar] / Float(counts[bar])) : 0
            let db = 20 * log10(max(rms, 0.000_1))
            levels[bar] = CGFloat(min(max((db + 48) / 48, 0), 1))
        }
        DispatchQueue.main.async { [weak self] in self?.onLevels?(levels) }
    }

    private func failStart(_ operation: String, _ status: OSStatus) {
        NSLog("NotchDrop Core Audio %@ failed: %d", operation, status)
        tearDownAudioTap()
        DispatchQueue.main.async { [weak self] in
            self?.isStarting = false
            self?.isRunning = false
            self?.isUnavailable = true
            self?.onLevels?([])
        }
    }

    private func tearDownAudioTap() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isRunning = false
        isStarting = false
    }
}

// MARK: - System Output Volume
// Public Core Audio, same family of calls SystemAudioMeter above already uses —
// there is no AppKit-level API for this on macOS (unlike iOS's MPVolumeView).
enum SystemVolume {
    static func defaultOutputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func volumeAddress(channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: channel)
    }
    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    // Not every output device exposes a single "virtual master" volume — some
    // (many USB/Bluetooth devices) only expose per-channel volume, so this falls
    // back to averaging channels 1 and 2 when the master channel isn't available.
    static func currentVolume() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var size = UInt32(MemoryLayout<Float32>.size)
        var master = volumeAddress(channel: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &master) {
            var volume: Float32 = 0
            if AudioObjectGetPropertyData(device, &master, 0, nil, &size, &volume) == noErr { return volume }
        }
        var leftAddr = volumeAddress(channel: 1), rightAddr = volumeAddress(channel: 2)
        var left: Float32 = 0, right: Float32 = 0
        let leftOK = AudioObjectHasProperty(device, &leftAddr) && AudioObjectGetPropertyData(device, &leftAddr, 0, nil, &size, &left) == noErr
        let rightOK = AudioObjectHasProperty(device, &rightAddr) && AudioObjectGetPropertyData(device, &rightAddr, 0, nil, &size, &right) == noErr
        if leftOK && rightOK { return (left + right) / 2 }
        return leftOK ? left : (rightOK ? right : nil)
    }

    static func setVolume(_ value: Float) {
        guard let device = defaultOutputDevice() else { return }
        var v = max(0, min(1, value))
        let size = UInt32(MemoryLayout<Float32>.size)
        var master = volumeAddress(channel: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &master) {
            AudioObjectSetPropertyData(device, &master, 0, nil, size, &v)
            return
        }
        var leftAddr = volumeAddress(channel: 1), rightAddr = volumeAddress(channel: 2)
        if AudioObjectHasProperty(device, &leftAddr) { AudioObjectSetPropertyData(device, &leftAddr, 0, nil, size, &v) }
        if AudioObjectHasProperty(device, &rightAddr) { AudioObjectSetPropertyData(device, &rightAddr, 0, nil, size, &v) }
    }

    static func isMuted() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr && muted != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = defaultOutputDevice() else { return }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

// MARK: - Now Playing bridge for macOS 15.4+
// Newer macOS releases reject MediaRemote calls made directly by third-party
// apps. The bundled bridge runs those calls through the system Perl runtime and
// streams the native Control Center metadata (including artwork) as JSON.

/// Runs a subprocess with both pipes drained CONCURRENTLY and a hard deadline.
///
/// Reading one pipe to EOF before touching the other deadlocks the moment the
/// child fills the *other* pipe's 64KB buffer: the child blocks in `write()`,
/// we block in `read()`, and neither side can ever make progress. Every
/// subprocess in this file previously had that shape. The deadline covers the
/// other half — a beachballing Spotify or an `osascript` sitting on an
/// Automation permission prompt would otherwise block indefinitely.
@discardableResult
func runProcessBounded(_ process: Process, timeout: TimeInterval) -> (status: Int32, out: String, err: String) {
    let outPipe = Pipe(), errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do { try process.run() } catch {
        return (-1, "", error.localizedDescription)
    }

    var outData = Data(), errData = Data()
    let lock = NSLock()
    let group = DispatchGroup()
    for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            if isStdout { outData = data } else { errData = data }
            lock.unlock()
            group.leave()
        }
    }

    let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    process.waitUntilExit()
    killer.cancel()
    // Bounded: if a grandchild still holds the pipe open after the child exits,
    // don't hang here waiting for an EOF that may never arrive.
    _ = group.wait(timeout: .now() + 5)

    lock.lock(); defer { lock.unlock() }
    return (process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "")
}

final class MediaRemoteBridge {
    private var listener: Process?
    var isRunning: Bool { listener != nil }
    private var outputBuffer = Data()
    private let bufferQueue = DispatchQueue(label: "com.marcelo.notchdrop.media-bridge")
    var onPayload: ((String, [String: Any]) -> Void)?
    /// Fired when the adapter process dies, so Now Playing can fall back instead
    /// of freezing on whatever it last received.
    var onTerminated: (() -> Void)?

    private var scriptURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter/run.pl")
    }
    private var libraryURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter/libMediaRemoteAdapter.dylib")
    }

    // The bridge's perl listener is a child of the app, but nothing stopped it
    // when the app quit or was killed, so every quit, relaunch and update left
    // another copy running (found: six orphans, one 9+ hours old, all still
    // polling MediaRemote). Orphans are perl processes running this adapter in
    // "loop" mode whose parent is launchd (pid 1).
    static func orphanPIDs(inPSOutput output: String) -> [Int32] {
        output.split(separator: "\n").compactMap { line -> Int32? in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]), ppid == 1 else { return nil }
            let command = String(parts[2])
            guard command.contains("/MediaRemoteAdapter/"), command.hasSuffix(" loop") else { return nil }
            return pid
        }
    }

    static func reapOrphans() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        for pid in orphanPIDs(inPSOutput: runProcessBounded(ps, timeout: 5).out) { kill(pid, SIGTERM) }
    }

    // stderr goes to /dev/null, never to a Pipe nobody reads: the perl adapter
    // and its dylib do write there (warnings, "Failed to serialize data"), and
    // once ~64KB piled up in an unread pipe perl blocked in write() — still
    // alive, so onTerminated never fired, with Now Playing frozen on an old track.
    static func silenceDiagnostics(_ process: Process) {
        process.standardError = FileHandle.nullDevice
    }

    @discardableResult
    func start() -> Bool {
        guard listener == nil, let scriptURL, let libraryURL,
              FileManager.default.fileExists(atPath: scriptURL.path),
              FileManager.default.fileExists(atPath: libraryURL.path) else { return false }

        Self.reapOrphans()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, libraryURL.path, "loop"]
        let output = Pipe()
        process.standardOutput = output
        Self.silenceDiagnostics(process)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.bufferQueue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            // Without clearing the handler the dispatch source keeps firing
            // readable-with-0-bytes forever once the write end closes, pegging a
            // core for the rest of the app's life.
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.listener = nil
                self?.onTerminated?()
            }
        }
        do {
            try process.run()
            listener = process
            return true
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return false
        }
    }

    func stop() {
        if let pipe = listener?.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        listener?.terminate()
        listener = nil
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        let newline = Data([0x0A])
        while let range = outputBuffer.range(of: newline) {
            let line = outputBuffer.subdata(in: outputBuffer.startIndex..<range.lowerBound)
            outputBuffer.removeSubrange(outputBuffer.startIndex..<range.upperBound)
            guard !line.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let name = json["notificationName"] as? String,
                  let payload = json["payload"] as? [String: Any] else { continue }
            DispatchQueue.main.async { [weak self] in self?.onPayload?(name, payload) }
        }
    }

    // `argument` is passed through as the adapter's next positional arg — used by
    // `set_time`, which is how seeking within the current track is performed.
    func send(_ command: String, argument: String? = nil) {
        guard let scriptURL, let libraryURL else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            var args = [scriptURL.path, libraryURL.path, command]
            if let argument { args.append(argument) }
            process.arguments = args
            // Bounded and drained: an unread pipe plus waitUntilExit leaked a
            // thread and a perl process per click whenever MediaRemote hung.
            runProcessBounded(process, timeout: 5)
        }
    }
}

// MARK: - Media Downloader
// Pulls the video or image behind a pasted link (TikTok, Instagram, X, YouTube,
// Reddit, and ~1800 other sites) into a folder, from where it lands in the Shelf.
//
// The heavy lifting is delegated to yt-dlp rather than reimplemented: every one of
// these sites uses a different, undocumented, frequently-changing internal API, and
// keeping up with that is precisely what yt-dlp exists for. It is deliberately NOT
// bundled — it's GPL-licensed, and a copy frozen inside this app would silently rot
// as sites change. We locate a user-installed copy instead, and say so plainly when
// it isn't there.
final class MediaDownloader {
    enum Outcome {
        case success(URL)
        case missingTool
        case failure(String)
    }

    // Straight into Downloads, alongside everything else that gets saved there —
    // a NotchDrop subfolder just meant one more place to go looking.
    static var destinationDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    // TikTok's webpage extractor is broken in yt-dlp 2026.08.19 (the current
    // release): the page no longer carries the __UNIVERSAL_DATA_FOR_REHYDRATION__
    // blob it parses, so every attempt dies with "Unable to extract universal data
    // for rehydration" — reproduced against a real link, with and without query
    // params, on a cleared cache, and with browser cookies. Passing app_info routes
    // the request through TikTok's mobile app API instead, which still works
    // (verified end to end). Scoped to TikTok; harmless once yt-dlp fixes the web path.
    private static func extractorArgs(for url: URL) -> [String] {
        guard let host = url.host?.lowercased(), host.contains("tiktok.com") else { return [] }
        return ["--extractor-args", "tiktok:app_info=7355728856979392262"]
    }

    static func locateTool() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/opt/local/bin/yt-dlp",
            NSHomeDirectory() + "/.local/bin/yt-dlp",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    // yt-dlp handles pages; a link that already points straight at an image file
    // isn't a page it knows how to extract, so those are fetched directly.
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff", "avif"
    ]

    static func isSupportedLink(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return false }
        return true
    }

    enum Format {
        case videoMP4
        case audioMP3

        // Left to its own devices yt-dlp picks the highest-quality streams, which on
        // YouTube are usually VP9 + Opus and get muxed into .mkv/.webm — technically
        // better, but awkward in Finder, QuickTime, and most editors. These selectors
        // prefer an MP4/M4A pair and fall back to remuxing whatever was available, so
        // the result is a .mp4 either way.
        var arguments: [String] {
            switch self {
            case .videoMP4:
                return ["-f", "bv*[ext=mp4]+ba[ext=m4a]/bv*+ba/b",
                        "--merge-output-format", "mp4"]
            case .audioMP3:
                return ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
            }
        }
    }

    // TikTok and Instagram gate automated requests behind an anti-bot challenge:
    // a first request often succeeds, then further ones get rejected with
    // "Unable to extract universal data for rehydration". Handing yt-dlp the
    // cookies from a browser you're already signed into is the accepted way
    // around it — off by default, since it means reading browser session data.
    static func download(_ raw: String,
                         format: Format = .videoMP4,
                         cookiesFromBrowser: String? = nil,
                         onRetry: ((Int, Int) -> Void)? = nil,
                         completion: @escaping (Outcome) -> Void) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSupportedLink(trimmed), let url = URL(string: trimmed) else {
            completion(.failure("Eso no parece un enlace válido."))
            return
        }
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            completion(.failure("No se pudo crear la carpeta de descargas."))
            return
        }
        if imageExtensions.contains(url.pathExtension.lowercased()) {
            downloadDirectFile(url, completion: completion)
        } else {
            downloadWithTool(url, format: format, cookiesFromBrowser: cookiesFromBrowser, onRetry: onRetry, completion: completion)
        }
    }

    private static func downloadDirectFile(_ url: URL, completion: @escaping (Outcome) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // Some CDNs reject requests without a browser-ish UA.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.downloadTask(with: request) { temp, response, error in
            if let error {
                completion(.failure(error.localizedDescription)); return
            }
            guard let temp else { completion(.failure("Descarga vacía.")); return }
            let name = response?.suggestedFilename ?? url.lastPathComponent
            let target = uniqueDestination(for: name)
            do {
                try FileManager.default.moveItem(at: temp, to: target)
                completion(.success(target))
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }.resume()
    }

    /// TikTok's anti-bot challenge is non-deterministic: measured over repeated
    /// identical runs, the same link succeeded roughly 1 attempt in 5 with the rest
    /// failing on "Unable to extract universal data for rehydration". There is no
    /// configuration that makes it deterministic, so the honest fix is to retry —
    /// a handful of attempts turns a ~20% per-attempt success rate into a high
    /// overall one. Only errors that look transient are retried; a private video or
    /// an unsupported site fails immediately.
    private static let transientRetryLimit = 6
    private static let transientRetryDelay: TimeInterval = 1.5

    private static func isTransient(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("universal data for rehydration")
            || lower.contains("captcha")
            || lower.contains("timed out")
            || lower.contains("temporarily")
    }

    private static func downloadWithTool(_ url: URL,
                                         format: Format,
                                         cookiesFromBrowser: String?,
                                         onRetry: ((Int, Int) -> Void)?,
                                         completion: @escaping (Outcome) -> Void) {
        guard let tool = locateTool() else { completion(.missingTool); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let cookieArgs = cookiesFromBrowser.map { ["--cookies-from-browser", $0] } ?? []
            let siteArgs = extractorArgs(for: url)
            let arguments = cookieArgs + siteArgs + [
                "--no-playlist",          // a link inside a playlist means that one video, not all of them
                "--no-warnings",
                "--restrict-filenames",   // keeps names shell/Finder-friendly
                "--no-simulate",          // --print implies --simulate otherwise, and nothing downloads
                "--print", "after_move:filepath",
                "-o", destinationDirectory.appendingPathComponent("%(title).60s [%(id)s].%(ext)s").path,
            ] + format.arguments + [
                url.absoluteString,
            ]

            var lastError = "Falló la descarga."
            for attempt in 1...transientRetryLimit {
                let process = Process()
                process.executableURL = tool
                process.arguments = arguments
                // yt-dlp shells out to ffmpeg to merge separate video/audio streams,
                // and a GUI app's PATH doesn't include Homebrew, so spell it out.
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                process.environment = env

                // 10 minutes: long enough for a big video on a slow link, bounded so a
                // wedged yt-dlp can't leave the downloader disabled for the session.
                let result = runProcessBounded(process, timeout: 600)
                let printed = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = result.err.trimmingCharacters(in: .whitespacesAndNewlines)

                if result.status == 0 {
                    // --print may emit several lines; the last non-empty one is the path.
                    let path = printed.split(separator: "\n").last.map(String.init) ?? ""
                    if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                        DispatchQueue.main.async { completion(.success(URL(fileURLWithPath: path))) }
                        return
                    }
                    DispatchQueue.main.async { completion(.failure("Descargado, pero no se encontró el archivo final.")) }
                    return
                }

                lastError = friendlyError(from: stderr)
                guard isTransient(stderr), attempt < transientRetryLimit else {
                    DispatchQueue.main.async { completion(.failure(lastError)) }
                    return
                }
                DispatchQueue.main.async { onRetry?(attempt + 1, transientRetryLimit) }
                Thread.sleep(forTimeInterval: transientRetryDelay)
            }
            DispatchQueue.main.async { completion(.failure(lastError)) }
        }
    }

    private static func friendlyError(from stderr: String) -> String {
        let lower = stderr.lowercased()
        // TikTok's anti-bot rejection. The raw message tells the user to file a
        // yt-dlp bug, which is the wrong advice here — it's rate limiting, and
        // the actual fix is on the cookies setting.
        if lower.contains("universal data for rehydration") || lower.contains("captcha") {
            return "TikTok bloqueó la petición. Activa las cookies del navegador en Ajustes y reintenta."
        }
        if lower.contains("private") || lower.contains("login") || lower.contains("cookies") {
            return "Contenido privado o que requiere iniciar sesión — prueba activar cookies en Ajustes."
        }
        if lower.contains("unsupported url") {
            return "Ese sitio no está soportado."
        }
        if lower.contains("unavailable") || lower.contains("404") {
            return "El contenido ya no está disponible."
        }
        let firstLine = stderr.split(separator: "\n").first.map(String.init) ?? "Falló la descarga."
        return String(firstLine.prefix(120))
    }

    private static func uniqueDestination(for filename: String) -> URL {
        let safe = filename.isEmpty ? "descarga" : filename
        var candidate = destinationDirectory.appendingPathComponent(safe)
        var counter = 2
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            candidate = destinationDirectory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}

final class ClipItem {
    enum Kind {
        case text(String)
        case image(data: Data, type: NSPasteboard.PasteboardType)
    }
    let kind: Kind
    let date: Date
    // What actually gets drawn in the panel. The full-size data is kept separately
    // so pasting gives back the original image, never this downscaled copy.
    let thumbnail: NSImage?

    init(text: String) {
        self.kind = .text(text); self.date = Date(); self.thumbnail = nil
    }
    init(imageData: Data, type: NSPasteboard.PasteboardType) {
        self.kind = .image(data: imageData, type: type)
        self.date = Date()
        self.thumbnail = ClipItem.makeThumbnail(from: imageData, maxEdge: 26)
    }

    var byteCount: Int {
        switch kind {
        case .text(let s): return s.utf8.count
        case .image(let d, _): return d.count
        }
    }
    var isImage: Bool { if case .image = kind { return true }; return false }

    func isDuplicate(of other: ClipItem) -> Bool {
        switch (kind, other.kind) {
        case (.text(let a), .text(let b)): return a == b
        case (.image(let a, _), .image(let b, _)): return a == b
        default: return false
        }
    }

    // PNG before TIFF: macOS often offers both, and pasteboard TIFF is
    // uncompressed — a single screenshot can be an order of magnitude larger.
    static func preferredImageType(on pb: NSPasteboard) -> NSPasteboard.PasteboardType? {
        let candidates: [NSPasteboard.PasteboardType] = [
            .png, NSPasteboard.PasteboardType("public.jpeg"), .tiff
        ]
        return candidates.first { pb.availableType(from: [$0]) != nil }
    }

    static func makeThumbnail(from data: Data, maxEdge: CGFloat) -> NSImage? {
        guard let source = NSImage(data: data), source.size.width > 0, source.size.height > 0 else { return nil }
        let scale = min(maxEdge / source.size.width, maxEdge / source.size.height, 1)
        let size = NSSize(width: max(1, source.size.width * scale), height: max(1, source.size.height * scale))
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: size))
        thumb.unlockFocus()
        return thumb
    }
}


// MARK: - File Converter
// Format conversion and compression for whatever gets dropped in. Images and PDFs
// go through native macOS frameworks (ImageIO / PDFKit) so they need no external
// tools at all; video and audio delegate to ffmpeg, which is the only realistic
// option and is already required by the downloader.
enum FileConverter {

    enum Kind {
        case video, audio, image, pdf, unsupported

        /// What a file of this kind can become. Deliberately excludes no-op
        /// conversions to the same format — the UI filters the source's own
        /// extension out of the list.
        var targets: [String] {
            switch self {
            case .video: return ["mp4", "mov", "m4v", "webm", "gif", "mp3", "m4a", "wav"]
            case .audio: return ["mp3", "m4a", "wav", "aiff", "flac"]
            // No WebP: verified against this machine — neither ImageIO nor the
            // installed ffmpeg ships a WebP *encoder* on macOS, so offering it
            // would just be a button that always fails. Reading .webp as INPUT
            // still works, so webp -> png/jpg is available.
            case .image: return ["png", "jpg", "heic", "tiff", "pdf"]
            case .pdf:   return ["png", "jpg"]
            case .unsupported: return []
            }
        }

        var canCompress: Bool { self != .unsupported && self != .pdf }
    }

    static func kind(of url: URL) -> Kind {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv", "mpg", "mpeg":
            return .video
        case "mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "ogg", "opus", "wma":
            return .audio
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "webp", "gif", "bmp":
            return .image
        case "pdf":
            return .pdf
        default:
            return .unsupported
        }
    }

    static func ffmpegPath() -> URL? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    enum Outcome {
        case success(URL)
        case missingFFmpeg
        case failure(String)
    }

    /// Never overwrite: land next to the source with a distinct name.
    private static func output(for source: URL, ext: String, suffix: String) -> URL {
        let dir = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(stem)\(suffix).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem)\(suffix)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // ── Public entry points ────────────────────────────────────────────────

    static func convert(_ url: URL, to ext: String, completion: @escaping (Outcome) -> Void) {
        let target = ext.lowercased()
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Outcome
            switch kind(of: url) {
            case .image where target == "pdf":  result = imageToPDF(url)
            case .image:                        result = convertImage(url, to: target, quality: 0.92)
            case .pdf:                          result = pdfToImages(url, ext: target)
            case .video, .audio:                result = runFFmpeg(url, to: target, quality: nil)
            case .unsupported:                  result = .failure("Ese tipo de archivo no está soportado.")
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// `targetPercent` is the share of the ORIGINAL SIZE to aim for: 50 means
    /// "about half the bytes".
    ///
    /// This used to drive ffmpeg with CRF, which targets a quality level rather
    /// than a size — so re-encoding an already-compressed file (any downloaded
    /// video) at a *higher* quality than it was stored with made it BIGGER.
    /// Measured: a 139 KB clip came back at 211 KB. Targeting a bitrate derived
    /// from the source's own size makes the result track what was asked for.
    static func compress(_ url: URL, targetPercent: Int, completion: @escaping (Outcome) -> Void) {
        let percent = max(10, min(95, targetPercent))
        DispatchQueue.global(qos: .userInitiated).async {
            let originalBytes = fileSize(of: url)
            var result: Outcome
            switch kind(of: url) {
            case .image:
                result = compressImage(url, targetPercent: percent, originalBytes: originalBytes)
            case .video, .audio:
                result = compressMedia(url, targetPercent: percent, originalBytes: originalBytes)
            case .pdf, .unsupported:
                result = .failure("Comprimir no aplica a este tipo de archivo.")
            }
            // Never hand back a "compressed" file that is larger than the input.
            if case .success(let out) = result, originalBytes > 0 {
                let newBytes = fileSize(of: out)
                if newBytes >= originalBytes {
                    try? FileManager.default.removeItem(at: out)
                    result = .failure("Ya está muy comprimido; no se puede reducir más sin dañar la calidad.")
                }
            }
            let final = result
            DispatchQueue.main.async { completion(final) }
        }
    }

    static func fileSize(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    private static func ffprobePath() -> URL? {
        let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/opt/local/bin/ffprobe"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    /// width, height and frame rate — needed to decide whether a requested bitrate
    /// is even achievable at the current resolution.
    private static func probeVideoGeometry(_ url: URL) -> (w: Int, h: Int, fps: Double)? {
        guard let ffprobe = ffprobePath() else { return nil }
        let p = Process()
        p.executableURL = ffprobe
        p.arguments = ["-v", "error", "-select_streams", "v:0",
                       "-show_entries", "stream=width,height,r_frame_rate",
                       "-of", "default=noprint_wrappers=1:nokey=1", url.path]
        let parts = runProcessBounded(p, timeout: 30).out
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        // r_frame_rate comes back as a fraction like "30000/1001".
        let fpsParts = parts[2].split(separator: "/").compactMap { Double($0) }
        let fps = (fpsParts.count == 2 && fpsParts[1] != 0) ? fpsParts[0] / fpsParts[1] : (fpsParts.first ?? 30)
        return (w, h, max(1, fps))
    }

    private static func probeDuration(_ url: URL) -> Double? {
        guard let ffprobe = ffprobePath() else { return nil }
        let p = Process()
        p.executableURL = ffprobe
        p.arguments = ["-v", "error", "-show_entries", "format=duration",
                       "-of", "default=noprint_wrappers=1:nokey=1", url.path]
        let r = runProcessBounded(p, timeout: 30)
        return Double(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Which container the compressed file goes in. It used to keep the source
    /// extension while ALWAYS encoding AAC/H.264, which ffmpeg rejects for mp3,
    /// flac, aiff, opus and webm (leaving a stray empty file) and, for wav,
    /// silently wraps as AAC inside a .wav that nothing on macOS can play.
    /// Formats that can't be made smaller by lowering a bitrate (lossless) or
    /// that H.264/AAC can't live in come out as .m4a / .mp4 instead.
    static func compressionOutputExtension(forSource ext: String, isVideo: Bool) -> String {
        let e = ext.lowercased()
        if isVideo { return ["mp4", "mov", "m4v", "mkv"].contains(e) ? e : "mp4" }
        return ["mp3", "m4a", "aac", "opus"].contains(e) ? e : "m4a"
    }

    static func audioCompressionCodecArgs(outputExtension ext: String, kbps: Int) -> [String] {
        switch ext {
        case "mp3":  return ["-c:a", "libmp3lame", "-b:a", "\(kbps)k"]
        case "opus": return ["-c:a", "libopus", "-b:a", "\(kbps)k"]
        default:     return ["-c:a", "aac", "-b:a", "\(kbps)k"]
        }
    }

    private static func compressMedia(_ url: URL, targetPercent: Int, originalBytes: Int64) -> Outcome {
        guard let ffmpeg = ffmpegPath() else { return .missingFFmpeg }
        guard originalBytes > 0, let duration = probeDuration(url), duration > 0.1 else {
            return .failure("No se pudo leer la duración del archivo.")
        }
        let isVideo = kind(of: url) == .video
        let targetBytes = Double(originalBytes) * Double(targetPercent) / 100.0
        // Leave headroom for container overhead so the result lands under target.
        let targetBitsPerSecond = (targetBytes * 8.0 / duration) * 0.95

        let outExt = compressionOutputExtension(forSource: url.pathExtension, isVideo: isVideo)
        let out = output(for: url, ext: outExt, suffix: "-comprimido")
        var args = ["-y", "-i", url.path]

        if isVideo {
            // Audio gets a modest fixed slice; the rest goes to video.
            let audioBps = min(128_000.0, max(48_000.0, targetBitsPerSecond * 0.15))
            let videoBps = max(80_000.0, targetBitsPerSecond - audioBps)
            args += ["-c:v", "libx264", "-preset", "medium",
                     "-b:v", "\(Int(videoBps))",
                     "-maxrate", "\(Int(videoBps * 1.45))",
                     "-bufsize", "\(Int(videoBps * 2.0))",
                     "-pix_fmt", "yuv420p",
                     "-c:a", "aac", "-b:a", "\(max(48, Int(audioBps / 1000)))k"]

            // Below roughly 0.07 bits per pixel per frame, H.264 stops being able to
            // hold the frame together and just smears. Past that point the only way
            // to actually reach the requested size is fewer pixels — which is what
            // any real "compress for social" preset does too. Without this, an
            // already-compressed clip ignored aggressive targets entirely: 75/50/30/15
            // all came back at ~72% of the original.
            if let geo = probeVideoGeometry(url) {
                let bitsNeeded = Double(geo.w * geo.h) * geo.fps * 0.07
                if videoBps < bitsNeeded {
                    let scale = max(0.3, min(1.0, (videoBps / bitsNeeded).squareRoot()))
                    if scale < 0.97 {
                        // -2 keeps the dimension even, which H.264 requires.
                        let targetW = max(160, Int((Double(geo.w) * scale / 2).rounded()) * 2)
                        args += ["-vf", "scale=\(targetW):-2"]
                    }
                }
            }
        } else {
            let audioBps = max(48_000.0, targetBitsPerSecond)
            args += audioCompressionCodecArgs(outputExtension: outExt, kbps: Int(audioBps / 1000))
        }
        args.append(out.path)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        let result = runProcessBounded(process, timeout: 1200)
        guard result.status == 0, FileManager.default.fileExists(atPath: out.path) else {
            // ffmpeg creates the output before it knows it can finish; a failure
            // or timeout leaves an empty/partial file that would otherwise sit
            // next to the source and push the next attempt to "-comprimido-2".
            try? FileManager.default.removeItem(at: out)
            let line = result.err.split(separator: "\n").last.map(String.init) ?? "ffmpeg falló."
            return .failure(String(line.prefix(120)))
        }
        return .success(out)
    }

    private static func compressImage(_ url: URL, targetPercent: Int, originalBytes: Int64) -> Outcome {
        // JPEG quality doesn't map linearly to file size, so step down until the
        // result actually lands near the requested share of the original.
        let targetBytes = Double(originalBytes) * Double(targetPercent) / 100.0
        var quality = CGFloat(targetPercent) / 100.0
        var lastOutcome: Outcome = .failure("No se pudo comprimir la imagen.")
        for _ in 0..<5 {
            let attempt = convertImage(url, to: "jpg", quality: quality, suffix: "-comprimido")
            guard case .success(let out) = attempt else { return attempt }
            if Double(fileSize(of: out)) <= targetBytes || quality <= 0.15 {
                return attempt
            }
            // Overshot: discard and try harder.
            try? FileManager.default.removeItem(at: out)
            lastOutcome = attempt
            quality = max(0.1, quality - 0.15)
        }
        return lastOutcome
    }

    // ── Images (ImageIO / AppKit — no external tools) ──────────────────────

    private static func convertImage(_ url: URL, to ext: String, quality: CGFloat, suffix: String = "") -> Outcome {
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return .failure("No se pudo leer la imagen.")
        }
        let out = output(for: url, ext: ext, suffix: suffix)

        // HEIC and WebP aren't NSBitmapImageRep file types; they go through ImageIO.
        if ext == "heic" {
            let uti = "public.heic"
            guard let cg = rep.cgImage,
                  let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil) else {
                return .failure("Este Mac no puede escribir \(ext.uppercased()).")
            }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return .failure("Falló al escribir \(ext.uppercased()).") }
            return .success(out)
        }

        let type: NSBitmapImageRep.FileType
        var props: [NSBitmapImageRep.PropertyKey: Any] = [:]
        switch ext {
        case "png":          type = .png
        case "jpg", "jpeg":  type = .jpeg; props[.compressionFactor] = quality
        case "tiff", "tif":  type = .tiff
        case "bmp":          type = .bmp
        case "gif":          type = .gif
        default:             return .failure("Formato de salida no soportado: \(ext)")
        }
        guard let data = rep.representation(using: type, properties: props) else {
            return .failure("No se pudo generar \(ext.uppercased()).")
        }
        do { try data.write(to: out); return .success(out) }
        catch { return .failure(error.localizedDescription) }
    }

    private static func imageToPDF(_ url: URL) -> Outcome {
        guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
            return .failure("No se pudo leer la imagen.")
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        let out = output(for: url, ext: "pdf", suffix: "")
        guard doc.write(to: out) else { return .failure("No se pudo escribir el PDF.") }
        return .success(out)
    }

    private static func pdfToImages(_ url: URL, ext: String) -> Outcome {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            return .failure("No se pudo leer el PDF.")
        }
        var firstWritten: URL?
        // Multi-page PDFs become one image per page, numbered.
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // 2× for a usable resolution rather than a screen-sized thumbnail.
            let size = NSSize(width: bounds.width * 2, height: bounds.height * 2)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.scaleBy(x: 2, y: 2)
                page.draw(with: .mediaBox, to: ctx)
            }
            image.unlockFocus()

            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
            let type: NSBitmapImageRep.FileType = (ext == "png") ? .png : .jpeg
            let props: [NSBitmapImageRep.PropertyKey: Any] = (ext == "png") ? [:] : [.compressionFactor: 0.92]
            guard let data = rep.representation(using: type, properties: props) else { continue }
            let suffix = doc.pageCount > 1 ? "-p\(index + 1)" : ""
            let out = output(for: url, ext: ext, suffix: suffix)
            do {
                try data.write(to: out)
                if firstWritten == nil { firstWritten = out }
            } catch { return .failure(error.localizedDescription) }
        }
        guard let first = firstWritten else { return .failure("No se pudo convertir ninguna página.") }
        return .success(first)
    }

    // ── Video / audio (ffmpeg) ─────────────────────────────────────────────

    private static func runFFmpeg(_ url: URL, to ext: String, quality: Int?) -> Outcome {
        guard let ffmpeg = ffmpegPath() else { return .missingFFmpeg }
        let suffix = quality != nil ? "-comprimido" : ""
        let out = output(for: url, ext: ext, suffix: suffix)

        var args = ["-y", "-i", url.path]
        let sourceKind = kind(of: url)

        switch ext {
        case "mp3":
            args += ["-vn", "-c:a", "libmp3lame", "-q:a", quality.map { String(mp3Quality(for: $0)) } ?? "2"]
        case "m4a", "aac":
            args += ["-vn", "-c:a", "aac", "-b:a", "\(audioBitrate(for: quality ?? 100))k"]
        case "wav":
            args += ["-vn", "-c:a", "pcm_s16le"]
        case "aiff":
            args += ["-vn", "-c:a", "pcm_s16be"]
        case "flac":
            args += ["-vn", "-c:a", "flac"]
        case "gif":
            // Two-pass palette generation would be sharper, but this single pass is
            // fast and predictable, and caps size so a long clip can't explode.
            args += ["-vf", "fps=12,scale=480:-1:flags=lanczos", "-loop", "0"]
        case "webm":
            args += ["-c:v", "libvpx-vp9", "-crf", String(videoCRF(for: quality ?? 75)), "-b:v", "0", "-c:a", "libopus"]
        case "mp4", "mov", "m4v":
            if sourceKind == .audio { return .failure("Ese archivo es solo audio; elige un formato de audio.") }
            args += ["-c:v", "libx264", "-preset", "medium",
                     "-crf", String(videoCRF(for: quality ?? 75)),
                     "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k"]
        default:
            return .failure("Formato de salida no soportado: \(ext)")
        }
        args.append(out.path)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        // 20 minutes: a long 4K re-encode is genuinely slow, but it must not be
        // able to hang the converter forever.
        let result = runProcessBounded(process, timeout: 1200)
        guard result.status == 0, FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: out)
            let line = result.err.split(separator: "\n").last.map(String.init) ?? "ffmpeg falló."
            return .failure(String(line.prefix(120)))
        }
        return .success(out)
    }

    // Quality 100 → visually lossless; 10 → small and rough.
    private static func videoCRF(for quality: Int) -> Int {
        // CRF 18 is near-transparent for H.264, 34 is heavily compressed.
        let clamped = max(10, min(100, quality))
        return Int((Double(100 - clamped) / 90.0) * 16.0) + 18
    }
    private static func mp3Quality(for quality: Int) -> Int {
        // libmp3lame -q:a runs 0 (best) … 9 (worst).
        let clamped = max(10, min(100, quality))
        return Int((Double(100 - clamped) / 90.0) * 7.0)
    }
    private static func audioBitrate(for quality: Int) -> Int {
        let clamped = max(10, min(100, quality))
        return max(64, Int(Double(clamped) / 100.0 * 256.0))
    }
}

// MARK: - Draggable File View
class FileTrayItemView: NSView, NSDraggingSource {
    var fileURL: URL!
    var onRemove: (() -> Void)?
    var imageView: NSImageView!
    
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { return .copy }
    override func mouseDragged(with event: NSEvent) {
        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        draggingItem.setDraggingFrame(imageView.bounds, contents: imageView.image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    
    init(url: URL) {
        self.fileURL = url
        super.init(frame: NSRect(x: 0, y: 0, width: 70, height: 74))
        
        imageView = NSImageView()
        imageView.image = NSWorkspace.shared.icon(forFile: url.path)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        
        let lbl = NSTextField(labelWithString: url.lastPathComponent)
        lbl.font = .systemFont(ofSize: 10); lbl.textColor = .white; lbl.alignment = .center; lbl.lineBreakMode = .byTruncatingMiddle; lbl.isEditable = false; lbl.isSelectable = false; lbl.drawsBackground = false; lbl.isBordered = false
        lbl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lbl)
        
        let closeBtn = NSButton(title: "􀆄", target: self, action: #selector(removeClicked))
        closeBtn.bezelStyle = .inline; closeBtn.isBordered = false
        closeBtn.contentTintColor = NSColor(white: 1.0, alpha: 0.6); closeBtn.font = .systemFont(ofSize: 12, weight: .bold)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeBtn)
        
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8), imageView.centerXAnchor.constraint(equalTo: centerXAnchor), imageView.widthAnchor.constraint(equalToConstant: 40), imageView.heightAnchor.constraint(equalToConstant: 40),
            lbl.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4), lbl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), lbl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            closeBtn.topAnchor.constraint(equalTo: topAnchor, constant: 2), closeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2), closeBtn.widthAnchor.constraint(equalToConstant: 16), closeBtn.heightAnchor.constraint(equalToConstant: 16)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    
    @objc func removeClicked() { onRemove?() }
}

private let acceptedFileDragTypes: [NSPasteboard.PasteboardType] = [
    .fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")
]

private func fileURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
    let pasteboard = draggingInfo.draggingPasteboard
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) as? [URL],
       !urls.isEmpty {
        return urls
    }
    if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
        return paths.map(URL.init(fileURLWithPath:))
    }
    return []
}

// MARK: - Custom Background View
class PanelBackgroundView: NSView {
    var onMouseExit: (() -> Void)?
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(acceptedFileDragTypes)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
    override func mouseExited(with event: NSEvent) {
        if let w = window, !w.frame.insetBy(dx: -5, dy: -5).contains(NSEvent.mouseLocation) { onMouseExit?() }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onDragEnter?(); return .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { onDragEnter?(); return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        if !urls.isEmpty {
            onFilesDropped?(urls)
            onDragExit?()
            return true
        }
        return false
    }
}

// MARK: - Custom Panel
class NotchPanel: NSPanel {
    var onFileDragEntered: (() -> Void)?
    var onFileDragExited: (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?

    override var canBecomeKey: Bool { true }

    // NotchDrop runs as an LSUIElement agent, so it has no menu bar — and AppKit
    // delivers ⌘V/⌘C/⌘X/⌘A/⌘Z by matching them against the main menu's key
    // equivalents. With no Edit menu to match against, those shortcuts did nothing
    // inside this panel and text fields could only be pasted into via right-click.
    // Dispatching them down the responder chain ourselves restores the normal
    // behaviour without having to install a phantom menu bar.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.subtracting(.shift) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        var selector: Selector?
        switch key {
        case "x": selector = #selector(NSText.cut(_:))
        case "c": selector = #selector(NSText.copy(_:))
        case "v": selector = #selector(NSText.paste(_:))
        case "a": selector = #selector(NSResponder.selectAll(_:))
        case "z": selector = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        default: break
        }
        if let selector, NSApp.sendAction(selector, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        registerForDraggedTypes(acceptedFileDragTypes)
    }

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        onFileDragEntered?()
        return .copy
    }
    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        onFileDragEntered?()
        return .copy
    }
    @objc func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(from: sender).isEmpty
    }
    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        onFileDragExited?()
        return true
    }
    @objc func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDragExited?()
    }
}

// MARK: - Drag & Drop Tray View
class FileTrayView: NSView {
    var files: [URL] = []
    var updateCallback: (() -> Void)?
    var dragEndedCallback: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(acceptedFileDragTypes)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 2
        layer?.borderColor = C.pillBorder.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        layer?.borderColor = C.spotifyGreen.cgColor
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.borderColor = C.pillBorder.cgColor
        dragEndedCallback?()
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderColor = C.pillBorder.cgColor
        let urls = fileURLs(from: sender)
        if !urls.isEmpty {
            for url in urls {
                if !files.contains(url) { files.append(url) }
            }
            updateCallback?()
            dragEndedCallback?()
            return true
        }
        return false
    }
}

class IslandBackgroundView: NSView {
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(acceptedFileDragTypes)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        if !urls.isEmpty {
            onFilesDropped?(urls)
            onDragExit?()
            return true
        }
        return false
    }
}

// MARK: - Onboarding Overlay
// A lightweight, native spotlight tour (in the spirit of driver.js): darkens the
// expanded panel except for a rounded cutout around whichever control is being
// introduced, with a small callout box carrying the copy and Next/Skip controls.
class OnboardingOverlayView: NSView {
    var holeRect: NSRect = .zero { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(roundedRect: holeRect, xRadius: 10, yRadius: 10))
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.6).setFill()
        path.fill()
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - AppDelegate
// ═══════════════════════════════════════════════════════════════════════════
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSTextFieldDelegate {

    // ── Window & Dimensions ──
    var panel: NotchPanel!
    var isExpanded = false
    var isTransitioning = false
    var isReceivingFileDrag = false
    var targetScreen: NSScreen?
    var islandArtWindow: NSPanel?
    var islandArtView: NSImageView!
    var islandWaveWindow: NSPanel?
    var islandWaveView: WaveformAnimView!
    var islandAlarmLabel: NSTextField!

    var notchWidth: CGFloat = 190
    var menuBarHeight: CGFloat = 34
    var collapsedWidth: CGFloat = 190
    // The notch's height in POINTS is not a constant across Macs: it varies by
    // model and, on the same machine, by the Display Settings scaling the user
    // picked. Hardcoding 32 happened to match the machine this was built on and
    // would have been subtly wrong elsewhere — the collapsed strip either
    // overhanging into content or leaving a sliver of notch uncovered.
    // safeAreaInsets.top is the OS reporting the real value.
    var collapsedHeight: CGFloat { notchHeight(for: targetScreen) }

    func notchHeight(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return 32 }
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
            return screen.safeAreaInsets.top
        }
        // No physical notch: fall back to the menu bar height so the synthetic
        // notch matches the bar it sits in, clamped to something sane.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return menuBar > 0 ? min(max(menuBar, 24), 40) : 32
    }
    var expandedWidth: CGFloat = 520 // Widened to fix overlapping in Nook tab
    var expandedHeight: CGFloat = 260

    // User-facing size preference (Settings → General → "Tamaño del panel").
    // Notch *position* is always auto-detected correctly per device via
    // hasPhysicalNotch/auxiliaryTopLeftArea — there's no reliable way to improve
    // on that with a hardcoded per-model table (see hasPhysicalNotch's comment).
    // What genuinely varies by taste/screen is how big the expanded panel feels,
    // so that's what's actually adjustable.
    let panelScaleDefaultsKey = "NotchDropPanelScale"
    var panelScale: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: panelScaleDefaultsKey)
            return v == 0 ? 1.0 : CGFloat(v)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: panelScaleDefaultsKey) }
    }

    // Fixed content box the expanded panel's children are sized to. Derived from
    // the panel's final size minus its padding — 16pt each side horizontally, and
    // vertically the 92pt above the containers (top inset + tab bar + gap) plus
    // the 12pt below, measured in expandedBox's coordinate space.
    var contentWidth: CGFloat { expandedWidth * panelScale - 32 }
    var contentHeight: CGFloat { expandedHeight * panelScale - 80 }
    var contentWidthConstraints: [NSLayoutConstraint] = []
    var contentHeightConstraints: [NSLayoutConstraint] = []

    func updateContentSizeConstraints() {
        contentWidthConstraints.forEach { $0.constant = contentWidth }
        contentHeightConstraints.forEach { $0.constant = contentHeight }
    }

    // ── State ──
    var track = TrackInfo()
    var lastArtworkHash = 0
    // Cached last-rendered SF Symbol names, so the 1s poll tick doesn't rebuild
    // identical NSImages forever (see updateVolumeIcon / updateUI).
    var lastVolumeSymbol = ""
    var lastPlayBtnSymbol = ""
    var wasShowingMusic = false
    var cachedArtImage: NSImage?
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var mirrorActive = false
    var alarmEnd: Date?; var alarmTimer: Timer?; var alarmMins = 0
    var alarmRingTimer: Timer?
    var alarmSound: NSSound?
    var lastAlarmPillState = false
    let alarmNotificationID = "com.marcelo.notchdrop.alarm"
    let alarmDateDefaultsKey = "NotchDropAlarmEnd"
    let alarmMinutesDefaultsKey = "NotchDropAlarmMinutes"
    var swClock = StopwatchClock(); var swTimer: Timer?
    var clipboard: [ClipItem] = []
    var clipboardExpanded = false
    static let clipVisibleCollapsed = 3
    var lastPBCount = 0
    var globalClickMon: Any?
    var hotKeyRef: EventHotKeyRef?
    var globalHoverMon: Any?
    var localHoverMon: Any?
    var globalDragMon: Any?
    var globalMouseUpMon: Any?
    var audioMeter = SystemAudioMeter()
    let mediaBridge = MediaRemoteBridge()
    var usesMediaBridge = false
    var usingSpotifyFallback = false
    var isSpotifyPolling = false
    var fallbackPollTick = 0
    var spotifyArtworkURL = ""
    var spotifyArtworkData: Data?
    var usingNetflixFallback = false
    var isNetflixPolling = false
    var systemAudioIsAudible = false
    var lastAudibleAudioAt = Date.distantPast

    // ── UI Elements ──
    var mainView: NSView!
    var collapsedBox: NSView!
    var expandedBox: NSView!

    // Top Tabs
    var nooksTabBtn: NSButton!
    var trayTabBtn: NSButton!
    var toolsTabBtn: NSButton!
    var notesTabBtn: NSButton!
    var settingsBtn: NSButton!
    var convertTabBtn: NSButton!
    var currencyTabBtn: NSButton!
    var tabsStack: NSStackView!
    var allTabButtons: [NSButton] = []
    var selectedTabButton: NSButton?

    // Containers
    var nookContainer: NSView!
    var trayContainer: NSView!
    var toolsContainer: NSView!
    var notesContainer: NSView!
    var settingsContainer: NSView!
    var convertContainer: NSView!
    var currencyContainer: NSView!

    // Currency tab
    var currencyAmountField: NSTextField!
    var currencyFromPopup: NSPopUpButton!
    var currencyToPopup: NSPopUpButton!
    var currencyResultLabel: NSTextField!
    var currencyStatusLabel: NSTextField!
    var currencyTaxCheckbox: NSButton!
    var currencyTaxField: NSTextField!
    var currencyTaxPercentSign: NSTextField!
    static let currencyDefaultTaxPercent = "16"
    var currencyRatesCache: [String: (rate: Double, date: String)] = [:]
    var currencyPairsInFlight: Set<String> = []
    static let currencyDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")   // matches Frankfurter's "date" field
        return f
    }()
    static let currencyCodes = [
        "USD", "EUR", "GBP", "CHF", "JPY", "CNY", "CAD", "AUD", "MXN", "BRL",
        "INR", "KRW", "SEK", "NOK", "DKK", "PLN", "CZK", "HUF", "RON", "TRY",
        "ZAR", "SGD", "HKD", "NZD", "ILS", "PHP", "THB", "IDR", "MYR", "ISK",
    ]

    // Converter tab
    var convChooseBtn: NSButton!
    var convFileLabel: NSTextField!
    var convModeControl: NSSegmentedControl!
    var convOptionsPopup: NSPopUpButton!
    var convOptionLabel: NSTextField!
    var convRunBtn: NSButton!
    var convStatusLabel: NSTextField!
    var convRevealBtn: NSButton!
    var convSelectedFile: URL?
    var convResultFile: URL?
    var isConverting = false

    // Settings UI
    var launchAtLoginSwitch: NSSwitch!
    var hoverToOpenSwitchCtl: NSSwitch!
    var persistClipboardSwitch: NSSwitch!
    var audioStatusLabel: NSTextField!
    var panelSizeControl: NSSegmentedControl!
    var notchDiagnosticLabel: NSTextField!
    var downloaderStatusLabel: NSTextField!
    var cookieBrowserPopup: NSPopUpButton!
    var signalSources: [DispatchSourceSignal] = []
    var bridgeFailures = 0
    var bridgeStartedAt = Date()
    var openedByKeyboard = false
    var pointerEnteredSinceKeyboardOpen = false
    var updateStatusLabel: NSTextField!
    var updateActionBtn: NSButton!
    var availableUpdate: UpdateRelease?
    var isInstallingUpdate = false
    var updateCheckTimer: Timer?
    let autoUpdateDefaultsKey = "NotchDropAutoCheckUpdates"
    let lastUpdateCheckDefaultsKey = "NotchDropLastUpdateCheck"
    let notifiedUpdateVersionDefaultsKey = "NotchDropNotifiedUpdateVersion"
    let updateNotificationID = "com.marcelo.notchdrop.update"
    // On by default; the key is only written once the user flips the switch.
    var autoUpdateEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoUpdateDefaultsKey) == nil ? true : UserDefaults.standard.bool(forKey: autoUpdateDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoUpdateDefaultsKey) }
    }
    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    let hoverToOpenDefaultsKey = "NotchDropHoverToOpenEnabled"
    // Defaults to true (existing behavior) when the key has never been written.
    var hoverToOpenEnabled: Bool {
        get { UserDefaults.standard.object(forKey: hoverToOpenDefaultsKey) == nil ? true : UserDefaults.standard.bool(forKey: hoverToOpenDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: hoverToOpenDefaultsKey) }
    }

    // Onboarding tour
    var onboardingOverlay: NSView?
    var onboardingSteps: [(target: () -> NSView?, title: String, text: String)] = []
    var onboardingIndex = 0
    let onboardingDefaultsKey = "NotchDropHasSeenOnboarding"

    // Nook UI
    var artImageView: NSImageView!
    var npTitleLabel: NSTextField!
    var npArtistLabel: NSTextField!
    var npPlayBtn: NSButton!
    var progressSlider: NSSlider!
    var progressTimeLabel: NSTextField!
    var progressRemainLabel: NSTextField!
    var volumeSlider: NSSlider!
    var volumeIconBtn: NSButton!
    var mirrorCircleView: NSView!
    var mirrorCamLayerContainer: NSView!
    var mirrorIconView: NSImageView!

    // Tray UI
    var fileTrayBox: FileTrayView!
    var trayFilesStack: NSStackView!
    var trayClearBtn: NSButton!
    var airDropBtn: NSButton!
    var downloadField: NSTextField!
    var downloadBtn: NSButton!
    var downloadFormatControl: NSSegmentedControl!
    var revealDownloadBtn: NSButton!
    var lastDownloadedFile: URL?
    var downloadStatusLabel: NSTextField!
    var isDownloading = false

    // Tools UI
    var tabToolsStack: NSStackView!
    var alarmStatusLabel: NSTextField!
    var alarmTimePicker: NSDatePicker!
    var alarmCancelBtn: NSButton!
    var swDisplayLabel: NSTextField!
    var swStartBtn: NSButton!
    var clipStackView: NSStackView!

    var pollTimer: Timer?

    // ── Helpers ──
    func lbl(_ text: String, _ size: CGFloat = 12, _ weight: NSFont.Weight = .regular, _ color: NSColor = C.textPrimary) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }
    func iconBtn(_ symbol: String, size: CGFloat = 14, color: NSColor = C.textPrimary, action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
        let b = NSButton(image: img.withSymbolConfiguration(cfg) ?? img, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = color
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
    // SF Symbol + text tab button — replaces the emoji-prefixed titles the top
    // tab bar used to use, which was the single biggest thing making the panel
    // read as "not a native Mac app" at a glance.
    func tabBtn(_ symbol: String, _ title: String, tag: Int, action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let b = NSButton(title: title, target: self, action: action)
        b.image = img?.withSymbolConfiguration(cfg)
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        b.isBordered = false
        b.tag = tag
        // Trimmed from 12: a 6th tab (Currency) pushed the bar close to the gear
        // icon at the smallest panel-size setting (0.85x scale).
        b.font = .systemFont(ofSize: 11, weight: .medium)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
    // Keeps every tab's name visible and only gives up on that as a last resort.
    // Steps, cheapest first: tighter spacing between tabs (10 → 8 → 6 → 4pt),
    // then icon-only for the unselected tabs, then icon-only everywhere.
    // Measured at runtime so it adapts to the text metrics this Mac renders with.
    // (An earlier version skipped straight to icon-only and hid the names on the
    // Mac where they had always fit.)
    func fitTabBar() {
        guard let tabsStack, let settingsBtn else { return }
        // Same right edge as the trailing constraint to the gear (8pt gap).
        let available = contentWidth - settingsBtn.fittingSize.width - 8
        for b in allTabButtons { b.toolTip = b.title }
        func fits() -> Bool { tabsStack.fittingSize.width <= available }
        allTabButtons.forEach { $0.imagePosition = .imageLeading }
        for spacing in [CGFloat(10), 8, 6, 4] {
            tabsStack.spacing = spacing
            if fits() { return }
        }
        tabsStack.spacing = 10
        for b in allTabButtons { b.imagePosition = (b === selectedTabButton) ? .imageLeading : .imageOnly }
        if fits() { return }
        allTabButtons.forEach { $0.imagePosition = .imageOnly }
    }

    func makeCardView() -> NSView {
        let v = NSView(); v.wantsLayer = true
        v.layer?.backgroundColor = C.cardBg.cgColor
        v.layer?.cornerRadius = 14
        v.layer?.cornerCurve = .continuous
        v.layer?.borderColor = C.pillBorder.cgColor
        v.layer?.borderWidth = 1
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Launch
    // ═══════════════════════════════════════════════════════════════════

    func getPanelRect(expanded: Bool) -> NSRect {
        guard let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            let w = expanded ? expandedWidth : collapsedWidth
            let h = expanded ? expandedHeight : menuBarHeight
            return NSRect(x: 0, y: 0, width: w, height: h)
        }
        let sf = screen.frame
        let vf = screen.visibleFrame
        menuBarHeight = max(sf.maxY - vf.maxY, 32)

        var notchCenterX = sf.midX
        if #available(macOS 12.0, *), let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, left.maxX < right.minX {
            notchWidth = right.minX - left.maxX
            notchCenterX = left.maxX + (notchWidth / 2)
        } else {
            // This screen isn't reporting a physical notch cutout (e.g. an external
            // display, or the built-in screen momentarily mid-reconfiguration).
            // Reset to the default instead of keeping whatever value was last
            // computed for a different screen — otherwise a stale/oversized width
            // can persist and the panel visibly balloons in the wrong place.
            notchWidth = 190
        }
        collapsedWidth = notchWidth

        // Clamp against the actual screen width — expandedWidth is a fixed
        // constant, and without this a hypothetical narrow display could get a
        // panel wider than the screen itself.
        let w = expanded ? min(expandedWidth * panelScale, sf.width - 24) : notchWidth
        let h = expanded ? expandedHeight * panelScale : collapsedHeight
        return NSRect(x: notchCenterX - (w / 2), y: sf.maxY - h, width: w, height: h)
    }

    // The notch-bearing screen, freshly resolved. Called at launch and again
    // whenever macOS reports a screen configuration change (sleep/wake, an
    // external display connecting/disconnecting, resolution change). Without
    // re-resolving this, `targetScreen` keeps pointing at a screen object that
    // AppKit may have already replaced, and every geometry calculation derived
    // from it (notch width, panel position, island pill position) goes stale.
    func pickTargetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { screen in
            if #available(macOS 12.0, *), let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                return left.maxX < right.minX
            }
            return false
        }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    // Whether targetScreen is reporting an actual hardware notch cutout. This is
    // the ONLY reliable way to know the notch's real position and width — it's
    // read fresh from AppKit every time, so it's automatically correct for every
    // notched Mac model AND every Display Settings scaling option on that model
    // (the notch's width in *points* changes with scaling even on the same
    // physical machine, since the cutout is a fixed physical size in millimeters
    // but points-per-pixel changes — a hardcoded "pick your MacBook model" table
    // would need to also account for the user's current scaling to be correct,
    // which is exactly what this API already does for free).
    var hasPhysicalNotch: Bool {
        guard let screen = targetScreen else { return false }
        guard #available(macOS 12.0, *), let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return false }
        return left.maxX < right.minX
    }

    @objc func handleScreenParametersChanged() {
        targetScreen = pickTargetScreen()
        if isExpanded { collapsePanel() }
        if panel != nil, !isTransitioning {
            panel.setFrame(getPanelRect(expanded: false), display: true)
        }
        repositionIslandWindows()
        applyCollapsedBoxAppearance()
    }

    // Runs on any normal quit, including NSApp.terminate from the updater's relaunch.
    func applicationWillTerminate(_ notification: Notification) {
        mediaBridge.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduleUpdateChecks()
        // pkill / kill send SIGTERM, whose default action ends the process without
        // running applicationWillTerminate. Routing it through terminate() lets
        // the bridge (and anything else that cleans up on quit) actually stop.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
        targetScreen = pickTargetScreen()
        NotificationCenter.default.addObserver(self, selector: #selector(handleScreenParametersChanged),
                                                name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let r = getPanelRect(expanded: false)
        panel = NotchPanel(
            contentRect: r,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        // No shadow: the window is transparent with black content, so macOS drew
        // the shadow around the rounded edges — over a light background that reads
        // as a gray rim hugging the panel instead of a clean black shape. The two
        // island pill windows already opt out for the same reason.
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false; panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onFileDragEntered = { [weak self] in self?.prepareShelfForDrop() }
        panel.onFileDragExited = { [weak self] in self?.isReceivingFileDrag = false }
        panel.onFilesDropped = { [weak self] urls in self?.acceptDroppedFiles(urls) }

        mainView = PanelBackgroundView()
        panel.contentView = mainView
        (mainView as? PanelBackgroundView)?.onMouseExit = { [weak self] in
            // Auto-collapse on mouse-out: passive, so no haptic. (Went through
            // toggleExpandedState before, which made the trackpad click itself
            // every time the cursor drifted off the panel.)
            if self?.isExpanded == true && self?.isReceivingFileDrag == false { self?.collapsePanel() }
        }
        (mainView as? PanelBackgroundView)?.onDragEnter = { [weak self] in
            self?.prepareShelfForDrop()
        }
        (mainView as? PanelBackgroundView)?.onDragExit = { [weak self] in
            self?.isReceivingFileDrag = false
        }
        (mainView as? PanelBackgroundView)?.onFilesDropped = { [weak self] urls in
            self?.acceptDroppedFiles(urls)
        }

        mainView.wantsLayer = true
        mainView.layer?.backgroundColor = NSColor.clear.cgColor

        buildCollapsedView()
        buildExpandedView()
        expandedBox.isHidden = true
        panel.makeKeyAndOrderFront(nil)

        audioMeter.onLevels = { [weak self] levels in
            guard let self else { return }
            let now = Date()
            if (levels.max() ?? 0) > 0.06 { self.lastAudibleAudioAt = now }
            let audible = now.timeIntervalSince(self.lastAudibleAudioAt) < 1.2
            self.islandWaveView?.isActive = audible
            self.islandWaveView?.updateLevels(levels)
            if audible != self.systemAudioIsAudible {
                self.systemAudioIsAudible = audible
                self.updateUI()
                self.pollNetflixFallback()
            }
        }
        audioMeter.start(for: targetScreen)
        configureNativeNotifications()

        // Precise hover detection using global/local monitors instead of tracking areas.
        // This completely prevents accidental triggers when interacting with browser tabs.
        let hoverHandler: (NSEvent) -> Void = { [weak self] _ in
            guard let self = self else { return }
            let loc = NSEvent.mouseLocation

            if !self.isExpanded {
                guard self.hoverToOpenEnabled else { return }
                // Require the cursor to actually be on the notch-bearing screen.
                // `NSEvent.mouseLocation` is in one shared coordinate space across
                // every display, so without this check a second monitor positioned
                // above (or overlapping the notch's x-range) lets the open-ended
                // vertical check below fire from anywhere on that other screen.
                guard let screen = self.targetScreen, screen.frame.contains(loc) else { return }
                let rect = self.getPanelRect(expanded: false)
                let physicalNotchMinX = rect.midX - (self.notchWidth / 2)
                let physicalNotchMaxX = rect.midX + (self.notchWidth / 2)
                // Trigger ONLY if the mouse is horizontally within the physical notch
                // AND vertically within its collapsed height (+2px buffer on both
                // edges). The old check only bounded the lower edge, so on a
                // multi-monitor setup the trigger zone effectively extended upward
                // forever — any mouse movement on a display above the notch, inside
                // that narrow x-strip, would spuriously pop the panel open.
                if loc.x >= physicalNotchMinX && loc.x <= physicalNotchMaxX &&
                    loc.y >= (rect.minY - 2) && loc.y <= (rect.maxY + 2) {
                    self.expandPanel()
                }
            } else {
                let expandedRect = self.getPanelRect(expanded: true)
                // Collapse if mouse moves far outside the expanded panel (give 10px buffer)
                let paddedRect = expandedRect.insetBy(dx: -10, dy: -10)
                let d = AutoCollapsePolicy.decide(pointer: loc, paddedRect: paddedRect,
                                                  keyboardOpened: self.openedByKeyboard,
                                                  hasEntered: self.pointerEnteredSinceKeyboardOpen)
                self.pointerEnteredSinceKeyboardOpen = d.hasEntered
                if d.collapse { self.collapsePanel() }
            }
        }
        
        globalHoverMon = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: hoverHandler)
        localHoverMon = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            hoverHandler(event)
            return event
        }

        lastPBCount = NSPasteboard.general.changeCount
        mediaBridge.onPayload = { [weak self] notificationName, payload in
            self?.handleMediaPayload(notificationName: notificationName, payload: payload)
        }
        // If the adapter process dies, stop taking the bridge branch in poll() —
        // it was latched true at launch and never re-evaluated, so a dead adapter
        // meant Now Playing froze on the last track it had seen, forever, with
        // nothing on screen explaining why.
        mediaBridge.onTerminated = { [weak self] in
            guard let self, self.usesMediaBridge else { return }
            // A bridge that ran for a while before dying isn't a crash loop.
            if Date().timeIntervalSince(self.bridgeStartedAt) > 120 { self.bridgeFailures = 0 }
            self.bridgeFailures += 1
            if let delay = BridgeRestartPolicy.delay(afterFailures: self.bridgeFailures) {
                NSLog("NotchDrop: media bridge exited — restarting in \(Int(delay))s (attempt \(self.bridgeFailures))")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.usesMediaBridge, !self.mediaBridge.isRunning else { return }
                    if self.mediaBridge.start() { self.bridgeStartedAt = Date() } else { self.fallBackToDirectMediaRemote() }
                }
                return
            }
            self.fallBackToDirectMediaRemote()
        }
        usesMediaBridge = mediaBridge.start()
        bridgeStartedAt = Date()
        if !usesMediaBridge {
            loadMediaRemote()
            mrRegisterNotifs?(DispatchQueue.main)
        }
        
        // Spring-load Shelf as soon as any external drag reaches the notch.
        // The window-level destination validates that the dropped payload is a file.
        globalMouseUpMon = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self, self.isReceivingFileDrag else { return }
            // Give the drop a moment to be delivered before deciding the drag is over.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.isReceivingFileDrag = false
            }
        }
        globalDragMon = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            guard let self = self, !self.isExpanded else { return }
            let loc = NSEvent.mouseLocation
            let rect = self.getPanelRect(expanded: false)
            let notchMinX = rect.midX - (self.notchWidth / 2) - 60
            let notchMaxX = rect.midX + (self.notchWidth / 2) + 60
            if loc.x >= notchMinX && loc.x <= notchMaxX && loc.y >= (rect.minY - 30) {
                guard self.dragCarriesFiles() else { return }
                DispatchQueue.main.async { self.prepareShelfForDrop() }
            }
        }
        
        registerGlobalHotkey()
        startPollingLoop()
    }

    // ⌥⌘N from anywhere opens/closes the notch. Uses Carbon's RegisterEventHotKey,
    // which is the one system-wide hotkey API that does NOT require the
    // "Input Monitoring" permission — an NSEvent global monitor would see every
    // keystroke you type in every app and needs that (fairly alarming) grant, for
    // what is only ever a single key combination.
    func registerGlobalHotkey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E44_5250), id: 1) // 'NDRP'
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var received = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &received)
            if received.id == 1 {
                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.toggleExpandedState()
                }
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let keyN: UInt32 = 45
        let modifiers = UInt32(optionKey | cmdKey)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyN, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("NotchDrop: global hotkey registration failed (%d) — ⌥⌘N may be taken by another app", status)
        }
    }

    func prepareShelfForDrop() {
        // Idempotent: the global drag monitor fires on every mouse-drag event
        // (60+/s), and this used to re-run the whole thing each time — including a
        // pasteboard IPC round trip — and slam the tab back to Shelf so you
        // couldn't switch away mid-drag.
        guard !isReceivingFileDrag else { return }
        isReceivingFileDrag = true
        if !isExpanded { expandPanel(forFileDrop: true) }
        if trayTabBtn != nil { switchTab(trayTabBtn) }
    }

    /// Only true while an actual file drag is in flight. The drag monitor sees
    /// every left-drag on the screen, including dragging a browser tab or a window
    /// by its title bar, and reacting to those popped the panel open for no reason.
    func dragCarriesFiles() -> Bool {
        guard let pb = NSPasteboard(name: .drag).types else { return false }
        return pb.contains(.fileURL)
            || pb.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    }

    func acceptDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isReceivingFileDrag = false
        if !isExpanded { expandPanel(forFileDrop: true) }
        for url in urls where !fileTrayBox.files.contains(url) {
            fileTrayBox.files.append(url)
        }
        updateTrayUI()
        switchTab(trayTabBtn)
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Collapsed UI
    // ═══════════════════════════════════════════════════════════════════

    // On a Mac with a real notch, the collapsed trigger stays fully transparent —
    // the physical camera housing is already black, nothing to draw. On a Mac
    // without one (MacBook Air without a notch, iMac, Mac mini/Studio + monitor),
    // the same zone would otherwise be an invisible floating hover target with
    // nothing for the eye to anchor to. This draws an actual notch-shaped element
    // instead — flush with the top edge, rounded only at the bottom, like the
    // real hardware — so the whole interaction model still makes visual sense.
    // Called at initial build and again after any screen change, since docking/
    // undocking a MacBook in clamshell mode can flip which case applies.
    func applyCollapsedBoxAppearance() {
        guard let trigger = collapsedBox else { return }
        if hasPhysicalNotch {
            trigger.layer?.backgroundColor = NSColor.clear.cgColor
            trigger.layer?.masksToBounds = false
        } else {
            trigger.layer?.backgroundColor = C.black.cgColor
            trigger.layer?.cornerRadius = 12
            trigger.layer?.cornerCurve = .continuous
            trigger.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            trigger.layer?.masksToBounds = true
        }
    }

    func buildCollapsedView() {
        let trigger = NSView(); trigger.wantsLayer = true
        trigger.layer?.backgroundColor = NSColor.clear.cgColor
        trigger.translatesAutoresizingMaskIntoConstraints = false
        mainView.addSubview(trigger)
        NSLayoutConstraint.activate([
            trigger.topAnchor.constraint(equalTo: mainView.topAnchor),
            trigger.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),
            trigger.leadingAnchor.constraint(equalTo: mainView.leadingAnchor),
            trigger.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),
        ])
        collapsedBox = trigger
        // Click always opens the notch, independent of the hover setting — so
        // turning off "open on hover" in Settings never leaves the app with no
        // way to open it.
        trigger.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(collapsedBoxClicked)))

        applyCollapsedBoxAppearance()
        if !hasPhysicalNotch {
            // A one-time reveal shortly after launch, so the synthetic notch reads
            // as arriving rather than just being there on first paint.
            trigger.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.5
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    trigger.animator().alphaValue = 1
                }
            }
        }

        // Create two tiny independent windows for Dynamic Island icons
        buildIslandWindows()
        updateUI() // Apply state immediately
    }
    
    let islandPillW: CGFloat = 34   // width of each black pill
    let islandAlarmPillW: CGFloat = 62  // wider, so the countdown clears the notch overlap
    let islandNotchOverlap: CGFloat = 10
    var alarmIsShowing: Bool { (alarmEnd != nil || alarmSound != nil) && !isExpanded }
    var islandPillH: CGFloat { notchHeight(for: targetScreen) }   // always matches the notch

    // Shared geometry for both island pill windows, factored out so it can be
    // recomputed against a fresh screen after a display change instead of only
    // ever reflecting whatever screen was active when the windows were first built.
    func islandGeometry(for screen: NSScreen) -> (art: NSRect, wave: NSRect) {
        let sf = screen.frame
        var nCenterX = sf.midX
        var nWidth: CGFloat = 190
        if #available(macOS 12.0, *), let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, left.maxX < right.minX {
            nWidth = right.minX - left.maxX
            nCenterX = left.maxX + (nWidth / 2)
        }
        let notchLeftEdge = nCenterX - (nWidth / 2)
        let notchRightEdge = nCenterX + (nWidth / 2)
        let notchTopY = sf.maxY
        let artRect = NSRect(x: notchLeftEdge - islandPillW + 10, y: notchTopY - islandPillH, width: islandPillW, height: islandPillH)
        // Both pills tuck 10pt under the notch so they appear joined to it. That
        // means the leftmost 10pt of the right pill is never visible — so when it
        // carries the alarm countdown it has to be wider, or the text starts
        // underneath the notch and gets cut in half.
        let waveWidth = alarmIsShowing ? islandAlarmPillW : islandPillW
        let waveRect = NSRect(x: notchRightEdge - 10, y: notchTopY - islandPillH, width: waveWidth, height: islandPillH)
        return (artRect, waveRect)
    }

    // Re-anchors the already-built island pill windows to the current
    // targetScreen. Call after any screen configuration change — otherwise the
    // pills stay glued to the old screen's notch coordinates while the main
    // panel moves, so they visibly drift apart.
    func repositionIslandWindows() {
        guard let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let geo = islandGeometry(for: screen)
        islandArtWindow?.setFrame(geo.art, display: true)
        islandWaveWindow?.setFrame(geo.wave, display: true)
        // The pills' contents use fixed frames, so a height change (different
        // display, different scaling) has to move them too.
        let pillH = geo.art.height
        let iconSz: CGFloat = min(20, pillH - 12)
        let artVisibleW = islandPillW - islandNotchOverlap
        islandArtView?.frame = NSRect(x: (artVisibleW - iconSz) / 2, y: (pillH - iconSz) / 2,
                                      width: iconSz, height: iconSz)
        islandWaveView?.frame = NSRect(x: (islandPillW - iconSz) / 2, y: (pillH - iconSz) / 2,
                                       width: iconSz, height: iconSz)
        islandAlarmLabel?.frame = NSRect(x: islandNotchOverlap, y: (pillH - 14) / 2,
                                         width: islandAlarmPillW - islandNotchOverlap, height: 14)
    }

    func buildIslandWindows() {
        guard let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let pillW = islandPillW
        let pillH = islandPillH
        let iconSz: CGFloat = 20  // icon inside the pill
        let cornerR: CGFloat = 12 // rounded corners like the notch
        let geo = islandGeometry(for: screen)

        // ── Left pill (album art) ── overlaps 14px into notch area to seamlessly connect
        let artRect = geo.art
        let artPanel = NotchPanel(contentRect: artRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        artPanel.level = .statusBar + 1
        artPanel.backgroundColor = .clear
        artPanel.isOpaque = false
        artPanel.hasShadow = false
        artPanel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        artPanel.ignoresMouseEvents = false
        
        let artBg = IslandBackgroundView(frame: NSRect(x: 0, y: 0, width: pillW, height: pillH))
        artBg.wantsLayer = true
        artBg.layer?.backgroundColor = NSColor.black.cgColor
        artBg.layer?.cornerRadius = cornerR
        artBg.layer?.cornerCurve = .continuous
        // ONE corner: bottom-outer only (MinY is the bottom edge in layer geometry).
        // The top edge stays square so the pill sits flush against the top of the
        // screen, and the INNER bottom corner — the one that meets the notch — stays
        // square too. Rounding that inner corner carved a visible gap between the
        // pill and the notch, which is what made these read as separate elements
        // dropping down from the menu bar rather than the notch widening.
        // Left pill: its outer edge is the LEFT one.
        artBg.layer?.maskedCorners = [.layerMinXMinYCorner]
        artBg.onDragEnter = { [weak self] in
            self?.prepareShelfForDrop()
        }
        artBg.onDragExit = { [weak self] in self?.isReceivingFileDrag = false }
        artBg.onFilesDropped = { [weak self] urls in
            self?.acceptDroppedFiles(urls)
        }
        artPanel.onFileDragEntered = { [weak self] in self?.prepareShelfForDrop() }
        artPanel.onFileDragExited = { [weak self] in self?.isReceivingFileDrag = false }
        artPanel.onFilesDropped = { [weak self] urls in self?.acceptDroppedFiles(urls) }
        
        // The left pill overlaps the notch on its RIGHT edge, so centering the
        // artwork across the whole pill pushed part of it underneath the notch.
        // Center it within the visible strip instead.
        let artVisibleW = pillW - islandNotchOverlap
        islandArtView = NSImageView(frame: NSRect(x: (artVisibleW - iconSz) / 2,
                                                 y: (pillH - iconSz) / 2,
                                                 width: iconSz, height: iconSz))
        islandArtView.imageScaling = .scaleProportionallyUpOrDown
        islandArtView.wantsLayer = true
        islandArtView.layer?.cornerRadius = 4
        islandArtView.layer?.cornerCurve = .continuous
        islandArtView.layer?.masksToBounds = true
        artBg.addSubview(islandArtView)
        artPanel.contentView = artBg
        islandArtWindow = artPanel
        
        // ── Right pill (waveform) ── flush against the right edge of notch
        // ── Right pill (waveform) ── overlaps 14px into notch area to seamlessly connect
        let waveRect = geo.wave
        let wavePanel = NotchPanel(contentRect: waveRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        wavePanel.level = .statusBar + 1
        wavePanel.backgroundColor = .clear
        wavePanel.isOpaque = false
        wavePanel.hasShadow = false
        wavePanel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        wavePanel.ignoresMouseEvents = false
        
        let waveBg = IslandBackgroundView(frame: NSRect(x: 0, y: 0, width: pillW, height: pillH))
        waveBg.wantsLayer = true
        waveBg.layer?.backgroundColor = NSColor.black.cgColor
        waveBg.layer?.cornerRadius = cornerR
        waveBg.layer?.cornerCurve = .continuous
        // Right pill: mirror image — its outer edge is the RIGHT one.
        waveBg.layer?.maskedCorners = [.layerMaxXMinYCorner]
        waveBg.onDragEnter = { [weak self] in
            self?.prepareShelfForDrop()
        }
        waveBg.onDragExit = { [weak self] in self?.isReceivingFileDrag = false }
        waveBg.onFilesDropped = { [weak self] urls in
            self?.acceptDroppedFiles(urls)
        }
        wavePanel.onFileDragEntered = { [weak self] in self?.prepareShelfForDrop() }
        wavePanel.onFileDragExited = { [weak self] in self?.isReceivingFileDrag = false }
        wavePanel.onFilesDropped = { [weak self] urls in self?.acceptDroppedFiles(urls) }
        
        islandWaveView = WaveformAnimView(frame: NSRect(x: (pillW - iconSz) / 2, y: (pillH - iconSz) / 2, width: iconSz, height: iconSz))
        waveBg.addSubview(islandWaveView)

        // Live Activity-style glance: while an alarm is counting down or ringing,
        // this swaps in for the waveform so the countdown is visible without
        // opening the panel — matching how the real Dynamic Island keeps a Live
        // Activity glanceable in the compact state.
        islandAlarmLabel = NSTextField(labelWithString: "")
        islandAlarmLabel.frame = NSRect(x: islandNotchOverlap, y: (pillH - 14) / 2,
                                        width: islandAlarmPillW - islandNotchOverlap, height: 14)
        islandAlarmLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        islandAlarmLabel.textColor = C.spotifyGreen
        islandAlarmLabel.alignment = .center
        islandAlarmLabel.isBordered = false
        islandAlarmLabel.drawsBackground = false
        islandAlarmLabel.isEditable = false
        islandAlarmLabel.isSelectable = false
        islandAlarmLabel.isHidden = true
        waveBg.addSubview(islandAlarmLabel)

        wavePanel.contentView = waveBg
        islandWaveWindow = wavePanel
    }

    // ═══════════════════════════════════════════════════════════════════

    // MARK: - Expanded UI Build
    // ═══════════════════════════════════════════════════════════════════

    func buildExpandedView() {
        expandedBox = NSView(); expandedBox.wantsLayer = true
        // Solid opaque black, matching the collapsed notch and the island pills —
        // the whole point of this UI is that it reads as the physical notch itself
        // extending, not as a separate floating glass panel. (Vibrancy/blur was
        // tried here and reverted: it broke that illusion and made the color shift
        // with whatever's behind the panel instead of staying pure black.)
        expandedBox.layer?.backgroundColor = C.black.cgColor
        expandedBox.layer?.cornerRadius = 24
        expandedBox.layer?.cornerCurve = .continuous
        expandedBox.layer?.masksToBounds = true
        expandedBox.translatesAutoresizingMaskIntoConstraints = false
        mainView.addSubview(expandedBox)
        NSLayoutConstraint.activate([
            expandedBox.topAnchor.constraint(equalTo: mainView.topAnchor, constant: -24),
            expandedBox.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),
            expandedBox.leadingAnchor.constraint(equalTo: mainView.leadingAnchor),
            expandedBox.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),
        ])

        let topBar = NSView(); topBar.translatesAutoresizingMaskIntoConstraints = false
        expandedBox.addSubview(topBar)
        // Same fixed-width, centered treatment as the containers below — the tab
        // bar must not slide inward/outward while the panel animates.
        let topBarWidth = topBar.widthAnchor.constraint(equalToConstant: contentWidth)
        contentWidthConstraints.append(topBarWidth)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: expandedBox.topAnchor, constant: 60), // 36 + 24
            topBar.centerXAnchor.constraint(equalTo: expandedBox.centerXAnchor),
            topBarWidth,
            topBar.heightAnchor.constraint(equalToConstant: 26),
        ])

        nooksTabBtn = tabBtn("music.note", "Player", tag: 0, action: #selector(switchTab(_:)))
        trayTabBtn = tabBtn("tray.full", "Shelf", tag: 1, action: #selector(switchTab(_:)))
        toolsTabBtn = tabBtn("bolt.fill", "Tools", tag: 2, action: #selector(switchTab(_:)))
        notesTabBtn = tabBtn("note.text", "Notes", tag: 3, action: #selector(switchTab(_:)))
        convertTabBtn = tabBtn("arrow.triangle.2.circlepath", "Convert", tag: 4, action: #selector(switchTab(_:)))
        currencyTabBtn = tabBtn("banknote", "Currency", tag: 5, action: #selector(switchTab(_:)))

        allTabButtons = [nooksTabBtn, trayTabBtn, toolsTabBtn, notesTabBtn, convertTabBtn, currencyTabBtn]
        tabsStack = NSStackView(views: allTabButtons)
        tabsStack.spacing = 10; tabsStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(tabsStack)

        settingsBtn = iconBtn("gearshape.fill", size: 13, color: C.textMuted, action: #selector(openSettings))
        topBar.addSubview(settingsBtn)
        NSLayoutConstraint.activate([
            tabsStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            tabsStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            // Without this the row had no right edge: with full labels it fit
            // this Mac at the small panel size by exactly 0pt, so any other Mac
            // rendering text a hair wider pushed Currency under the gear and
            // past the panel. fitTabBar() keeps it inside; this is the backstop.
            tabsStack.trailingAnchor.constraint(lessThanOrEqualTo: settingsBtn.leadingAnchor, constant: -8),
            settingsBtn.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            settingsBtn.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])

        nookContainer = NSView(); nookContainer.translatesAutoresizingMaskIntoConstraints = false
        trayContainer = NSView(); trayContainer.translatesAutoresizingMaskIntoConstraints = false
        toolsContainer = NSView(); toolsContainer.translatesAutoresizingMaskIntoConstraints = false
        notesContainer = NSView(); notesContainer.translatesAutoresizingMaskIntoConstraints = false
        settingsContainer = NSView(); settingsContainer.translatesAutoresizingMaskIntoConstraints = false
        convertContainer = NSView(); convertContainer.translatesAutoresizingMaskIntoConstraints = false
        currencyContainer = NSView(); currencyContainer.translatesAutoresizingMaskIntoConstraints = false
        trayContainer.isHidden = true; toolsContainer.isHidden = true; notesContainer.isHidden = true
        settingsContainer.isHidden = true; convertContainer.isHidden = true; currencyContainer.isHidden = true

        // Content is pinned to a FIXED size, centered — never to the panel's moving
        // edges. During the open/close animation the window is still narrow, so
        // Auto Layout would otherwise re-solve the whole layout every frame at a
        // compressed width; with edge-pinned columns that resolves asymmetrically
        // and the panel visually unfolds from one side. Holding the content at its
        // final size and letting expandedBox (which clips to its rounded bounds)
        // reveal it means the opening reads as center-outward, like the real
        // Dynamic Island.
        for v in [nookContainer!, trayContainer!, toolsContainer!, notesContainer!, settingsContainer!, convertContainer!, currencyContainer!] {
            expandedBox.addSubview(v)
            let widthC = v.widthAnchor.constraint(equalToConstant: contentWidth)
            let heightC = v.heightAnchor.constraint(equalToConstant: contentHeight)
            contentWidthConstraints.append(widthC)
            contentHeightConstraints.append(heightC)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
                v.centerXAnchor.constraint(equalTo: expandedBox.centerXAnchor),
                widthC,
                heightC,
            ])
        }

        switchTab(nooksTabBtn)
        buildNookTab()
        buildTrayTab()
        buildToolsTab()
        buildNotesTab()
        buildSettingsTab()
        buildConvertTab()
        buildCurrencyTab()
    }

    func buildNookTab() {
        let col1 = NSView(); col1.translatesAutoresizingMaskIntoConstraints = false
        nookContainer.addSubview(col1)

        let artBox = NSView(); artBox.wantsLayer = true; artBox.layer?.cornerRadius = 16; artBox.layer?.cornerCurve = .continuous; artBox.layer?.masksToBounds = true
        artBox.translatesAutoresizingMaskIntoConstraints = false
        col1.addSubview(artBox)
        artImageView = NSImageView(); artImageView.imageScaling = .scaleProportionallyUpOrDown
        artImageView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        artImageView.contentTintColor = C.textMuted; artImageView.translatesAutoresizingMaskIntoConstraints = false
        artBox.addSubview(artImageView)
        NSLayoutConstraint.activate([
            artImageView.topAnchor.constraint(equalTo: artBox.topAnchor), artImageView.bottomAnchor.constraint(equalTo: artBox.bottomAnchor),
            artImageView.leadingAnchor.constraint(equalTo: artBox.leadingAnchor), artImageView.trailingAnchor.constraint(equalTo: artBox.trailingAnchor)
        ])
        
        let spotBadgeView = NSImageView(image: NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil) ?? NSImage())
        spotBadgeView.contentTintColor = C.spotifyGreen; spotBadgeView.translatesAutoresizingMaskIntoConstraints = false
        artBox.addSubview(spotBadgeView)
        NSLayoutConstraint.activate([
            spotBadgeView.trailingAnchor.constraint(equalTo: artBox.trailingAnchor, constant: -4),
            spotBadgeView.bottomAnchor.constraint(equalTo: artBox.bottomAnchor, constant: -4),
            spotBadgeView.widthAnchor.constraint(equalToConstant: 18), spotBadgeView.heightAnchor.constraint(equalToConstant: 18),
        ])

        npTitleLabel = lbl("No Music", 14, .bold, C.textPrimary); npTitleLabel.maximumNumberOfLines = 1
        npArtistLabel = lbl("Play something in any app", 11, .regular, C.textSecondary); npArtistLabel.maximumNumberOfLines = 1

        let prevBtn = iconBtn("backward.fill", size: 12, color: C.textPrimary, action: #selector(prevTrack))
        npPlayBtn = iconBtn("pause.fill", size: 14, color: C.textPrimary, action: #selector(playPauseTrack))
        let nextBtn = iconBtn("forward.fill", size: 12, color: C.textPrimary, action: #selector(nextTrack))
        
        let airplayBtn = iconBtn("airplayaudio", size: 13, color: C.airplayBlue, action: #selector(openAirPlayMenu))
        
        progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: #selector(onScrubTrack(_:)))
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        // .small rather than .mini: the mini knob is a very small hit target for
        // something you're meant to grab and drag.
        progressSlider.controlSize = .small
        // Fire once on mouse-up instead of continuously through the drag, so a
        // single scrub doesn't spawn dozens of seek commands.
        progressSlider.isContinuous = false
        
        progressTimeLabel = lbl("0:00", 11, .medium, NSColor(white: 1.0, alpha: 0.6))
        progressTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        progressRemainLabel = lbl("-0:00", 11, .medium, NSColor(white: 1.0, alpha: 0.6))
        progressRemainLabel.translatesAutoresizingMaskIntoConstraints = false
        progressRemainLabel.alignment = .right

        // System output volume — a real Dynamic Island / Control Center has one of
        // these; NotchDrop only had the (read-only) song position bar until now.
        volumeIconBtn = iconBtn("speaker.wave.2.fill", size: 11, color: NSColor(white: 1.0, alpha: 0.6), action: #selector(toggleSystemMute))
        volumeSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: #selector(onVolumeSlider(_:)))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false; volumeSlider.controlSize = .mini
        // Continuous firing meant ~6 synchronous HAL round trips per drag increment
        // on the main thread — visibly stuttery on slow (Bluetooth) output devices.
        volumeSlider.isContinuous = false

        col1.addSubview(npTitleLabel); col1.addSubview(npArtistLabel)
        col1.addSubview(prevBtn); col1.addSubview(npPlayBtn); col1.addSubview(nextBtn); col1.addSubview(airplayBtn)
        col1.addSubview(progressSlider)
        col1.addSubview(progressTimeLabel); col1.addSubview(progressRemainLabel)
        col1.addSubview(volumeIconBtn); col1.addSubview(volumeSlider)

        NSLayoutConstraint.activate([
            artBox.leadingAnchor.constraint(equalTo: col1.leadingAnchor),
            artBox.centerYAnchor.constraint(equalTo: col1.centerYAnchor),
            artBox.widthAnchor.constraint(equalToConstant: 110),
            artBox.heightAnchor.constraint(equalToConstant: 110),

            npTitleLabel.topAnchor.constraint(equalTo: col1.topAnchor, constant: 10),
            npTitleLabel.leadingAnchor.constraint(equalTo: artBox.trailingAnchor, constant: 16),
            npTitleLabel.trailingAnchor.constraint(equalTo: col1.trailingAnchor),

            npArtistLabel.topAnchor.constraint(equalTo: npTitleLabel.bottomAnchor, constant: 4),
            npArtistLabel.leadingAnchor.constraint(equalTo: npTitleLabel.leadingAnchor),
            npArtistLabel.trailingAnchor.constraint(equalTo: col1.trailingAnchor),

            prevBtn.leadingAnchor.constraint(equalTo: npTitleLabel.leadingAnchor),
            prevBtn.topAnchor.constraint(equalTo: npArtistLabel.bottomAnchor, constant: 12),
            npPlayBtn.centerYAnchor.constraint(equalTo: prevBtn.centerYAnchor),
            npPlayBtn.leadingAnchor.constraint(equalTo: prevBtn.trailingAnchor, constant: 16),
            nextBtn.centerYAnchor.constraint(equalTo: prevBtn.centerYAnchor),
            nextBtn.leadingAnchor.constraint(equalTo: npPlayBtn.trailingAnchor, constant: 16),
            airplayBtn.centerYAnchor.constraint(equalTo: prevBtn.centerYAnchor),
            airplayBtn.leadingAnchor.constraint(equalTo: nextBtn.trailingAnchor, constant: 20),

            progressTimeLabel.leadingAnchor.constraint(equalTo: npTitleLabel.leadingAnchor),
            progressTimeLabel.centerYAnchor.constraint(equalTo: progressSlider.centerYAnchor),
            progressTimeLabel.widthAnchor.constraint(equalToConstant: 32),
            
            progressSlider.leadingAnchor.constraint(equalTo: progressTimeLabel.trailingAnchor, constant: 6),
            progressSlider.topAnchor.constraint(equalTo: prevBtn.bottomAnchor, constant: 14),
            progressSlider.trailingAnchor.constraint(equalTo: progressRemainLabel.leadingAnchor, constant: -6),
            
            progressRemainLabel.trailingAnchor.constraint(equalTo: col1.trailingAnchor, constant: -16),
            progressRemainLabel.centerYAnchor.constraint(equalTo: progressSlider.centerYAnchor),
            progressRemainLabel.widthAnchor.constraint(equalToConstant: 36),

            volumeIconBtn.leadingAnchor.constraint(equalTo: npTitleLabel.leadingAnchor),
            volumeIconBtn.centerYAnchor.constraint(equalTo: volumeSlider.centerYAnchor),
            volumeIconBtn.widthAnchor.constraint(equalToConstant: 14),

            volumeSlider.leadingAnchor.constraint(equalTo: volumeIconBtn.trailingAnchor, constant: 8),
            volumeSlider.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 12),
            volumeSlider.trailingAnchor.constraint(equalTo: col1.trailingAnchor, constant: -16),
        ])

        let col3 = NSView(); col3.translatesAutoresizingMaskIntoConstraints = false
        nookContainer.addSubview(col3)

        mirrorCircleView = NSView(); mirrorCircleView.wantsLayer = true
        mirrorCircleView.layer?.backgroundColor = C.pillBg.cgColor; mirrorCircleView.layer?.borderColor = C.pillBorder.cgColor
        mirrorCircleView.layer?.borderWidth = 1; mirrorCircleView.layer?.cornerRadius = 55; mirrorCircleView.layer?.masksToBounds = true
        mirrorCircleView.translatesAutoresizingMaskIntoConstraints = false
        col3.addSubview(mirrorCircleView)

        mirrorCamLayerContainer = NSView(); mirrorCamLayerContainer.translatesAutoresizingMaskIntoConstraints = false
        mirrorCircleView.addSubview(mirrorCamLayerContainer)
        NSLayoutConstraint.activate([
            mirrorCamLayerContainer.topAnchor.constraint(equalTo: mirrorCircleView.topAnchor), mirrorCamLayerContainer.bottomAnchor.constraint(equalTo: mirrorCircleView.bottomAnchor),
            mirrorCamLayerContainer.leadingAnchor.constraint(equalTo: mirrorCircleView.leadingAnchor), mirrorCamLayerContainer.trailingAnchor.constraint(equalTo: mirrorCircleView.trailingAnchor)
        ])

        mirrorIconView = NSImageView(image: NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil) ?? NSImage())
        mirrorIconView.contentTintColor = C.textSecondary; mirrorIconView.translatesAutoresizingMaskIntoConstraints = false
        mirrorCircleView.addSubview(mirrorIconView)

        NSLayoutConstraint.activate([
            mirrorCircleView.centerXAnchor.constraint(equalTo: col3.centerXAnchor),
            mirrorCircleView.centerYAnchor.constraint(equalTo: col3.centerYAnchor),
            mirrorCircleView.widthAnchor.constraint(equalToConstant: 110),
            mirrorCircleView.heightAnchor.constraint(equalToConstant: 110),
            mirrorIconView.centerXAnchor.constraint(equalTo: mirrorCircleView.centerXAnchor),
            mirrorIconView.centerYAnchor.constraint(equalTo: mirrorCircleView.centerYAnchor),
        ])
        mirrorCircleView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleMirrorCamera)))

        // col1 and col3 are both pinned to opposite container edges, so two fixed
        // widths would be unsatisfiable whenever the container is narrower than
        // their sum (330 + 110 + 32pt padding = 472pt). The panel-size preference
        // can produce exactly that, so col1's width is deliberately breakable:
        // AppKit compresses this one predictably instead of picking a constraint
        // to drop on its own and logging a conflict.
        let col1Width = col1.widthAnchor.constraint(equalToConstant: 330)
        col1Width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            col1.leadingAnchor.constraint(equalTo: nookContainer.leadingAnchor),
            col1.topAnchor.constraint(equalTo: nookContainer.topAnchor),
            col1.bottomAnchor.constraint(equalTo: nookContainer.bottomAnchor),
            col1Width,
            col1.trailingAnchor.constraint(lessThanOrEqualTo: col3.leadingAnchor, constant: -12),
            col3.trailingAnchor.constraint(equalTo: nookContainer.trailingAnchor),
            col3.topAnchor.constraint(equalTo: nookContainer.topAnchor),
            col3.bottomAnchor.constraint(equalTo: nookContainer.bottomAnchor),
            col3.widthAnchor.constraint(equalToConstant: 110)
        ])
    }

    func buildTrayTab() {
        let trayTitle = lbl("File Tray", 14, .bold, C.textPrimary)
        trayContainer.addSubview(trayTitle)

        // ── Link downloader ──
        downloadField = NSTextField()
        downloadField.placeholderString = "Pega un link de TikTok, Instagram, X, YouTube…"
        downloadField.font = .systemFont(ofSize: 11)
        downloadField.bezelStyle = .roundedBezel
        downloadField.focusRingType = .none
        downloadField.target = self
        downloadField.action = #selector(startDownload)   // Enter dispara la descarga
        downloadField.translatesAutoresizingMaskIntoConstraints = false
        trayContainer.addSubview(downloadField)

        // MP4 first and selected by default — video is the common case, and MP4 is
        // what actually opens everywhere.
        downloadFormatControl = NSSegmentedControl(labels: ["MP4", "MP3"], trackingMode: .selectOne, target: nil, action: nil)
        downloadFormatControl.selectedSegment = 0
        downloadFormatControl.controlSize = .small
        downloadFormatControl.translatesAutoresizingMaskIntoConstraints = false
        trayContainer.addSubview(downloadFormatControl)

        downloadBtn = NSButton(title: "Descargar", target: self, action: #selector(startDownload))
        downloadBtn.bezelStyle = .rounded; downloadBtn.controlSize = .small
        downloadBtn.translatesAutoresizingMaskIntoConstraints = false
        trayContainer.addSubview(downloadBtn)

        downloadStatusLabel = lbl("", 10, .regular, C.textMuted)
        downloadStatusLabel.maximumNumberOfLines = 1
        downloadStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        trayContainer.addSubview(downloadStatusLabel)

        // Downloads always land in a real folder on disk, but that was invisible —
        // the file only *appeared* in the Shelf, so it read as if it lived nowhere
        // else. This reveals the actual file in Finder.
        revealDownloadBtn = NSButton(title: "Mostrar en Finder", target: self, action: #selector(revealLastDownload))
        revealDownloadBtn.bezelStyle = .inline
        revealDownloadBtn.isBordered = false
        revealDownloadBtn.controlSize = .small
        revealDownloadBtn.contentTintColor = NSColor.systemBlue
        revealDownloadBtn.font = .systemFont(ofSize: 10, weight: .medium)
        revealDownloadBtn.isHidden = true
        revealDownloadBtn.translatesAutoresizingMaskIntoConstraints = false
        trayContainer.addSubview(revealDownloadBtn)

        fileTrayBox = FileTrayView(); fileTrayBox.wantsLayer = true
        fileTrayBox.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        fileTrayBox.layer?.cornerRadius = 8
        fileTrayBox.layer?.cornerCurve = .continuous
        fileTrayBox.layer?.borderWidth = 1; fileTrayBox.layer?.borderColor = NSColor(white: 1.0, alpha: 0.1).cgColor
        fileTrayBox.translatesAutoresizingMaskIntoConstraints = false
        fileTrayBox.updateCallback = { [weak self] in self?.updateTrayUI() }
        fileTrayBox.dragEndedCallback = { [weak self] in self?.isReceivingFileDrag = false }
        trayContainer.addSubview(fileTrayBox)
        
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        // Without this the scroller stayed visible even with nothing to scroll,
        // and with a zero-sized document view (below) macOS drew its knob as a
        // stray little circle floating in the middle of the empty tray.
        scroll.autohidesScrollers = true

        trayFilesStack = NSStackView(); trayFilesStack.orientation = .horizontal; trayFilesStack.spacing = 10
        trayFilesStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = trayFilesStack
        fileTrayBox.addSubview(scroll)
        // A constraint-based document view needs to be tied to the clip view or
        // its size is undefined — it was collapsing to 0×0, which is why the
        // "Drag & Drop Files Here" hint never appeared. Trailing is deliberately
        // left free so the stack can grow past the clip view and actually scroll.
        NSLayoutConstraint.activate([
            trayFilesStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            trayFilesStack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            trayFilesStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        
        trayClearBtn = NSButton(title: "Clear", target: self, action: #selector(clearTray))
        trayClearBtn.bezelStyle = .recessed; trayClearBtn.controlSize = .small
        trayClearBtn.isHidden = true
        trayClearBtn.translatesAutoresizingMaskIntoConstraints = false
        fileTrayBox.addSubview(trayClearBtn)

        airDropBtn = NSButton(title: "AirDrop", target: self, action: #selector(airDropShelf))
        airDropBtn.bezelStyle = .recessed; airDropBtn.controlSize = .small
        airDropBtn.isHidden = true
        airDropBtn.translatesAutoresizingMaskIntoConstraints = false
        fileTrayBox.addSubview(airDropBtn)

        let uploadBtn = NSButton(title: "Upload Files", target: self, action: #selector(uploadFiles))
        uploadBtn.bezelStyle = .recessed; uploadBtn.controlSize = .small
        uploadBtn.translatesAutoresizingMaskIntoConstraints = false
        fileTrayBox.addSubview(uploadBtn)

        NSLayoutConstraint.activate([
            trayTitle.topAnchor.constraint(equalTo: trayContainer.topAnchor),
            trayTitle.centerXAnchor.constraint(equalTo: trayContainer.centerXAnchor),

            downloadField.topAnchor.constraint(equalTo: trayTitle.bottomAnchor, constant: 8),
            downloadField.leadingAnchor.constraint(equalTo: trayContainer.leadingAnchor, constant: 4),
            downloadField.trailingAnchor.constraint(equalTo: downloadFormatControl.leadingAnchor, constant: -8),
            downloadFormatControl.trailingAnchor.constraint(equalTo: downloadBtn.leadingAnchor, constant: -8),
            downloadFormatControl.centerYAnchor.constraint(equalTo: downloadField.centerYAnchor),
            downloadBtn.trailingAnchor.constraint(equalTo: trayContainer.trailingAnchor, constant: -4),
            downloadBtn.centerYAnchor.constraint(equalTo: downloadField.centerYAnchor),

            downloadStatusLabel.topAnchor.constraint(equalTo: downloadField.bottomAnchor, constant: 4),
            downloadStatusLabel.leadingAnchor.constraint(equalTo: trayContainer.leadingAnchor, constant: 6),
            downloadStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: revealDownloadBtn.leadingAnchor, constant: -8),
            revealDownloadBtn.centerYAnchor.constraint(equalTo: downloadStatusLabel.centerYAnchor),
            revealDownloadBtn.trailingAnchor.constraint(equalTo: trayContainer.trailingAnchor, constant: -6),

            fileTrayBox.topAnchor.constraint(equalTo: downloadStatusLabel.bottomAnchor, constant: 6),
            fileTrayBox.bottomAnchor.constraint(equalTo: trayContainer.bottomAnchor, constant: -4),
            fileTrayBox.leadingAnchor.constraint(equalTo: trayContainer.leadingAnchor, constant: 4),
            fileTrayBox.trailingAnchor.constraint(equalTo: trayContainer.trailingAnchor, constant: -4),

            scroll.leadingAnchor.constraint(equalTo: fileTrayBox.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trayClearBtn.leadingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: fileTrayBox.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: fileTrayBox.bottomAnchor, constant: -8),

            uploadBtn.trailingAnchor.constraint(equalTo: fileTrayBox.trailingAnchor, constant: -10),
            uploadBtn.topAnchor.constraint(equalTo: fileTrayBox.topAnchor, constant: 10),
            airDropBtn.trailingAnchor.constraint(equalTo: uploadBtn.leadingAnchor, constant: -8),
            airDropBtn.centerYAnchor.constraint(equalTo: uploadBtn.centerYAnchor),
            trayClearBtn.trailingAnchor.constraint(equalTo: airDropBtn.leadingAnchor, constant: -8),
            trayClearBtn.centerYAnchor.constraint(equalTo: uploadBtn.centerYAnchor)
        ])

        // Bring back whatever was in the Shelf before the app last closed, then
        // paint. updateTrayUI also handles the empty state, which previously only
        // ran after a drop or a clear so a fresh launch showed no hint at all.
        restoreShelf()
        updateTrayUI()
    }

    @objc func startDownload() {
        guard !isDownloading else { return }
        let link = downloadField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else {
            setDownloadStatus("Pega primero un enlace.", color: C.textMuted)
            return
        }
        guard MediaDownloader.isSupportedLink(link) else {
            setDownloadStatus("Eso no parece un enlace válido.", color: NSColor.systemRed)
            return
        }
        let format: MediaDownloader.Format = downloadFormatControl.selectedSegment == 1 ? .audioMP3 : .videoMP4
        isDownloading = true
        downloadBtn.isEnabled = false
        setDownloadStatus(format == .audioMP3 ? "Extrayendo audio…" : "Descargando…", color: C.textSecondary)

        MediaDownloader.download(link, format: format, cookiesFromBrowser: cookieBrowserArgument,
                                 onRetry: { [weak self] attempt, total in
            // TikTok's challenge fails most attempts; without this the panel just
            // sits on "Descargando…" for ten seconds looking hung.
            self?.setDownloadStatus("Reintentando \(attempt)/\(total)…", color: C.textSecondary)
        }) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDownloading = false
                self.downloadBtn.isEnabled = true
                switch outcome {
                case .success(let fileURL):
                    self.downloadField.stringValue = ""
                    self.lastDownloadedFile = fileURL
                    self.revealDownloadBtn.isHidden = false
                    // Name the folder, not just the file — the previous message made
                    // it look like the download only existed inside the Shelf.
                    let folder = fileURL.deletingLastPathComponent().lastPathComponent
                    self.setDownloadStatus("✓ Guardado en \(folder) · \(fileURL.lastPathComponent)", color: C.spotifyGreen)
                    // Straight into the Shelf, so it can be dragged wherever it's needed.
                    if !self.fileTrayBox.files.contains(fileURL) {
                        self.fileTrayBox.files.append(fileURL)
                    }
                    self.updateTrayUI()
                case .missingTool:
                    self.setDownloadStatus("Falta yt-dlp — instálalo desde Ajustes.", color: NSColor.systemOrange)
                case .failure(let message):
                    self.setDownloadStatus(message, color: NSColor.systemRed)
                }
            }
        }
    }

    @objc func revealLastDownload() {
        guard let file = lastDownloadedFile, FileManager.default.fileExists(atPath: file.path) else {
            NSWorkspace.shared.open(MediaDownloader.destinationDirectory)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func setDownloadStatus(_ text: String, color: NSColor) {
        downloadStatusLabel?.stringValue = text
        downloadStatusLabel?.textColor = color
    }

    @objc func airDropShelf() {
        guard !fileTrayBox.files.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: fileTrayBox.files as [Any])
    }

    @objc func uploadFiles() {
        // An LSUIElement app with a non-activating panel never becomes frontmost, so
        // a modal opens behind whatever app is in front while blocking our main
        // thread — indistinguishable from a freeze.
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        if p.runModal() == .OK {
            for url in p.urls {
                if !fileTrayBox.files.contains(url) { fileTrayBox.files.append(url) }
            }
            updateTrayUI()
        }
    }

    func updateTrayUI() {
        // Every mutation of the Shelf funnels through here, so this is the one
        // place that has to remember to save.
        persistShelf()
        trayFilesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if fileTrayBox.files.isEmpty {
            let emptyLbl = lbl("Drag & Drop Files Here", 14, .medium, C.textMuted)
            trayFilesStack.addArrangedSubview(emptyLbl)
            trayClearBtn.isHidden = true
            airDropBtn.isHidden = true
        } else {
            for url in fileTrayBox.files {
                let fv = FileTrayItemView(url: url)
                fv.onRemove = { [weak self] in
                    self?.fileTrayBox.files.removeAll(where: { $0 == url })
                    self?.updateTrayUI()
                }
                fv.translatesAutoresizingMaskIntoConstraints = false
                fv.widthAnchor.constraint(equalToConstant: 70).isActive = true
                fv.heightAnchor.constraint(equalToConstant: 74).isActive = true
                trayFilesStack.addArrangedSubview(fv)
            }
            trayClearBtn.isHidden = false
            airDropBtn.isHidden = false
        }
    }
    @objc func clearTray() {
        fileTrayBox.files.removeAll()
        updateTrayUI()
    }

    // ── Tools Tab ──
    func buildToolsTab() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        toolsContainer.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: toolsContainer.topAnchor), scroll.bottomAnchor.constraint(equalTo: toolsContainer.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: toolsContainer.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: toolsContainer.trailingAnchor)
        ])

        tabToolsStack = NSStackView(); tabToolsStack.orientation = .vertical; tabToolsStack.spacing = 16; tabToolsStack.alignment = .centerX
        tabToolsStack.translatesAutoresizingMaskIntoConstraints = false
        
        let docView = NSView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(tabToolsStack)
        scroll.documentView = docView
        
        NSLayoutConstraint.activate([
            docView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            tabToolsStack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 4),
            tabToolsStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 4),
            tabToolsStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -4),
            tabToolsStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -4)
        ])

        // 1. Clipboard (Moved to top)
        let ccard = makeCardView()
        let cl = lbl("📋 CLIPBOARD HISTORY", 14, .bold, NSColor.systemIndigo)
        clipStackView = NSStackView(); clipStackView.orientation = .vertical; clipStackView.alignment = .leading; clipStackView.distribution = .fill; clipStackView.spacing = 8; clipStackView.translatesAutoresizingMaskIntoConstraints = false
        ccard.addSubview(cl); ccard.addSubview(clipStackView)
        NSLayoutConstraint.activate([
            cl.topAnchor.constraint(equalTo: ccard.topAnchor, constant: 16), cl.leadingAnchor.constraint(equalTo: ccard.leadingAnchor, constant: 16),
            clipStackView.topAnchor.constraint(equalTo: cl.bottomAnchor, constant: 12), clipStackView.leadingAnchor.constraint(equalTo: ccard.leadingAnchor, constant: 16), clipStackView.trailingAnchor.constraint(equalTo: ccard.trailingAnchor, constant: -16), clipStackView.bottomAnchor.constraint(equalTo: ccard.bottomAnchor, constant: -16)
        ])
        tabToolsStack.addArrangedSubview(ccard); ccard.widthAnchor.constraint(equalTo: tabToolsStack.widthAnchor).isActive = true
        restoreClipboard()
        updateClipUI()

        // 2. Alarms
        let acard = makeCardView()
        let al = lbl("⏰ NATIVE ALARMS", 14, .bold, C.spotifyGreen)
        acard.addSubview(al)
        
        let agrid = NSStackView(); agrid.orientation = .horizontal; agrid.spacing = 8; agrid.distribution = .fillEqually
        agrid.translatesAutoresizingMaskIntoConstraints = false
        acard.addSubview(agrid)
        for m in [5, 10, 15, 30, 45, 60] {
            let b = NSButton(title: "\(m)m", target: self, action: #selector(setAlarmPreset(_:)))
            b.tag = m; b.bezelStyle = .rounded; b.controlSize = .regular; b.font = .systemFont(ofSize: 13, weight: .semibold)
            agrid.addArrangedSubview(b)
        }
        
        let picker = NSDatePicker()
        picker.datePickerElements = [.hourMinute]
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single
        picker.dateValue = Date()
        picker.controlSize = .small
        picker.translatesAutoresizingMaskIntoConstraints = false
        alarmTimePicker = picker

        let setTimeBtn = NSButton(title: "Fijar hora", target: self, action: #selector(setAlarmAtPickedTime))
        setTimeBtn.bezelStyle = .rounded; setTimeBtn.controlSize = .small; setTimeBtn.translatesAutoresizingMaskIntoConstraints = false

        let timeRow = NSStackView(views: [picker, setTimeBtn])
        timeRow.orientation = .horizontal; timeRow.spacing = 8; timeRow.translatesAutoresizingMaskIntoConstraints = false
        acard.addSubview(timeRow)

        alarmStatusLabel = lbl("Sin alarma activa", 12, .medium, C.textMuted); acard.addSubview(alarmStatusLabel)

        let cancelBtn = NSButton(title: "Cancelar", target: self, action: #selector(cancelAlarm))
        cancelBtn.bezelStyle = .recessed; cancelBtn.controlSize = .small; cancelBtn.isHidden = true
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        alarmCancelBtn = cancelBtn
        acard.addSubview(cancelBtn)

        let clockAppBtn = NSButton(title: "Open Clock.app ↗", target: self, action: #selector(openClockApp))
        clockAppBtn.bezelStyle = .recessed; clockAppBtn.controlSize = .small; clockAppBtn.translatesAutoresizingMaskIntoConstraints = false
        acard.addSubview(clockAppBtn)

        NSLayoutConstraint.activate([
            al.topAnchor.constraint(equalTo: acard.topAnchor, constant: 16), al.leadingAnchor.constraint(equalTo: acard.leadingAnchor, constant: 16),
            clockAppBtn.centerYAnchor.constraint(equalTo: al.centerYAnchor), clockAppBtn.trailingAnchor.constraint(equalTo: acard.trailingAnchor, constant: -16),
            agrid.topAnchor.constraint(equalTo: al.bottomAnchor, constant: 16), agrid.leadingAnchor.constraint(equalTo: acard.leadingAnchor, constant: 16), agrid.trailingAnchor.constraint(equalTo: acard.trailingAnchor, constant: -16),
            timeRow.topAnchor.constraint(equalTo: agrid.bottomAnchor, constant: 12), timeRow.leadingAnchor.constraint(equalTo: acard.leadingAnchor, constant: 16),
            alarmStatusLabel.topAnchor.constraint(equalTo: timeRow.bottomAnchor, constant: 12), alarmStatusLabel.leadingAnchor.constraint(equalTo: acard.leadingAnchor, constant: 16),
            alarmStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelBtn.leadingAnchor, constant: -10),
            cancelBtn.centerYAnchor.constraint(equalTo: alarmStatusLabel.centerYAnchor), cancelBtn.trailingAnchor.constraint(equalTo: acard.trailingAnchor, constant: -16),
            acard.bottomAnchor.constraint(equalTo: alarmStatusLabel.bottomAnchor, constant: 16)
        ])
        tabToolsStack.addArrangedSubview(acard); acard.widthAnchor.constraint(equalTo: tabToolsStack.widthAnchor).isActive = true

        // 3. Stopwatch
        let scard = makeCardView()
        let sl = lbl("⏱ STOPWATCH", 14, .bold, NSColor.systemOrange)
        swDisplayLabel = lbl("00:00.0", 28, .bold, C.textPrimary); swDisplayLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        swStartBtn = NSButton(title: "Start", target: self, action: #selector(toggleSw)); swStartBtn.bezelStyle = .rounded; swStartBtn.controlSize = .regular; swStartBtn.translatesAutoresizingMaskIntoConstraints = false
        let swRBtn = NSButton(title: "Reset", target: self, action: #selector(resetSw)); swRBtn.bezelStyle = .rounded; swRBtn.controlSize = .regular; swRBtn.translatesAutoresizingMaskIntoConstraints = false
        scard.addSubview(sl); scard.addSubview(swDisplayLabel); scard.addSubview(swStartBtn); scard.addSubview(swRBtn)
        NSLayoutConstraint.activate([
            sl.topAnchor.constraint(equalTo: scard.topAnchor, constant: 16), sl.leadingAnchor.constraint(equalTo: scard.leadingAnchor, constant: 16),
            swDisplayLabel.topAnchor.constraint(equalTo: sl.bottomAnchor, constant: 8), swDisplayLabel.leadingAnchor.constraint(equalTo: scard.leadingAnchor, constant: 16),
            swRBtn.centerYAnchor.constraint(equalTo: swDisplayLabel.centerYAnchor), swRBtn.trailingAnchor.constraint(equalTo: scard.trailingAnchor, constant: -16),
            swStartBtn.centerYAnchor.constraint(equalTo: swDisplayLabel.centerYAnchor), swStartBtn.trailingAnchor.constraint(equalTo: swRBtn.leadingAnchor, constant: -12),
            scard.bottomAnchor.constraint(equalTo: swDisplayLabel.bottomAnchor, constant: 16)
        ])
        tabToolsStack.addArrangedSubview(scard); scard.widthAnchor.constraint(equalTo: tabToolsStack.widthAnchor).isActive = true
    }


    // ── Converter Tab ──
    // Left column picks the file; right column is the two modes (change format /
    // compress) with whatever options apply to what was picked.
    func buildConvertTab() {
        let left = NSView(); left.translatesAutoresizingMaskIntoConstraints = false
        convertContainer.addSubview(left)

        let dropIcon = NSImageView()
        dropIcon.image = NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        dropIcon.contentTintColor = C.textMuted
        dropIcon.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(dropIcon)

        convChooseBtn = NSButton(title: "Subir archivo", target: self, action: #selector(chooseConvertFile))
        convChooseBtn.bezelStyle = .rounded; convChooseBtn.controlSize = .regular
        convChooseBtn.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(convChooseBtn)

        convFileLabel = lbl("Ningún archivo seleccionado", 10, .regular, C.textMuted)
        convFileLabel.maximumNumberOfLines = 2
        convFileLabel.alignment = .center
        convFileLabel.lineBreakMode = .byTruncatingMiddle
        convFileLabel.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(convFileLabel)

        NSLayoutConstraint.activate([
            dropIcon.topAnchor.constraint(equalTo: left.topAnchor, constant: 10),
            dropIcon.centerXAnchor.constraint(equalTo: left.centerXAnchor),
            convChooseBtn.topAnchor.constraint(equalTo: dropIcon.bottomAnchor, constant: 10),
            convChooseBtn.centerXAnchor.constraint(equalTo: left.centerXAnchor),
            convFileLabel.topAnchor.constraint(equalTo: convChooseBtn.bottomAnchor, constant: 8),
            convFileLabel.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            convFileLabel.trailingAnchor.constraint(equalTo: left.trailingAnchor),
        ])

        let right = NSView(); right.translatesAutoresizingMaskIntoConstraints = false
        convertContainer.addSubview(right)

        convModeControl = NSSegmentedControl(labels: ["Cambiar formato", "Comprimir"],
                                             trackingMode: .selectOne,
                                             target: self, action: #selector(convModeChanged))
        convModeControl.selectedSegment = 0
        convModeControl.controlSize = .small
        convModeControl.isEnabled = false
        convModeControl.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(convModeControl)

        convOptionLabel = lbl("Formato de salida", 10, .regular, C.textMuted)
        convOptionLabel.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(convOptionLabel)

        convOptionsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        convOptionsPopup.controlSize = .small
        convOptionsPopup.isEnabled = false
        convOptionsPopup.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(convOptionsPopup)

        convRunBtn = NSButton(title: "Convertir", target: self, action: #selector(runConversion))
        convRunBtn.bezelStyle = .rounded; convRunBtn.controlSize = .regular
        convRunBtn.isEnabled = false
        convRunBtn.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(convRunBtn)

        convStatusLabel = lbl("", 10, .regular, C.textMuted)
        convStatusLabel.maximumNumberOfLines = 2
        convStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(convStatusLabel)

        convRevealBtn = NSButton(title: "Mostrar en Finder", target: self, action: #selector(revealConvertedFile))
        convRevealBtn.bezelStyle = .inline; convRevealBtn.isBordered = false
        convRevealBtn.controlSize = .small
        convRevealBtn.contentTintColor = NSColor.systemBlue
        convRevealBtn.font = .systemFont(ofSize: 10, weight: .medium)
        convRevealBtn.isHidden = true
        convRevealBtn.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(convRevealBtn)

        NSLayoutConstraint.activate([
            convModeControl.topAnchor.constraint(equalTo: right.topAnchor, constant: 10),
            convModeControl.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            convModeControl.trailingAnchor.constraint(lessThanOrEqualTo: right.trailingAnchor),

            convOptionLabel.topAnchor.constraint(equalTo: convModeControl.bottomAnchor, constant: 12),
            convOptionLabel.leadingAnchor.constraint(equalTo: right.leadingAnchor),

            convOptionsPopup.topAnchor.constraint(equalTo: convOptionLabel.bottomAnchor, constant: 4),
            convOptionsPopup.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            convOptionsPopup.widthAnchor.constraint(equalToConstant: 140),

            convRunBtn.centerYAnchor.constraint(equalTo: convOptionsPopup.centerYAnchor),
            convRunBtn.leadingAnchor.constraint(equalTo: convOptionsPopup.trailingAnchor, constant: 10),

            convStatusLabel.topAnchor.constraint(equalTo: convOptionsPopup.bottomAnchor, constant: 10),
            convStatusLabel.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            convStatusLabel.trailingAnchor.constraint(equalTo: right.trailingAnchor),

            convRevealBtn.topAnchor.constraint(equalTo: convStatusLabel.bottomAnchor, constant: 2),
            convRevealBtn.leadingAnchor.constraint(equalTo: right.leadingAnchor),

            left.leadingAnchor.constraint(equalTo: convertContainer.leadingAnchor),
            left.topAnchor.constraint(equalTo: convertContainer.topAnchor),
            left.bottomAnchor.constraint(equalTo: convertContainer.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 165),

            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 16),
            right.trailingAnchor.constraint(equalTo: convertContainer.trailingAnchor),
            right.topAnchor.constraint(equalTo: convertContainer.topAnchor),
            right.bottomAnchor.constraint(equalTo: convertContainer.bottomAnchor),
        ])
    }

    @objc func chooseConvertFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Elige el archivo a convertir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setConvertFile(url)
    }

    func setConvertFile(_ url: URL) {
        convSelectedFile = url
        convResultFile = nil
        convRevealBtn.isHidden = true
        convFileLabel.stringValue = url.lastPathComponent
        convFileLabel.textColor = C.textPrimary

        let kind = FileConverter.kind(of: url)
        guard kind != .unsupported else {
            convModeControl.isEnabled = false
            convOptionsPopup.isEnabled = false
            convRunBtn.isEnabled = false
            convOptionsPopup.removeAllItems()
            convStatusLabel.stringValue = "Tipo de archivo no soportado."
            convStatusLabel.textColor = NSColor.systemRed
            return
        }
        convModeControl.isEnabled = true
        // Compressing a PDF isn't offered, so don't leave the segment selectable.
        convModeControl.setEnabled(kind.canCompress, forSegment: 1)
        if !kind.canCompress && convModeControl.selectedSegment == 1 {
            convModeControl.selectedSegment = 0
        }
        convStatusLabel.stringValue = ""
        convStatusLabel.textColor = C.textMuted
        refreshConvertOptions()
    }

    @objc func convModeChanged() { refreshConvertOptions() }

    func refreshConvertOptions() {
        guard let url = convSelectedFile else { return }
        let kind = FileConverter.kind(of: url)
        convOptionsPopup.removeAllItems()

        if convModeControl.selectedSegment == 1 {
            convOptionLabel.stringValue = "Reducir a…"
            // Labelled as a share of the ORIGINAL SIZE, which is what the numbers
            // now actually control. Framing them as "quality" was misleading: a
            // 90%-quality re-encode of an already-compressed file grew it by 51%.
            convOptionsPopup.addItems(withTitles: ["75 % del tamaño", "50 % del tamaño",
                                                   "30 % del tamaño", "15 % del tamaño"])
            convRunBtn.title = "Comprimir"
        } else {
            convOptionLabel.stringValue = "Formato de salida"
            // Never offer converting a file to the format it already is.
            let current = url.pathExtension.lowercased()
            let targets = kind.targets.filter { $0 != current && !($0 == "jpg" && current == "jpeg") }
            convOptionsPopup.addItems(withTitles: targets.map { $0.uppercased() })
            convRunBtn.title = "Convertir"
        }
        let hasOptions = convOptionsPopup.numberOfItems > 0
        convOptionsPopup.isEnabled = hasOptions
        convRunBtn.isEnabled = hasOptions && !isConverting
        if !hasOptions {
            convStatusLabel.stringValue = "No hay otros formatos disponibles para este archivo."
        }
    }

    @objc func runConversion() {
        guard let url = convSelectedFile, !isConverting else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            convStatusLabel.stringValue = "El archivo ya no existe."
            convStatusLabel.textColor = NSColor.systemRed
            return
        }
        isConverting = true
        convRunBtn.isEnabled = false
        convRevealBtn.isHidden = true
        convStatusLabel.textColor = C.textSecondary
        convStatusLabel.stringValue = convModeControl.selectedSegment == 1 ? "Comprimiendo…" : "Convirtiendo…"

        let handler: (FileConverter.Outcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            self.isConverting = false
            self.convRunBtn.isEnabled = true
            switch outcome {
            case .success(let out):
                self.convResultFile = out
                self.convRevealBtn.isHidden = false
                let newBytes = FileConverter.fileSize(of: out)
                var sizeText = " · " + ByteCountFormatter.string(fromByteCount: newBytes, countStyle: .file)
                // Spell out the change against the original — the whole point of
                // compressing is the delta, and it's what makes a bad result obvious.
                if let src = self.convSelectedFile {
                    let oldBytes = FileConverter.fileSize(of: src)
                    if oldBytes > 0 && newBytes > 0 {
                        let pct = Int((Double(newBytes) / Double(oldBytes)) * 100)
                        let from = ByteCountFormatter.string(fromByteCount: oldBytes, countStyle: .file)
                        sizeText = " · \(from) → " + ByteCountFormatter.string(fromByteCount: newBytes, countStyle: .file) + " (\(pct) %)"
                    }
                }
                self.convStatusLabel.stringValue = "✓ \(out.lastPathComponent)\(sizeText)"
                self.convStatusLabel.textColor = C.spotifyGreen
            case .missingFFmpeg:
                self.convStatusLabel.stringValue = "Falta ffmpeg para video/audio: brew install ffmpeg"
                self.convStatusLabel.textColor = NSColor.systemOrange
            case .failure(let message):
                self.convStatusLabel.stringValue = message
                self.convStatusLabel.textColor = NSColor.systemRed
            }
        }

        if convModeControl.selectedSegment == 1 {
            let percent = [75, 50, 30, 15][max(0, min(3, convOptionsPopup.indexOfSelectedItem))]
            FileConverter.compress(url, targetPercent: percent, completion: handler)
        } else {
            let target = (convOptionsPopup.titleOfSelectedItem ?? "").lowercased()
            FileConverter.convert(url, to: target, completion: handler)
        }
    }

    @objc func revealConvertedFile() {
        guard let file = convResultFile, FileManager.default.fileExists(atPath: file.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    // ── Settings Tab ──
    func settingsToggleRow(title: String, subtitle: String, isOn: Bool, action: Selector) -> (row: NSView, toggle: NSSwitch) {
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
        let titleLbl = lbl(title, 12, .medium, C.textPrimary); titleLbl.maximumNumberOfLines = 1
        let subLbl = lbl(subtitle, 10, .regular, C.textMuted); subLbl.maximumNumberOfLines = 2
        let sw = NSSwitch(); sw.state = isOn ? .on : .off; sw.target = self; sw.action = action
        sw.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        subLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleLbl); row.addSubview(subLbl); row.addSubview(sw)
        NSLayoutConstraint.activate([
            titleLbl.topAnchor.constraint(equalTo: row.topAnchor),
            titleLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            titleLbl.trailingAnchor.constraint(lessThanOrEqualTo: sw.leadingAnchor, constant: -10),
            subLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 3),
            subLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            subLbl.trailingAnchor.constraint(lessThanOrEqualTo: sw.leadingAnchor, constant: -10),
            subLbl.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            sw.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            sw.centerYAnchor.constraint(equalTo: titleLbl.centerYAnchor),
        ])
        return (row, sw)
    }

    func settingsSegmentedRow(title: String, subtitle: String, options: [String], selectedIndex: Int, action: Selector) -> (row: NSView, control: NSSegmentedControl) {
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
        let titleLbl = lbl(title, 12, .medium, C.textPrimary); titleLbl.maximumNumberOfLines = 1
        let subLbl = lbl(subtitle, 10, .regular, C.textMuted); subLbl.maximumNumberOfLines = 2
        let seg = NSSegmentedControl(labels: options, trackingMode: .selectOne, target: self, action: action)
        seg.selectedSegment = selectedIndex
        seg.controlSize = .small
        seg.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        subLbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleLbl); row.addSubview(subLbl); row.addSubview(seg)
        NSLayoutConstraint.activate([
            titleLbl.topAnchor.constraint(equalTo: row.topAnchor),
            titleLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            titleLbl.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            subLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 3),
            subLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            subLbl.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            seg.topAnchor.constraint(equalTo: subLbl.bottomAnchor, constant: 8),
            seg.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            seg.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return (row, seg)
    }

    func buildSettingsTab() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        settingsContainer.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: settingsContainer.topAnchor), scroll.bottomAnchor.constraint(equalTo: settingsContainer.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: settingsContainer.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: settingsContainer.trailingAnchor)
        ])

        let settingsStack = NSStackView(); settingsStack.orientation = .vertical; settingsStack.spacing = 16; settingsStack.alignment = .centerX
        settingsStack.translatesAutoresizingMaskIntoConstraints = false

        let docView = NSView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(settingsStack)
        scroll.documentView = docView

        NSLayoutConstraint.activate([
            docView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            settingsStack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 4),
            settingsStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 4),
            settingsStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -4),
            settingsStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -4)
        ])

        // 1. General
        let gcard = makeCardView()
        let gl = lbl("⚙️ GENERAL", 14, .bold, C.textPrimary)
        gcard.addSubview(gl)

        let (loginRow, loginSwitch) = settingsToggleRow(
            title: "Iniciar al iniciar sesión",
            subtitle: "Abre NotchDrop automáticamente al entrar a macOS.",
            isOn: SMAppService.mainApp.status == .enabled,
            action: #selector(toggleLaunchAtLogin(_:))
        )
        launchAtLoginSwitch = loginSwitch

        let (hoverRow, hoverSwitch) = settingsToggleRow(
            title: "Abrir al pasar el mouse por el notch",
            subtitle: "Si lo desactivas, haz clic en el notch para abrirlo.",
            isOn: hoverToOpenEnabled,
            action: #selector(toggleHoverToOpen(_:))
        )
        hoverToOpenSwitchCtl = hoverSwitch

        // Notch *position* is auto-detected per device already (see
        // hasPhysicalNotch) — there's no "select your MacBook model" control
        // because a hardcoded table can't beat that and would go stale with
        // every new model. What's actually adjustable is overall panel size,
        // since screens genuinely range from a 13" Air to a 16" Pro.
        let (sizeRow, sizeControl) = settingsSegmentedRow(
            title: "Tamaño del panel expandido",
            subtitle: "La posición del notch se detecta sola en cualquier Mac; esto es solo qué tan grande se ve.",
            options: ["Compacto", "Estándar", "Amplio"],
            selectedIndex: panelScale < 0.95 ? 0 : (panelScale > 1.05 ? 2 : 1),
            action: #selector(onPanelSizeChanged(_:))
        )
        panelSizeControl = sizeControl

        let (clipRow, clipSwitch) = settingsToggleRow(
            title: "Recordar portapapeles entre reinicios",
            subtitle: "Guarda el historial de texto en disco. Las imágenes nunca se guardan.",
            isOn: persistClipboardEnabled,
            action: #selector(togglePersistClipboard(_:))
        )
        persistClipboardSwitch = clipSwitch

        let rowsStack = NSStackView(views: [loginRow, hoverRow, clipRow, sizeRow])
        rowsStack.orientation = .vertical; rowsStack.spacing = 14; rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        gcard.addSubview(rowsStack)
        loginRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        hoverRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        clipRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        sizeRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true

        notchDiagnosticLabel = lbl(notchDiagnosticText(), 10, .regular, C.textMuted)
        notchDiagnosticLabel.maximumNumberOfLines = 2
        notchDiagnosticLabel.translatesAutoresizingMaskIntoConstraints = false
        gcard.addSubview(notchDiagnosticLabel)

        NSLayoutConstraint.activate([
            gl.topAnchor.constraint(equalTo: gcard.topAnchor, constant: 16), gl.leadingAnchor.constraint(equalTo: gcard.leadingAnchor, constant: 16),
            rowsStack.topAnchor.constraint(equalTo: gl.bottomAnchor, constant: 14),
            rowsStack.leadingAnchor.constraint(equalTo: gcard.leadingAnchor, constant: 16),
            rowsStack.trailingAnchor.constraint(equalTo: gcard.trailingAnchor, constant: -16),
            notchDiagnosticLabel.topAnchor.constraint(equalTo: rowsStack.bottomAnchor, constant: 14),
            notchDiagnosticLabel.leadingAnchor.constraint(equalTo: gcard.leadingAnchor, constant: 16),
            notchDiagnosticLabel.trailingAnchor.constraint(equalTo: gcard.trailingAnchor, constant: -16),
            gcard.bottomAnchor.constraint(equalTo: notchDiagnosticLabel.bottomAnchor, constant: 16),
        ])
        settingsStack.addArrangedSubview(gcard); gcard.widthAnchor.constraint(equalTo: settingsStack.widthAnchor).isActive = true

        // 2. Live audio
        let acard = makeCardView()
        let al = lbl("🎚 AUDIO EN VIVO", 14, .bold, NSColor.systemTeal)
        audioStatusLabel = lbl(audioStatusText(), 11, .regular, C.textSecondary)
        audioStatusLabel.maximumNumberOfLines = 2
        audioStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        let retryBtn = NSButton(title: "Reintentar acceso", target: self, action: #selector(retryAudioAccess))
        retryBtn.bezelStyle = .recessed; retryBtn.controlSize = .small; retryBtn.translatesAutoresizingMaskIntoConstraints = false
        acard.addSubview(al); acard.addSubview(audioStatusLabel); acard.addSubview(retryBtn)
        NSLayoutConstraint.activate([
            al.topAnchor.constraint(equalTo: acard.topAnchor, constant: 16), al.leadingAnchor.constraint(equalTo: acard.leadingAnchor, constant: 16),
            audioStatusLabel.topAnchor.constraint(equalTo: al.bottomAnchor, constant: 10),
            audioStatusLabel.leadingAnchor.constraint(equalTo: acard.leadingAnchor, constant: 16),
            audioStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: retryBtn.leadingAnchor, constant: -10),
            retryBtn.centerYAnchor.constraint(equalTo: audioStatusLabel.centerYAnchor),
            retryBtn.trailingAnchor.constraint(equalTo: acard.trailingAnchor, constant: -16),
            acard.bottomAnchor.constraint(equalTo: audioStatusLabel.bottomAnchor, constant: 16)
        ])
        settingsStack.addArrangedSubview(acard); acard.widthAnchor.constraint(equalTo: settingsStack.widthAnchor).isActive = true

        // 3. Downloader
        let dcard = makeCardView()
        let dl = lbl("⬇︎ DESCARGA DE LINKS", 14, .bold, NSColor.systemBlue)
        downloaderStatusLabel = lbl(downloaderStatusText(), 11, .regular, C.textSecondary)
        downloaderStatusLabel.maximumNumberOfLines = 3
        downloaderStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        // Off by default: this hands yt-dlp your browser's cookies so blocked sites
        // (TikTok, Instagram) treat the request as a signed-in session. It only ever
        // goes to yt-dlp on this machine, but it's your session data, so it's opt-in.
        cookieBrowserPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        cookieBrowserPopup.addItems(withTitles: ["Sin cookies", "Chrome", "Safari", "Firefox", "Brave", "Edge"])
        cookieBrowserPopup.selectItem(withTitle: cookieBrowserChoice)
        cookieBrowserPopup.target = self
        cookieBrowserPopup.action = #selector(onCookieBrowserChanged(_:))
        cookieBrowserPopup.controlSize = .small
        cookieBrowserPopup.translatesAutoresizingMaskIntoConstraints = false
        let cookieLbl = lbl("Cookies del navegador (para TikTok/Instagram bloqueados)", 10, .regular, C.textMuted)
        cookieLbl.maximumNumberOfLines = 2
        cookieLbl.translatesAutoresizingMaskIntoConstraints = false
        dcard.addSubview(cookieLbl); dcard.addSubview(cookieBrowserPopup)

        let copyCmdBtn = NSButton(title: "Copiar comando", target: self, action: #selector(copyInstallCommand))
        copyCmdBtn.bezelStyle = .recessed; copyCmdBtn.controlSize = .small
        copyCmdBtn.translatesAutoresizingMaskIntoConstraints = false
        let openFolderBtn = NSButton(title: "Abrir carpeta ↗", target: self, action: #selector(openDownloadsFolder))
        openFolderBtn.bezelStyle = .recessed; openFolderBtn.controlSize = .small
        openFolderBtn.translatesAutoresizingMaskIntoConstraints = false
        dcard.addSubview(dl); dcard.addSubview(downloaderStatusLabel)
        dcard.addSubview(copyCmdBtn); dcard.addSubview(openFolderBtn)
        NSLayoutConstraint.activate([
            dl.topAnchor.constraint(equalTo: dcard.topAnchor, constant: 16),
            dl.leadingAnchor.constraint(equalTo: dcard.leadingAnchor, constant: 16),
            openFolderBtn.centerYAnchor.constraint(equalTo: dl.centerYAnchor),
            openFolderBtn.trailingAnchor.constraint(equalTo: dcard.trailingAnchor, constant: -16),
            downloaderStatusLabel.topAnchor.constraint(equalTo: dl.bottomAnchor, constant: 10),
            downloaderStatusLabel.leadingAnchor.constraint(equalTo: dcard.leadingAnchor, constant: 16),
            downloaderStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyCmdBtn.leadingAnchor, constant: -10),
            copyCmdBtn.centerYAnchor.constraint(equalTo: downloaderStatusLabel.centerYAnchor),
            copyCmdBtn.trailingAnchor.constraint(equalTo: dcard.trailingAnchor, constant: -16),

            cookieLbl.topAnchor.constraint(equalTo: downloaderStatusLabel.bottomAnchor, constant: 12),
            cookieLbl.leadingAnchor.constraint(equalTo: dcard.leadingAnchor, constant: 16),
            cookieLbl.trailingAnchor.constraint(lessThanOrEqualTo: cookieBrowserPopup.leadingAnchor, constant: -10),
            cookieBrowserPopup.centerYAnchor.constraint(equalTo: cookieLbl.centerYAnchor),
            cookieBrowserPopup.trailingAnchor.constraint(equalTo: dcard.trailingAnchor, constant: -16),
            cookieBrowserPopup.widthAnchor.constraint(equalToConstant: 120),

            dcard.bottomAnchor.constraint(equalTo: cookieLbl.bottomAnchor, constant: 16)
        ])
        settingsStack.addArrangedSubview(dcard); dcard.widthAnchor.constraint(equalTo: settingsStack.widthAnchor).isActive = true

        // 4. Help
        let hcard = makeCardView()
        let hl = lbl("💡 AYUDA", 14, .bold, NSColor.systemPurple)
        let tourBtn = NSButton(title: "Ver tutorial de nuevo", target: self, action: #selector(replayOnboarding))
        tourBtn.bezelStyle = .recessed; tourBtn.controlSize = .small; tourBtn.translatesAutoresizingMaskIntoConstraints = false
        hcard.addSubview(hl); hcard.addSubview(tourBtn)
        NSLayoutConstraint.activate([
            hl.topAnchor.constraint(equalTo: hcard.topAnchor, constant: 16), hl.leadingAnchor.constraint(equalTo: hcard.leadingAnchor, constant: 16),
            tourBtn.centerYAnchor.constraint(equalTo: hl.centerYAnchor), tourBtn.trailingAnchor.constraint(equalTo: hcard.trailingAnchor, constant: -16),
            hcard.bottomAnchor.constraint(equalTo: hl.bottomAnchor, constant: 16)
        ])
        settingsStack.addArrangedSubview(hcard); hcard.widthAnchor.constraint(equalTo: settingsStack.widthAnchor).isActive = true

        // 4. Updates
        let ucard = makeCardView()
        let ul = lbl("🔄 ACTUALIZACIONES", 14, .bold, NSColor.systemTeal)
        updateStatusLabel = lbl("Versión \(currentVersion)", 10, .regular, C.textMuted)
        updateStatusLabel.maximumNumberOfLines = 2
        updateActionBtn = NSButton(title: "Buscar ahora", target: self, action: #selector(updateButtonPressed))
        updateActionBtn.bezelStyle = .recessed; updateActionBtn.controlSize = .small
        updateActionBtn.translatesAutoresizingMaskIntoConstraints = false
        let (autoRow, _) = settingsToggleRow(
            title: "Buscar actualizaciones automáticamente",
            subtitle: "Una vez al día, en GitHub. Nunca se instala nada sin que pulses Actualizar.",
            isOn: autoUpdateEnabled,
            action: #selector(toggleAutoUpdate(_:))
        )
        ucard.addSubview(ul); ucard.addSubview(updateStatusLabel); ucard.addSubview(updateActionBtn); ucard.addSubview(autoRow)
        NSLayoutConstraint.activate([
            ul.topAnchor.constraint(equalTo: ucard.topAnchor, constant: 16), ul.leadingAnchor.constraint(equalTo: ucard.leadingAnchor, constant: 16),
            updateActionBtn.centerYAnchor.constraint(equalTo: ul.centerYAnchor), updateActionBtn.trailingAnchor.constraint(equalTo: ucard.trailingAnchor, constant: -16),
            updateStatusLabel.topAnchor.constraint(equalTo: ul.bottomAnchor, constant: 6),
            updateStatusLabel.leadingAnchor.constraint(equalTo: ul.leadingAnchor),
            updateStatusLabel.trailingAnchor.constraint(equalTo: ucard.trailingAnchor, constant: -16),
            autoRow.topAnchor.constraint(equalTo: updateStatusLabel.bottomAnchor, constant: 10),
            autoRow.leadingAnchor.constraint(equalTo: ucard.leadingAnchor, constant: 16),
            autoRow.trailingAnchor.constraint(equalTo: ucard.trailingAnchor, constant: -16),
            ucard.bottomAnchor.constraint(equalTo: autoRow.bottomAnchor, constant: 14)
        ])
        settingsStack.addArrangedSubview(ucard); ucard.widthAnchor.constraint(equalTo: settingsStack.widthAnchor).isActive = true

        // 5. About / Quit
        let qcard = makeCardView()
        // Reads the real bundle version instead of a hardcoded string — the
        // source header comment, Info.plist, and this label had all drifted to
        // different version numbers ("v7", "2.0.0", "v2") before this.
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "?"
        let ql = lbl("NotchDrop v\(shortVersion)", 13, .bold, C.textPrimary)
        let qsub = lbl("Build \(buildNumber) · Compilación local", 10, .regular, C.textMuted)
        let quitBtn = NSButton(title: "Salir de NotchDrop", target: self, action: #selector(quitApp))
        quitBtn.bezelStyle = .recessed; quitBtn.controlSize = .small; quitBtn.translatesAutoresizingMaskIntoConstraints = false
        colorTitle(for: quitBtn, color: NSColor.systemRed, weight: .semibold)
        qcard.addSubview(ql); qcard.addSubview(qsub); qcard.addSubview(quitBtn)
        NSLayoutConstraint.activate([
            ql.topAnchor.constraint(equalTo: qcard.topAnchor, constant: 16), ql.leadingAnchor.constraint(equalTo: qcard.leadingAnchor, constant: 16),
            qsub.topAnchor.constraint(equalTo: ql.bottomAnchor, constant: 2), qsub.leadingAnchor.constraint(equalTo: ql.leadingAnchor),
            quitBtn.centerYAnchor.constraint(equalTo: ql.centerYAnchor), quitBtn.trailingAnchor.constraint(equalTo: qcard.trailingAnchor, constant: -16),
            qcard.bottomAnchor.constraint(equalTo: qsub.bottomAnchor, constant: 16)
        ])
        settingsStack.addArrangedSubview(qcard); qcard.widthAnchor.constraint(equalTo: settingsStack.widthAnchor).isActive = true
    }

    @objc func toggleLaunchAtLogin(_ sender: NSSwitch) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("NotchDrop: launch-at-login toggle failed: %@", error.localizedDescription)
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    @objc func toggleHoverToOpen(_ sender: NSSwitch) {
        hoverToOpenEnabled = sender.state == .on
    }

    @objc func onPanelSizeChanged(_ sender: NSSegmentedControl) {
        let scales: [CGFloat] = [0.85, 1.0, 1.15]
        panelScale = scales[sender.selectedSegment]
        updateContentSizeConstraints()
        fitTabBar()
        if isExpanded { panel.setFrame(getPanelRect(expanded: true), display: true) }
    }

    func notchDiagnosticText() -> String {
        if hasPhysicalNotch {
            return "Notch físico detectado — \(Int(notchWidth))pt de ancho en esta pantalla."
        } else {
            return "Esta pantalla no tiene notch físico — usando uno simulado de \(Int(notchWidth))pt."
        }
    }

    func audioStatusText() -> String {
        if audioMeter.isRunning { return "Activo — detectando el audio del sistema." }
        if audioMeter.isUnavailable { return "No disponible. Puede requerir permiso de \"Grabación de pantalla y audio del sistema\" en Configuración del Sistema." }
        return "Iniciando…"
    }

    static let ytDlpInstallCommand = "brew install yt-dlp"
    let cookieBrowserDefaultsKey = "NotchDropCookieBrowser"
    var cookieBrowserChoice: String {
        get { UserDefaults.standard.string(forKey: cookieBrowserDefaultsKey) ?? "Sin cookies" }
        set { UserDefaults.standard.set(newValue, forKey: cookieBrowserDefaultsKey) }
    }
    // Maps the menu label to yt-dlp's own browser identifiers; nil means don't
    // pass the flag at all.
    var cookieBrowserArgument: String? {
        switch cookieBrowserChoice {
        case "Chrome": return "chrome"
        case "Safari": return "safari"
        case "Firefox": return "firefox"
        case "Brave": return "brave"
        case "Edge": return "edge"
        default: return nil
        }
    }

    @objc func onCookieBrowserChanged(_ sender: NSPopUpButton) {
        cookieBrowserChoice = sender.titleOfSelectedItem ?? "Sin cookies"
    }

    func downloaderStatusText() -> String {
        if let tool = MediaDownloader.locateTool() {
            return "Listo — usando \(tool.path). Las descargas van directo a Descargas."
        }
        return "Falta yt-dlp, que es lo que hace la descarga. Instálalo con: \(Self.ytDlpInstallCommand)"
    }

    @objc func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.ytDlpInstallCommand, forType: .string)
        lastPBCount = NSPasteboard.general.changeCount
        downloaderStatusLabel?.stringValue = "Comando copiado — pégalo en Terminal."
    }

    @objc func openDownloadsFolder() {
        let dir = MediaDownloader.destinationDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc func retryAudioAccess() {
        audioMeter.retryAfterFailure()
        audioMeter.start(for: targetScreen)
        audioStatusLabel?.stringValue = audioStatusText()
    }

    @objc func replayOnboarding() {
        UserDefaults.standard.set(false, forKey: onboardingDefaultsKey)
        startOnboarding()
    }

    // MARK: Update checks

    func scheduleUpdateChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.maybeAutoCheckForUpdates() }
        // An hourly tick that only acts once a day survives sleep better than a single 24 h timer.
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.maybeAutoCheckForUpdates()
        }
    }

    func maybeAutoCheckForUpdates() {
        guard autoUpdateEnabled, !isInstallingUpdate else { return }
        let last = UserDefaults.standard.double(forKey: lastUpdateCheckDefaultsKey)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool) {
        if userInitiated { updateStatusLabel?.stringValue = "Buscando…" }
        UpdateFeed.fetchLatest { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let rel) where UpdateVersion.isNewer(rel.version, than: self.currentVersion):
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastUpdateCheckDefaultsKey)
                self.availableUpdate = rel
                self.updateStatusLabel?.stringValue = "Versión \(rel.version) disponible (tienes \(self.currentVersion))"
                self.updateActionBtn?.title = "Actualizar"
                if !userInitiated, UserDefaults.standard.string(forKey: self.notifiedUpdateVersionDefaultsKey) != rel.version {
                    UserDefaults.standard.set(rel.version, forKey: self.notifiedUpdateVersionDefaultsKey)
                    self.postUpdateNotification(rel.version)
                }
            case .success:
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastUpdateCheckDefaultsKey)
                self.availableUpdate = nil
                if userInitiated { self.updateStatusLabel?.stringValue = "Tienes la última versión (\(self.currentVersion))" }
            case .failure(let e):
                // A failed background check stays silent and is retried on the next hourly tick.
                if userInitiated { self.updateStatusLabel?.stringValue = e.message }
            }
        }
    }

    @objc func updateButtonPressed() {
        guard let rel = availableUpdate else { checkForUpdates(userInitiated: true); return }
        guard !isInstallingUpdate else { return }
        isInstallingUpdate = true
        updateActionBtn.isEnabled = false
        updateStatusLabel.stringValue = "Descargando y verificando \(rel.version)…"
        UpdateInstaller.install(rel, currentApp: Bundle.main.bundleURL,
                                expectedBundleID: Bundle.main.bundleIdentifier ?? "com.marcelo.notchdrop") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let app):
                self.updateStatusLabel.stringValue = "Listo. Reiniciando…"
                UpdateInstaller.relaunch(app)
            case .failure(let e):
                self.isInstallingUpdate = false
                self.updateActionBtn.isEnabled = true
                self.updateStatusLabel.stringValue = e.message
            }
        }
    }

    @objc func toggleAutoUpdate(_ sender: NSSwitch) { autoUpdateEnabled = sender.state == .on }

    func postUpdateNotification(_ version: String) {
        let content = UNMutableNotificationContent()
        content.title = "NotchDrop \(version) disponible"
        content.body = "Abre Ajustes en el notch y pulsa Actualizar."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: updateNotificationID, content: content, trigger: nil))
    }

    func fallBackToDirectMediaRemote() {
        NSLog("NotchDrop: media bridge unavailable — falling back to direct MediaRemote")
        usesMediaBridge = false
        loadMediaRemote()
        mrRegisterNotifs?(DispatchQueue.main)
    }

    @objc func quitApp() {
        // The loud repeating alarm sound only exists as long as this process is
        // running (it's an in-app Timer, not something the OS keeps going on its
        // own) — the scheduled system notification still fires after quitting, but
        // silently. Someone quitting to save battery shouldn't lose their alarm
        // without knowing that's what just happened.
        guard alarmEnd != nil || alarmRingTimer != nil else {
            NSApp.terminate(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "¿Salir con una alarma activa?"
        alert.informativeText = "Si cierras NotchDrop ahora, la alarma ya no sonará en loop — solo el aviso silencioso del sistema a la hora programada."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Salir de todos modos")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    // ── Onboarding Tour ──
    func maybeStartOnboarding() {
        guard !UserDefaults.standard.bool(forKey: onboardingDefaultsKey) else { return }
        // Mark it seen as soon as it is shown. The flag used to be written only if
        // the user clicked all the way through or pressed Saltar — but collapsing
        // the panel tears the overlay down without setting it, so on a hover-to-open
        // UI the tour reappeared on literally every open, dozens of times an hour.
        UserDefaults.standard.set(true, forKey: onboardingDefaultsKey)
        startOnboarding()
    }

    func startOnboarding() {
        onboardingSteps = [
            (target: { [weak self] in self?.nooksTabBtn }, title: "Tus pestañas",
             text: "Cambia entre Reproductor, Shelf, Tools y Notes desde aquí arriba."),
            (target: { [weak self] in self?.trayTabBtn }, title: "Shelf de archivos",
             text: "Arrastra archivos al notch en cualquier momento para guardarlos aquí temporalmente."),
            (target: { [weak self] in self?.settingsBtn }, title: "Ajustes",
             text: "Activa el auto-inicio, desactiva la apertura por hover si te resulta molesta, y más."),
        ]
        onboardingIndex = 0
        showOnboardingStep()
    }

    func showOnboardingStep() {
        onboardingOverlay?.removeFromSuperview()
        onboardingOverlay = nil
        guard onboardingIndex < onboardingSteps.count else {
            UserDefaults.standard.set(true, forKey: onboardingDefaultsKey)
            return
        }
        let step = onboardingSteps[onboardingIndex]
        guard let target = step.target(), target.superview != nil, !target.isHidden else {
            onboardingIndex += 1
            showOnboardingStep()
            return
        }

        let overlay = OnboardingOverlayView(frame: expandedBox.bounds)
        overlay.autoresizingMask = [.width, .height]
        let targetFrame = target.convert(target.bounds, to: expandedBox)
        overlay.holeRect = targetFrame.insetBy(dx: -8, dy: -6)
        expandedBox.addSubview(overlay)
        onboardingOverlay = overlay

        let callout = NSView(); callout.wantsLayer = true
        callout.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        callout.layer?.cornerRadius = 12
        callout.layer?.cornerCurve = .continuous
        callout.layer?.borderWidth = 1; callout.layer?.borderColor = C.pillBorder.cgColor
        callout.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = lbl(step.title, 13, .bold, .white)
        let textLbl = lbl(step.text, 11, .regular, C.textSecondary)
        textLbl.maximumNumberOfLines = 3
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        textLbl.translatesAutoresizingMaskIntoConstraints = false

        let isLast = onboardingIndex == onboardingSteps.count - 1
        let nextBtn = NSButton(title: isLast ? "Entendido" : "Siguiente", target: self, action: #selector(onboardingNext))
        nextBtn.bezelStyle = .rounded; nextBtn.controlSize = .small
        nextBtn.translatesAutoresizingMaskIntoConstraints = false
        let skipBtn = NSButton(title: "Saltar", target: self, action: #selector(onboardingSkip))
        skipBtn.bezelStyle = .inline; skipBtn.isBordered = false; skipBtn.contentTintColor = C.textMuted
        skipBtn.translatesAutoresizingMaskIntoConstraints = false

        callout.addSubview(titleLbl); callout.addSubview(textLbl); callout.addSubview(skipBtn); callout.addSubview(nextBtn)
        overlay.addSubview(callout)

        // Anchored to the target view directly — Auto Layout resolves this across
        // the shared expandedBox ancestor, so no manual coordinate-space math is
        // needed. The centerX pull is lower priority than the edge clamps, so a
        // target near the panel's edge (e.g. the settings gear) pushes the callout
        // back inside instead of producing an unsatisfiable constraint.
        let centerXc = callout.centerXAnchor.constraint(equalTo: target.centerXAnchor)
        centerXc.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centerXc,
            callout.topAnchor.constraint(equalTo: target.bottomAnchor, constant: 14),
            callout.widthAnchor.constraint(equalToConstant: 230),
            callout.leadingAnchor.constraint(greaterThanOrEqualTo: expandedBox.leadingAnchor, constant: 8),
            callout.trailingAnchor.constraint(lessThanOrEqualTo: expandedBox.trailingAnchor, constant: -8),

            titleLbl.topAnchor.constraint(equalTo: callout.topAnchor, constant: 14),
            titleLbl.leadingAnchor.constraint(equalTo: callout.leadingAnchor, constant: 14),
            titleLbl.trailingAnchor.constraint(equalTo: callout.trailingAnchor, constant: -14),
            textLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 6),
            textLbl.leadingAnchor.constraint(equalTo: callout.leadingAnchor, constant: 14),
            textLbl.trailingAnchor.constraint(equalTo: callout.trailingAnchor, constant: -14),
            skipBtn.leadingAnchor.constraint(equalTo: callout.leadingAnchor, constant: 14),
            skipBtn.topAnchor.constraint(equalTo: textLbl.bottomAnchor, constant: 12),
            skipBtn.bottomAnchor.constraint(equalTo: callout.bottomAnchor, constant: -12),
            nextBtn.trailingAnchor.constraint(equalTo: callout.trailingAnchor, constant: -14),
            nextBtn.centerYAnchor.constraint(equalTo: skipBtn.centerYAnchor),
        ])
    }

    @objc func onboardingNext() {
        onboardingIndex += 1
        showOnboardingStep()
    }
    @objc func onboardingSkip() {
        onboardingOverlay?.removeFromSuperview()
        onboardingOverlay = nil
        UserDefaults.standard.set(true, forKey: onboardingDefaultsKey)
    }

    func colorTitle(for button: NSButton, color: NSColor, weight: NSFont.Weight) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let attr = NSAttributedString(string: button.title, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 13, weight: weight),
            .paragraphStyle: p
        ])
        button.attributedTitle = attr
    }

        @objc func switchTab(_ sender: NSButton) {
        nooksTabBtn.contentTintColor = (sender.tag == 0) ? .white : C.textMuted
        trayTabBtn.contentTintColor = (sender.tag == 1) ? .white : C.textMuted
        toolsTabBtn.contentTintColor = (sender.tag == 2) ? .white : C.textMuted
        notesTabBtn.contentTintColor = (sender.tag == 3) ? .white : C.textMuted
        convertTabBtn.contentTintColor = (sender.tag == 4) ? .white : C.textMuted
        currencyTabBtn.contentTintColor = (sender.tag == 5) ? .white : C.textMuted
        settingsBtn.contentTintColor = C.textMuted

        nookContainer.isHidden = (sender.tag != 0)
        trayContainer.isHidden = (sender.tag != 1)
        toolsContainer.isHidden = (sender.tag != 2)
        notesContainer.isHidden = (sender.tag != 3)
        convertContainer.isHidden = (sender.tag != 4)
        currencyContainer.isHidden = (sender.tag != 5)
        settingsContainer.isHidden = true
        selectedTabButton = sender
        fitTabBar()

        // Opening the Shelf right after copying a link is the whole workflow, so
        // offer the clipboard contents instead of making the user paste manually.
        if sender.tag == 1, downloadField?.stringValue.isEmpty == true, !isDownloading,
           let copied = NSPasteboard.general.string(forType: .string),
           MediaDownloader.isSupportedLink(copied) {
            downloadField.stringValue = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @objc func openSettings() {
        nooksTabBtn.contentTintColor = C.textMuted
        trayTabBtn.contentTintColor = C.textMuted
        toolsTabBtn.contentTintColor = C.textMuted
        notesTabBtn.contentTintColor = C.textMuted
        convertTabBtn.contentTintColor = C.textMuted
        currencyTabBtn.contentTintColor = C.textMuted
        settingsBtn.contentTintColor = .white

        nookContainer.isHidden = true
        trayContainer.isHidden = true
        toolsContainer.isHidden = true
        notesContainer.isHidden = true
        convertContainer.isHidden = true
        currencyContainer.isHidden = true
        settingsContainer.isHidden = false
        selectedTabButton = nil
        fitTabBar()
        audioStatusLabel?.stringValue = audioStatusText()
        notchDiagnosticLabel?.stringValue = notchDiagnosticText()
        downloaderStatusLabel?.stringValue = downloaderStatusText()
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Expand / Collapse
    // ═══════════════════════════════════════════════════════════════════

    // Deliberate user actions — the two places haptic feedback is wanted.
    @objc func toggleExpandedState() {
        if isExpanded { collapsePanel(withHaptic: true); return }
        expandPanel(withHaptic: true)
        // Only the ⌥⌘N hotkey reaches here. expandPanel resets the flag, so set it after.
        if isExpanded { openedByKeyboard = true; pointerEnteredSinceKeyboardOpen = false }
    }
    @objc func collapsedBoxClicked() {
        guard !isExpanded, !isTransitioning else { return }
        expandPanel(withHaptic: true)
    }
    // `withHaptic` defaults to OFF and must be opted into by deliberate user
    // actions only (clicking the pill, the ⌥⌘N hotkey). It used to fire
    // unconditionally, which meant hover-to-open actuated the Force Touch
    // trackpad's haptic engine just from moving the cursor over the notch —
    // indistinguishable from a phantom click, sound and all.
    func expandPanel(forFileDrop: Bool = false, withHaptic: Bool = false) {
        guard !isExpanded, !isTransitioning else { return }
        openedByKeyboard = false; pointerEnteredSinceKeyboardOpen = false
        // A no-op on anything without a Force Touch trackpad (external mouse,
        // older trackpads) — safe to call unconditionally.
        if withHaptic {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        isExpanded = true; collapsedBox.isHidden = true; expandedBox.isHidden = false; expandedBox.alphaValue = 0
        let tr = getPanelRect(expanded: true)
        if forFileDrop {
            islandArtWindow?.orderOut(nil); islandWaveWindow?.orderOut(nil)
            panel.setFrame(tr, display: true)
            expandedBox.alphaValue = 1
            expandedBox.layer?.cornerRadius = 24
        } else {
            isTransitioning = true
            let duration = 0.38
            // A gentle overshoot-then-settle curve, not a flat ease — approximates
            // the spring feel of the real Dynamic Island opening. Kept modest
            // (rather than a full "ease-out-back") since this animates the actual
            // window frame with Auto-Layout-driven content inside it, and a bigger
            // overshoot would make that content visibly reflow/stretch mid-bounce.
            let timing = CAMediaTimingFunction(controlPoints: 0.32, 1.2, 0.55, 1.0)
            // The corner radius starts near the collapsed notch's own rounding and
            // grows into the panel's, in step with the frame — an unfurl, rather
            // than a fixed-corner rectangle that just happens to resize.
            animateCornerRadius(from: 12, to: 24, duration: duration, timingFunction: timing)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = timing
                panel.animator().setFrame(tr, display: true)
                expandedBox.animator().alphaValue = 1
                // Fade the compact pills out as the panel grows instead of vanishing
                // instantly, so it reads as them merging into the bigger shape.
                islandArtWindow?.animator().alphaValue = 0
                islandWaveWindow?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.isTransitioning = false
                self.panel.setFrame(self.getPanelRect(expanded: true), display: true)
                self.islandArtWindow?.orderOut(nil); self.islandWaveWindow?.orderOut(nil)
                self.islandArtWindow?.alphaValue = 1; self.islandWaveWindow?.alphaValue = 1
                self.maybeStartOnboarding()
            })
        }
        globalClickMon = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.collapsePanel() }
    }
    // Same opt-in rule as expandPanel: auto-collapse (mouse moved away, screen
    // changed, clicked elsewhere) must stay silent.
    func collapsePanel(withHaptic: Bool = false) {
        guard isExpanded, !isTransitioning else { return }
        openedByKeyboard = false; pointerEnteredSinceKeyboardOpen = false
        if withHaptic {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        isExpanded = false; if let m = globalClickMon { NSEvent.removeMonitor(m); globalClickMon = nil }
        if mirrorActive { stopMirrorCamera() }
        onboardingOverlay?.removeFromSuperview(); onboardingOverlay = nil
        let tr = getPanelRect(expanded: false)
        isTransitioning = true

        // Only bring back whichever pills should actually be showing right now
        // (mirrors the same checks updateUI() makes below), so nothing flashes
        // in only to be immediately hidden again once updateUI() runs.
        let showArt = track.isActive && track.isPlaying && !track.title.isEmpty
        let showWave = systemAudioIsAudible
        if showArt { islandArtWindow?.alphaValue = 0; islandArtWindow?.orderFrontRegardless() }
        if showWave { islandWaveWindow?.alphaValue = 0; islandWaveWindow?.orderFrontRegardless() }

        let duration = 0.3
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        animateCornerRadius(from: 24, to: 12, duration: duration, timingFunction: timing)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = timing
            panel.animator().setFrame(tr, display: true)
            expandedBox.animator().alphaValue = 0
            if showArt { islandArtWindow?.animator().alphaValue = 1 }
            if showWave { islandWaveWindow?.animator().alphaValue = 1 }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.setFrame(self.getPanelRect(expanded: false), display: true)
            self.expandedBox.isHidden = true
            self.collapsedBox.isHidden = false
            // Release focus, or checkAutoCollapse's "don't interrupt typing" guard
            // stays true forever after the first use of Notes or the link field.
            self.panel.makeFirstResponder(nil)
            self.isTransitioning = false
            self.updateUI()
        })
    }

    // Animates the panel's corner radius alongside its frame. CALayer properties
    // like cornerRadius aren't covered by NSAnimationContext's `.animator()`
    // proxy the way a view's frame/alpha are, so this needs its own explicit
    // CABasicAnimation sharing the same duration and timing curve.
    func animateCornerRadius(from: CGFloat, to: CGFloat, duration: CFTimeInterval, timingFunction: CAMediaTimingFunction) {
        guard let layer = expandedBox.layer else { return }
        let anim = CABasicAnimation(keyPath: "cornerRadius")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.timingFunction = timingFunction
        layer.add(anim, forKey: "cornerRadiusMorph")
        layer.cornerRadius = to
    }

    // (Removed) A transform.scale-based squash used to run here. It scaled around
    // the layer's anchor point, which for a layer-backed NSView is not reliably
    // the center — so it read as the panel lurching toward one side rather than
    // breathing symmetrically. The corner-radius morph plus the center-outward
    // reveal carry the motion without that risk.

    func normalizePanelFrame() {
        guard panel != nil, !isTransitioning else { return }
        let expected = getPanelRect(expanded: isExpanded)
        let current = panel.frame
        let tolerance: CGFloat = 1
        if abs(current.minX - expected.minX) > tolerance || abs(current.minY - expected.minY) > tolerance ||
            abs(current.width - expected.width) > tolerance || abs(current.height - expected.height) > tolerance {
            panel.setFrame(expected, display: true)
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - System Now Playing & Controls
    // ═══════════════════════════════════════════════════════════════════

    func startPollingLoop() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // If permission was enabled while the app was already open, this
            // starts ScreenCaptureKit automatically. start() is idempotent and
            // rate-limited, and never asks macOS to display a permission dialog.
            self.audioMeter.start(for: self.targetScreen)
            self.poll(); self.pollClip(); self.normalizePanelFrame(); self.checkAutoCollapse(); self.syncVolumeUI()
        }
        poll()
        syncVolumeUI()
    }

    // The mouse-leave collapse in the hover handler only fires on an actual
    // .mouseMoved event. If the panel gets expanded and the cursor then goes
    // still — the exact case of clicking elsewhere and typing without touching
    // the mouse again — no more move events arrive, so that check never runs
    // and the panel is stuck open indefinitely. Piggybacking a check on the
    // existing 1s poll tick closes that gap regardless of mouse activity.
    func checkAutoCollapse() {
        guard isExpanded, !isTransitioning, !isReceivingFileDrag else { return }
        // Don't pull the panel out from under someone actively typing in it
        // (e.g. the Notes tab) just because their cursor happens to be resting
        // outside the panel.
        if let responder = panel.firstResponder as? NSView, responder.isDescendant(of: expandedBox) { return }
        let expandedRect = getPanelRect(expanded: true)
        let paddedRect = expandedRect.insetBy(dx: -10, dy: -10)
        let d = AutoCollapsePolicy.decide(pointer: NSEvent.mouseLocation, paddedRect: paddedRect,
                                          keyboardOpened: openedByKeyboard, hasEntered: pointerEnteredSinceKeyboardOpen)
        pointerEnteredSinceKeyboardOpen = d.hasEntered
        if d.collapse { collapsePanel() }
    }

    func poll() {
        if usesMediaBridge {
            if track.isPlaying && track.duration > 0 {
                track.position = min(track.position + 1, track.duration)
            }
            // The Spotify/Netflix fallbacks each shell out to osascript, which loads
            // AppleScript + Cocoa fresh per call. Running that every single second,
            // indefinitely, for the whole time NotchDrop is open is the main sustained
            // CPU/process-churn cost in the app — throttling to every third tick (~3s)
            // keeps Now Playing responsive while cutting that spawn rate by two-thirds.
            fallbackPollTick += 1
            if fallbackPollTick % 3 == 0 {
                if !track.isActive || usingSpotifyFallback { pollSpotifyFallback() }
                if !track.isPlaying || usingNetflixFallback { pollNetflixFallback() }
            }
            updateUI()
            return
        }
        guard let getNP = mrGetNowPlaying else { return }
        getNP(DispatchQueue.main) { [weak self] dict in
            guard let self = self else { return }
            var t = TrackInfo()
            if let title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty {
                t.title = title
                t.artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
                t.album = dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
                t.duration = dict["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
                t.position = dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
                let rate = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
                t.isPlaying = rate > 0
                t.artworkData = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
                t.isActive = true
            }
            self.track = t; self.updateUI()
        }
    }

    static func parseLocaleNumber(_ raw: String) -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(trimmed) { return direct }
        // Fall back to swapping a decimal comma for a period.
        if let swapped = Double(trimmed.replacingOccurrences(of: ",", with: ".")) { return swapped }
        return 0
    }

    func pollSpotifyFallback() {
        let bundleID = "com.spotify.client"
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            if usingSpotifyFallback {
                usingSpotifyFallback = false
                track = TrackInfo()
                cachedArtImage = nil
                spotifyArtworkData = nil
                spotifyArtworkURL = ""
                updateUI()
            }
            return
        }
        guard !isSpotifyPolling else { return }
        isSpotifyPolling = true
        // Read the cached artwork on the main thread and hand the values into the
        // background block. Reading `self.spotifyArtwork*` from inside that block
        // meant a background thread was reading properties the main thread writes
        // to — an actual data race on a Data/String, not just a style issue.
        let cachedArtworkData = spotifyArtworkData
        let cachedArtworkURL = spotifyArtworkURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let script = """
            tell application "Spotify"
                if player state is playing or player state is paused then
                    return (name of current track) & "||" & (artist of current track) & "||" & (album of current track) & "||" & (artwork url of current track) & "||" & (player state as string) & "||" & (player position) & "||" & ((duration of current track) / 1000)
                end if
            end tell
            """
            let result = self.runScriptOut(script) ?? ""
            let parts = result.components(separatedBy: "||")
            // A paused Spotify session is stale metadata, not Now Playing.
            // Check this before touching the network so paused artwork is not
            // downloaded again on every poll.
            guard parts.count >= 7, parts[4] == "playing" else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isSpotifyPolling = false
                    if self.usingSpotifyFallback {
                        self.usingSpotifyFallback = false
                        self.track = TrackInfo()
                        self.cachedArtImage = nil
                        self.lastArtworkHash = 0
                        self.updateUI()
                    }
                }
                return
            }
            var artwork = cachedArtworkData
            let urlString = parts[3]
            if urlString != cachedArtworkURL, let url = URL(string: urlString) {
                artwork = self.downloadWithTimeout(url)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSpotifyPolling = false
                guard parts.count >= 7,
                      !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return }
                var spotifyTrack = TrackInfo()
                spotifyTrack.title = parts[0]
                spotifyTrack.artist = parts[1]
                spotifyTrack.album = parts[2]
                spotifyTrack.isPlaying = true
                // AppleScript formats reals with the SYSTEM decimal separator, so on a
                // Spanish-locale Mac these arrive as "123,456" and Double() returns nil —
                // which silently zeroed position and duration, killing the progress bar
                // and making seek refuse to run (it requires duration > 0).
                spotifyTrack.position = Self.parseLocaleNumber(parts[5])
                spotifyTrack.duration = Self.parseLocaleNumber(parts[6])
                spotifyTrack.artworkData = artwork
                spotifyTrack.isActive = !spotifyTrack.title.isEmpty
                self.spotifyArtworkURL = parts[3]
                self.spotifyArtworkData = artwork
                self.usingSpotifyFallback = spotifyTrack.isActive
                self.track = spotifyTrack
                self.updateUI()
            }
        }
    }

    func pollNetflixFallback() {
        let chromeBundleID = "com.google.Chrome"
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID).isEmpty else {
            if usingNetflixFallback {
                usingNetflixFallback = false
                track = TrackInfo()
                cachedArtImage = nil
                lastArtworkHash = 0
                updateUI()
            }
            return
        }
        guard !isNetflixPolling else { return }
        isNetflixPolling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let script = """
            tell application "Google Chrome"
                repeat with browserWindow in windows
                    repeat with browserTab in tabs of browserWindow
                        if URL of browserTab contains "netflix.com/watch" then
                            return (title of browserTab) & "||" & (URL of browserTab)
                        end if
                    end repeat
                end repeat
            end tell
            """
            let result = self.runScriptOut(script) ?? ""
            let hasNetflixPlayer = result.contains("||")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isNetflixPolling = false
                if hasNetflixPlayer && self.systemAudioIsAudible && !self.usingSpotifyFallback {
                    var netflixTrack = TrackInfo()
                    netflixTrack.title = "Netflix"
                    netflixTrack.artist = "Google Chrome"
                    netflixTrack.album = "Now Playing"
                    netflixTrack.isPlaying = true
                    netflixTrack.isActive = true
                    netflixTrack.artworkData = NSWorkspace.shared.icon(forFile: "/Applications/Google Chrome.app").tiffRepresentation
                    self.usingNetflixFallback = true
                    self.track = netflixTrack
                    self.updateUI()
                } else if self.usingNetflixFallback && (!hasNetflixPlayer || !self.systemAudioIsAudible) {
                    self.usingNetflixFallback = false
                    self.track = TrackInfo()
                    self.cachedArtImage = nil
                    self.lastArtworkHash = 0
                    self.updateUI()
                }
            }
        }
    }

    func handleMediaPayload(notificationName: String, payload: [String: Any]) {
        if let state = payload["playbackState"] as? NSNumber {
            track.isPlaying = state.intValue == 1
            updateUI()
            return
        }
        guard notificationName.contains("NowPlayingInfoDidChange") else { return }
        guard let title = payload["title"] as? String, !title.isEmpty else {
            if !usingSpotifyFallback && !usingNetflixFallback {
                track = TrackInfo()
                cachedArtImage = nil
                lastArtworkHash = 0
                updateUI()
            }
            return
        }

        var next = TrackInfo()
        next.title = title
        next.artist = payload["artist"] as? String ?? ""
        next.album = payload["album"] as? String ?? ""
        next.duration = (payload["durationMicros"] as? NSNumber)?.doubleValue ?? 0
        next.duration /= 1_000_000
        next.position = (payload["elapsedTimeMicros"] as? NSNumber)?.doubleValue ?? 0
        next.position /= 1_000_000
        if let playing = payload["isPlaying"] as? Bool {
            next.isPlaying = playing
        } else {
            next.isPlaying = (payload["isPlaying"] as? NSNumber)?.boolValue ?? false
        }
        if let base64 = payload["artworkDataBase64"] as? String {
            next.artworkData = Data(base64Encoded: base64)
        }
        next.isActive = true
        usingSpotifyFallback = false
        usingNetflixFallback = false
        track = next
        updateUI()
    }
    func formatTime(_ time: Double) -> String {
        guard !time.isNaN && time >= 0 else { return "0:00" }
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    func updateUI() {
        if track.isActive && !track.title.isEmpty {
            npTitleLabel?.stringValue = track.title
            let sub = [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " • ")
            npArtistLabel?.stringValue = sub.isEmpty ? "Unknown" : sub
            let playSymbol = track.isPlaying ? "pause.fill" : "play.fill"
            if playSymbol != lastPlayBtnSymbol {
                lastPlayBtnSymbol = playSymbol
                npPlayBtn?.image = NSImage(systemSymbolName: playSymbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .bold))
            }
            
            if track.duration > 0 {
                if progressSlider?.isHighlighted == false {
                    progressSlider?.doubleValue = (track.position / track.duration) * 100
                }
                progressTimeLabel?.stringValue = formatTime(track.position)
                progressRemainLabel?.stringValue = "-" + formatTime(track.duration - track.position)
            }
            
            // Update artwork if changed
            let newHash = track.artworkData?.hashValue ?? 0
            if newHash != lastArtworkHash, let data = track.artworkData, let img = NSImage(data: data) {
                lastArtworkHash = newHash
                cachedArtImage = img
                artImageView?.image = img; artImageView?.contentTintColor = nil
                if !isExpanded { islandArtView?.image = img }
            } else if track.artworkData == nil, lastArtworkHash != 0 {
                // Going from a track WITH artwork to one without used to leave the
                // previous cover on screen, so a podcast showed the last song's art.
                lastArtworkHash = 0
                cachedArtImage = nil
                artImageView?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
                artImageView?.contentTintColor = C.textMuted
                islandArtView?.image = nil
            }
        } else {
            npTitleLabel?.stringValue = "No Music"
            npArtistLabel?.stringValue = "Play something on any app"
            artImageView?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            artImageView?.contentTintColor = C.textMuted
            progressTimeLabel?.stringValue = "0:00"
            progressRemainLabel?.stringValue = "-0:00"
            progressSlider?.doubleValue = 0
        }
        
        // Album art only represents a session that is actively playing.
        let showArtwork = track.isActive && track.isPlaying && !track.title.isEmpty && !isExpanded
        if showArtwork {
            islandArtView?.image = cachedArtImage
            islandArtWindow?.orderFrontRegardless()
        } else {
            islandArtWindow?.orderOut(nil)
        }

        // The right capsule normally follows actual system audio amplitude,
        // independently from whichever app supplied (or failed to supply) Now
        // Playing metadata — but an active alarm takes over that same pill (an
        // armed/ringing alarm is rarer and more actionable than a live waveform,
        // so it wins the shared slot) rather than adding a third window.
        let hasActiveAlarm = alarmIsShowing
        let showLiveAudio = systemAudioIsAudible && !isExpanded && !hasActiveAlarm
        // The right pill changes width when it switches between waveform and
        // countdown, so its window has to be re-framed on that transition —
        // only on the transition, not every tick.
        if hasActiveAlarm != lastAlarmPillState {
            lastAlarmPillState = hasActiveAlarm
            repositionIslandWindows()
        }
        if hasActiveAlarm {
            islandWaveView?.isHidden = true
            islandAlarmLabel?.isHidden = false
            islandWaveWindow?.orderFrontRegardless()
        } else if showLiveAudio {
            islandWaveView?.isHidden = false
            islandAlarmLabel?.isHidden = true
            islandWaveWindow?.orderFrontRegardless()
        } else {
            islandWaveWindow?.orderOut(nil)
        }
    }

    @objc func playPauseTrack() {
        if usingSpotifyFallback { sendSpotifyCommand("playpause") }
        else if usesMediaBridge { mediaBridge.send("toggle_play_pause") }
        else { _ = mrSendCommand?(MRCommand.togglePlayPause.rawValue, nil) }
    }
    @objc func nextTrack() {
        if usingSpotifyFallback { sendSpotifyCommand("next track") }
        else if usesMediaBridge { mediaBridge.send("next_track") }
        else { _ = mrSendCommand?(MRCommand.nextTrack.rawValue, nil) }
    }
    @objc func prevTrack() {
        if usingSpotifyFallback { sendSpotifyCommand("previous track") }
        else if usesMediaBridge { mediaBridge.send("previous_track") }
        else { _ = mrSendCommand?(MRCommand.previousTrack.rawValue, nil) }
    }
    func sendSpotifyCommand(_ command: String) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runScriptOut("tell application \"Spotify\" to \(command)")
        }
    }
    // Was a deliberate no-op, so dragging the progress bar moved the knob and then
    // snapped back on the next poll — it looked interactive but could never seek.
    // The bundled adapter does expose a `set_time` command, and Spotify/MediaRemote
    // both have their own equivalents, so all three paths are wired up here.
    @objc func onScrubTrack(_ s: NSSlider) {
        guard track.isActive, track.duration > 0 else { return }
        seek(to: (s.doubleValue / 100) * track.duration)
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, track.duration))
        if usingSpotifyFallback {
            sendSpotifyCommand("set player position to \(String(format: "%.2f", target))")
        } else if usesMediaBridge {
            mediaBridge.send("set_time", argument: String(format: "%.3f", target))
        } else if let setElapsed = mrSetElapsedTime {
            setElapsed(target)
        } else {
            return // No seek path available for this source (e.g. the Netflix fallback).
        }
        // Move the UI immediately instead of waiting for the player to report back,
        // otherwise the knob visibly jumps back to the old spot for up to a second.
        track.position = target
        updateUI()
    }

    @objc func onVolumeSlider(_ s: NSSlider) {
        SystemVolume.setVolume(Float(s.doubleValue / 100))
        if SystemVolume.isMuted() && s.doubleValue > 0 { SystemVolume.setMuted(false) }
        updateVolumeIcon()
    }

    @objc func toggleSystemMute() {
        SystemVolume.setMuted(!SystemVolume.isMuted())
        updateVolumeIcon()
    }

    func updateVolumeIcon() {
        let muted = SystemVolume.isMuted()
        let level = SystemVolume.currentVolume() ?? 0
        let symbol = muted || level <= 0.01 ? "speaker.slash.fill"
            : level < 0.33 ? "speaker.wave.1.fill"
            : level < 0.66 ? "speaker.wave.2.fill"
            : "speaker.wave.3.fill"
        // Only rebuild the image when the symbol actually changes. This runs off
        // the 1s poll tick, so without the guard it allocated a fresh NSImage
        // every second for the entire life of the app — pure churn, and exactly
        // the kind of steady background cost worth avoiding here.
        guard symbol != lastVolumeSymbol else { return }
        lastVolumeSymbol = symbol
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        volumeIconBtn?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    // Keeps the slider truthful when volume changes from elsewhere (menu bar,
    // media keys, Control Center) — same "don't fight an active drag" guard the
    // song-position slider already uses.
    func syncVolumeUI() {
        guard volumeSlider?.isHighlighted == false else { return }
        guard let level = SystemVolume.currentVolume() else { return }
        volumeSlider?.doubleValue = Double(level * 100)
        updateVolumeIcon()
    }
    @objc func openAirPlayMenu() {
        // This was the one runScriptOut call still made directly from a button's
        // @objc action — i.e. on the main thread — so clicking it froze the UI for
        // however long osascript took to drive System Events. Every other remote
        // command already dispatches to a background queue; this just matches that.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runScriptOut("tell application \"System Events\" to tell process \"ControlCenter\" to click menu bar item \"Sound\" of menu bar 1")
        }
    }

    // Runs a script with the text passed as argv, so caller data never has to be
    // escaped into the script source. Returns whether osascript exited cleanly.
    @discardableResult
    func runScript(_ source: String, arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source, "--"] + arguments
        return runProcessBounded(p, timeout: 20).status == 0
    }

    @discardableResult
    func runScriptOut(_ s: String) -> String? {
        // Bounded at 15s. Apple Events have a two-minute default timeout, so a hung
        // Chrome or Spotify used to block this call — and its caller's polling flag —
        // for that long. It also read the pipe AFTER waitUntilExit, which deadlocks
        // outright once a script's output exceeds the pipe buffer.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", s]
        let result = runProcessBounded(p, timeout: 15)
        return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // pollSpotifyFallback() previously used `Data(contentsOf: url)` to fetch
    // artwork — a blocking call with no timeout. If the network hung, that call
    // never returned, `isSpotifyPolling` never reset, and since pollSpotifyFallback
    // guards on `!isSpotifyPolling`, Now Playing updates for Spotify would silently
    // stop forever until the app was relaunched. This bounds the wait explicitly.
    func downloadWithTimeout(_ url: URL, timeout: TimeInterval = 5) -> Data? {
        var result: Data?
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return result
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Mirror Camera
    // ═══════════════════════════════════════════════════════════════════

    @objc func toggleMirrorCamera() { if mirrorActive { stopMirrorCamera() } else { startMirrorCamera() } }
    func startMirrorCamera() {
        let s = AVCaptureSession(); s.sessionPreset = .medium
        guard let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front), let i = try? AVCaptureDeviceInput(device: d) else { return }
        s.addInput(i); let p = AVCaptureVideoPreviewLayer(session: s); p.videoGravity = .resizeAspectFill
        if let c = p.connection, c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = true }
        mirrorCamLayerContainer.wantsLayer = true; p.frame = NSRect(x: 0, y: 0, width: 110, height: 110); p.cornerRadius = 55
        mirrorCamLayerContainer.layer?.addSublayer(p)
        DispatchQueue.global().async { s.startRunning() }
        captureSession = s; previewLayer = p; mirrorActive = true; mirrorIconView.isHidden = true
    }
    func stopMirrorCamera() {
        captureSession?.stopRunning(); previewLayer?.removeFromSuperlayer()
        captureSession = nil; previewLayer = nil; mirrorActive = false; mirrorIconView.isHidden = false
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Tools: Alarms, Stopwatch, Clipboard
    // ═══════════════════════════════════════════════════════════════════

    func configureNativeNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Lets the alarm notification carry a "Detener" action button, so the
        // ringing can be silenced right from the banner — not just from inside
        // the app's own Tools tab.
        let stopAction = UNNotificationAction(identifier: "STOP_ALARM", title: "Detener", options: [.foreground])
        let alarmCategory = UNNotificationCategory(identifier: "ALARM_CATEGORY", actions: [stopAction], intentIdentifiers: [], options: [])
        center.setNotificationCategories([alarmCategory])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if !granted {
                    self.alarmStatusLabel?.stringValue = "Enable notifications to use native alarms"
                    self.alarmStatusLabel?.textColor = NSColor.systemRed
                }
            }
        }

        let defaults = UserDefaults.standard
        let timestamp = defaults.double(forKey: alarmDateDefaultsKey)
        guard timestamp > Date().timeIntervalSince1970 else {
            defaults.removeObject(forKey: alarmDateDefaultsKey)
            defaults.removeObject(forKey: alarmMinutesDefaultsKey)
            return
        }
        alarmEnd = Date(timeIntervalSince1970: timestamp)
        alarmMins = defaults.integer(forKey: alarmMinutesDefaultsKey)
        alarmTimer?.invalidate()
        alarmTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickAlarm() }
        alarmCancelBtn?.isHidden = false
        tickAlarm()
    }

    func scheduleNativeAlarm(minutes: Int, fireDate: Date) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "⏰ NotchDrop Alarm"
        content.body = minutes == 1 ? "Your alarm is ringing." : "Your \(minutes)-minute alarm is ringing."
        content.sound = .default
        content.categoryIdentifier = "ALARM_CATEGORY"
        // Lets the banner push through most Focus modes. A true bypass-everything
        // "critical alert" needs an entitlement Apple grants per-app on request —
        // not available to a local, ad-hoc-signed build like this one — so this is
        // the practical ceiling without going through App Store review.
        content.interruptionLevel = .timeSensitive
        // Driven by the exact target Date rather than a rounded minute count, so a
        // "set for 7:30" alarm doesn't drift by up to 59 seconds against the clock.
        let interval = max(1, fireDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: alarmNotificationID, content: content, trigger: trigger)
        center.removePendingNotificationRequests(withIdentifiers: [alarmNotificationID])
        center.add(request) { [weak self] error in
            guard let error, let self else { return }
            DispatchQueue.main.async {
                self.alarmStatusLabel.stringValue = "Could not schedule alarm: \(error.localizedDescription)"
                self.alarmStatusLabel.textColor = NSColor.systemRed
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Tapping the notification itself (default action) or its "Detener" button
    // both silence the ringing loop below.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == alarmNotificationID {
            DispatchQueue.main.async { [weak self] in self?.stopAlarmRinging() }
        } else if response.notification.request.identifier == updateNotificationID {
            DispatchQueue.main.async { [weak self] in
                self?.expandPanel(withHaptic: true)
                self?.openSettings()
            }
        }
        completionHandler()
    }

    // Shared by both the preset buttons and the specific-time picker.
    func activateAlarm(minutes: Int, end: Date) {
        stopAlarmRinging()
        alarmMins = minutes
        alarmEnd = end
        alarmTimer?.invalidate()
        alarmTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tickAlarm() }
        alarmCancelBtn?.title = "Cancelar"
        alarmCancelBtn?.isHidden = false
        UserDefaults.standard.set(end.timeIntervalSince1970, forKey: alarmDateDefaultsKey)
        UserDefaults.standard.set(minutes, forKey: alarmMinutesDefaultsKey)
        scheduleNativeAlarm(minutes: minutes, fireDate: end)
        tickAlarm()
    }

    @objc func setAlarmPreset(_ s: NSButton) {
        activateAlarm(minutes: s.tag, end: Date().addingTimeInterval(TimeInterval(s.tag * 60)))
    }

    // "Set for 7:30" — always the NEXT occurrence of that time, rolling to
    // tomorrow if that time of day has already passed today.
    @objc func setAlarmAtPickedTime() {
        guard let picker = alarmTimePicker else { return }
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute], from: picker.dateValue)
        guard let target = calendar.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime) else { return }
        let minutes = max(1, Int((target.timeIntervalSinceNow / 60.0).rounded()))
        activateAlarm(minutes: minutes, end: target)
    }

    @objc func cancelAlarm() {
        // While ringing, this same button reads "Detener" — route to the silencer.
        guard alarmRingTimer == nil else { stopAlarmRinging(); return }
        alarmTimer?.invalidate(); alarmTimer = nil
        alarmEnd = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [alarmNotificationID])
        UserDefaults.standard.removeObject(forKey: alarmDateDefaultsKey)
        UserDefaults.standard.removeObject(forKey: alarmMinutesDefaultsKey)
        alarmStatusLabel.stringValue = "Sin alarma activa"
        alarmStatusLabel.textColor = C.textMuted
        alarmCancelBtn?.isHidden = true
        updateUI()
    }

    func tickAlarm() {
        guard let e = alarmEnd else { return }
        let r = e.timeIntervalSinceNow
        if r <= 0 {
            alarmTimer?.invalidate(); alarmTimer = nil; alarmEnd = nil
            UserDefaults.standard.removeObject(forKey: alarmDateDefaultsKey)
            UserDefaults.standard.removeObject(forKey: alarmMinutesDefaultsKey)
            startAlarmRinging()
            return
        }
        let formatter = DateFormatter(); formatter.dateFormat = "h:mm a"
        alarmStatusLabel.stringValue = String(format: "⏰ %02d:%02d restantes — suena a las %@", Int(r)/60, Int(r)%60, formatter.string(from: e))
        // The pill is only 34pt wide, so "59:59" would crowd or clip it. Above ten
        // minutes a coarse "59m" is both legible and enough at a glance; the exact
        // mm:ss only starts mattering near the end.
        let secondsLeft = Int(r)
        islandAlarmLabel?.stringValue = secondsLeft >= 600
            ? "\(secondsLeft / 60)m"
            : String(format: "%d:%02d", secondsLeft / 60, secondsLeft % 60)
        updateUI()
    }

    // Plays an actual repeating alarm tone (system notification sounds are a
    // single quiet ping, not a real alarm) until the user stops it — from the
    // in-app "Detener" button, the notification's own action, or tapping the
    // notification itself. Auto-stops after ~3 minutes so a missed alarm
    // doesn't ring forever in the background.
    func startAlarmRinging() {
        alarmStatusLabel.stringValue = "✅ ¡ALARMA! — sonando…"
        alarmStatusLabel.textColor = C.spotifyGreen
        alarmCancelBtn?.title = "Detener"
        alarmCancelBtn?.isHidden = false
        islandAlarmLabel?.stringValue = "🔔"
        updateUI()

        // A looping synthesized tone rather than a system beep replayed on a timer:
        // the old approach was audibly a notification going off repeatedly, with
        // dead silence in between, which is not what an alarm sounds like.
        alarmSound?.stop()
        alarmSound = AlarmTone.makeSound()
        alarmSound?.play()

        // Still bounded, so a missed alarm doesn't ring forever in the background.
        alarmRingTimer?.invalidate()
        alarmRingTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            self?.stopAlarmRinging()
        }
    }

    func stopAlarmRinging() {
        guard alarmRingTimer != nil || alarmSound != nil else { return }
        alarmRingTimer?.invalidate(); alarmRingTimer = nil
        alarmSound?.stop(); alarmSound = nil
        alarmCancelBtn?.title = "Cancelar"
        alarmCancelBtn?.isHidden = true
        alarmStatusLabel.stringValue = "Sin alarma activa"
        alarmStatusLabel.textColor = C.textMuted
        updateUI()
    }
    @objc func openClockApp() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Clock.app")) }

    @objc func toggleSw() {
        if swClock.isRunning {
            swClock.pause(at: Date()); swTimer?.invalidate(); swTimer = nil
            swStartBtn.title = "Start"
        } else {
            swClock.start(at: Date()); swStartBtn.title = "Pause"
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tickSw() }
            // .common so it keeps redrawing while a menu is open or the panel is being scrolled.
            RunLoop.main.add(t, forMode: .common)
            swTimer = t
        }
        tickSw()
    }
    func tickSw() { swDisplayLabel.stringValue = StopwatchClock.format(swClock.elapsed(at: Date())) }
    @objc func resetSw() {
        swClock.reset(); swTimer?.invalidate(); swTimer = nil
        swDisplayLabel.stringValue = "00:00.0"; swStartBtn.title = "Start"
    }

    // Types that mean "do not record this in clipboard history". Password managers
    // (1Password, Bitwarden, Keychain…) stamp copied credentials with these, and
    // every well-behaved clipboard manager honours them. Without this check a
    // copied password landed in NotchDrop's history and was rendered as plain,
    // readable text right there in the notch.
    static let concealedPasteboardTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
    ]

    // A single Retina screenshot can be many megabytes, so images are bounded on
    // two axes: nothing oversized is captured at all, and the total held across
    // the whole history is capped. Text costs effectively nothing by comparison.
    static let maxClipboardImageBytes = 12 * 1024 * 1024   // 12 MB per image
    static let maxClipboardTotalBytes = 30 * 1024 * 1024   // 30 MB across history
    static let maxClipboardItems = 12
    // How many rows show before the "Ver más" button appears. Kept separate from
    // the storage cap: more history is useful, but showing all of it at once in a
    // narrow panel is what made entries read as crowded/run-together.

    func pollClip() {
        let pb = NSPasteboard.general; guard pb.changeCount != lastPBCount else { return }; lastPBCount = pb.changeCount
        let declaredTypes = Set((pb.types ?? []).map(\.rawValue))
        guard declaredTypes.isDisjoint(with: Self.concealedPasteboardTypes) else { return }

        let item: ClipItem
        // Text wins when both are present: copying from a rich editor puts both on
        // the pasteboard, and the text is almost always what was meant.
        if let s = pb.string(forType: .string), !s.isEmpty {
            item = ClipItem(text: s)
        } else if let type = ClipItem.preferredImageType(on: pb), let data = pb.data(forType: type) {
            guard data.count <= Self.maxClipboardImageBytes else { return }
            item = ClipItem(imageData: data, type: type)
        } else {
            return
        }

        clipboard.removeAll { $0.isDuplicate(of: item) }
        clipboard.insert(item, at: 0)
        trimClipboard()
        persistClipboard()
        updateClipUI()
    }

    // ── Persistence ──
    // The Shelf and the clipboard history lived only in memory, so quitting the
    // app — or rebuilding it — silently threw both away with no warning.
    let shelfDefaultsKey = "NotchDropShelfFiles"
    let clipPersistDefaultsKey = "NotchDropPersistClipboard"
    let clipHistoryDefaultsKey = "NotchDropClipboardHistory"

    // Opt-in, default off: persisting clipboard text means writing what you copy
    // to disk, which is a real change in what this app leaves behind. The Shelf
    // stores only file paths, so that one persists unconditionally.
    var persistClipboardEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: clipPersistDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: clipPersistDefaultsKey) }
    }

    func persistShelf() {
        UserDefaults.standard.set(fileTrayBox?.files.map(\.path) ?? [], forKey: shelfDefaultsKey)
    }

    func restoreShelf() {
        guard let paths = UserDefaults.standard.stringArray(forKey: shelfDefaultsKey) else { return }
        let fm = FileManager.default
        // Drop entries whose file has since been moved or deleted, rather than
        // restoring a tile that points at nothing.
        fileTrayBox.files = paths.map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }
    }

    func persistClipboard() {
        guard persistClipboardEnabled else { return }
        // Text only — images would mean writing megabytes of screenshots to disk.
        let texts: [String] = clipboard.compactMap {
            if case .text(let s) = $0.kind { return s }
            return nil
        }
        UserDefaults.standard.set(Array(texts.prefix(Self.maxClipboardItems)), forKey: clipHistoryDefaultsKey)
    }

    func restoreClipboard() {
        guard persistClipboardEnabled,
              let texts = UserDefaults.standard.stringArray(forKey: clipHistoryDefaultsKey) else { return }
        clipboard = texts.map { ClipItem(text: $0) }
    }

    @objc func togglePersistClipboard(_ sender: NSSwitch) {
        persistClipboardEnabled = sender.state == .on
        if persistClipboardEnabled {
            persistClipboard()
        } else {
            // Turning it off should also remove whatever was already written.
            UserDefaults.standard.removeObject(forKey: clipHistoryDefaultsKey)
        }
    }

    func trimClipboard() {
        if clipboard.count > Self.maxClipboardItems {
            clipboard = Array(clipboard.prefix(Self.maxClipboardItems))
        }
        var running = 0
        clipboard = clipboard.filter { entry in
            // Only count what is actually kept — otherwise a dropped image still
            // pushed later entries over the cap.
            let projected = running + entry.byteCount
            if entry.isImage && projected > Self.maxClipboardTotalBytes { return false }
            running = projected
            return true
        }
    }
    func updateClipUI() {
        clipStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if clipboard.isEmpty {
            clipStackView.addArrangedSubview(lbl("Copia texto o una imagen para verlos aquí.", 10, .regular, C.textMuted))
            return
        }
        // Rendering every stored entry at once is what made rows read as crowded —
        // collapse to a handful up front, with a button to reveal the rest on demand.
        let visibleCount = clipboardExpanded ? clipboard.count : min(Self.clipVisibleCollapsed, clipboard.count)
        for (i, c) in clipboard.prefix(visibleCount).enumerated() {
            let r = NSView(); r.translatesAutoresizingMaskIntoConstraints = false
            let b = NSButton(title: "Copy", target: self, action: #selector(copyClip(_:)))
            b.tag = i; b.bezelStyle = .recessed; b.controlSize = .mini
            b.translatesAutoresizingMaskIntoConstraints = false
            // A long single-line entry (a URL, say) was compressing the button to
            // nothing, leaving that row with no way to copy it. The button keeps its
            // intrinsic size; the text truncates instead.
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            b.setContentHuggingPriority(.required, for: .horizontal)
            r.addSubview(b)

            // Rows stay the same fixed height whether they hold text or an image —
            // a thumbnail that grew the row would let one screenshot dominate the
            // whole panel.
            let leading: NSView
            switch c.kind {
            case .text(let s):
                let t = lbl(s, 10, .regular, C.textSecondary)
                t.maximumNumberOfLines = 1
                t.cell?.wraps = false
                t.cell?.isScrollable = false
                t.cell?.usesSingleLineMode = true
                t.setContentHuggingPriority(.required, for: .vertical)
                leading = t
            case .image(let data, _):
                let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
                let thumb = NSImageView()
                thumb.image = c.thumbnail
                thumb.imageScaling = .scaleProportionallyUpOrDown
                thumb.wantsLayer = true
                thumb.layer?.cornerRadius = 3
                thumb.layer?.cornerCurve = .continuous
                thumb.layer?.masksToBounds = true
                thumb.translatesAutoresizingMaskIntoConstraints = false
                let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                let caption = lbl("Imagen · \(size)", 10, .regular, C.textSecondary)
                caption.maximumNumberOfLines = 1
                caption.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(thumb); row.addSubview(caption)
                NSLayoutConstraint.activate([
                    thumb.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                    thumb.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    thumb.widthAnchor.constraint(equalToConstant: 26),
                    thumb.heightAnchor.constraint(equalToConstant: 18),
                    caption.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 8),
                    caption.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    caption.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
                ])
                leading = row
            }
            leading.translatesAutoresizingMaskIntoConstraints = false
            leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            r.addSubview(leading)
            NSLayoutConstraint.activate([
                leading.leadingAnchor.constraint(equalTo: r.leadingAnchor),
                leading.centerYAnchor.constraint(equalTo: r.centerYAnchor),
                leading.trailingAnchor.constraint(lessThanOrEqualTo: b.leadingAnchor, constant: -8),
                b.trailingAnchor.constraint(equalTo: r.trailingAnchor),
                b.centerYAnchor.constraint(equalTo: r.centerYAnchor),
                r.heightAnchor.constraint(equalToConstant: 22)
            ])
            clipStackView.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: clipStackView.widthAnchor).isActive = true
        }
        if clipboard.count > Self.clipVisibleCollapsed {
            let remaining = clipboard.count - visibleCount
            let title = clipboardExpanded ? "Ver menos" : "Ver más (\(remaining))"
            let toggle = NSButton(title: title, target: self, action: #selector(toggleClipExpanded))
            toggle.bezelStyle = .recessed; toggle.controlSize = .mini
            toggle.translatesAutoresizingMaskIntoConstraints = false
            clipStackView.addArrangedSubview(toggle)
            toggle.widthAnchor.constraint(equalTo: clipStackView.widthAnchor).isActive = true
        }
    }

    @objc func toggleClipExpanded() {
        clipboardExpanded.toggle()
        updateClipUI()
    }

    @objc func copyClip(_ sender: NSButton) {
        guard sender.tag < clipboard.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        switch clipboard[sender.tag].kind {
        case .text(let s):
            pb.setString(s, forType: .string)
        case .image(let data, let type):
            // Original bytes and original type — the thumbnail is display-only.
            pb.setData(data, forType: type)
        }
        lastPBCount = pb.changeCount
        sender.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now()+1) { sender.title = "Copy" }
    }

    // ── Notes Tab ──
    var notesTextView: NSTextView!
    func buildNotesTab() {
        let titleLbl = lbl("Apple Notes Quick Entry", 16, .bold, C.textPrimary)
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        notesContainer.addSubview(titleLbl)
        
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        
        notesTextView = NSTextView()
        notesTextView.font = .systemFont(ofSize: 14)
        notesTextView.textColor = .white
        notesTextView.backgroundColor = NSColor(white: 0.15, alpha: 1.0)
        notesTextView.isRichText = false
        notesTextView.isAutomaticQuoteSubstitutionEnabled = false
        scroll.documentView = notesTextView
        notesContainer.addSubview(scroll)
        
        let saveBtn = NSButton(title: "Save to Apple Notes", target: self, action: #selector(saveNote))
        saveBtn.bezelStyle = .rounded
        saveBtn.controlSize = .large
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        notesContainer.addSubview(saveBtn)
        
        NSLayoutConstraint.activate([
            titleLbl.topAnchor.constraint(equalTo: notesContainer.topAnchor, constant: 8),
            titleLbl.leadingAnchor.constraint(equalTo: notesContainer.leadingAnchor, constant: 20),
            
            scroll.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: notesContainer.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: notesContainer.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: saveBtn.topAnchor, constant: -12),
            
            saveBtn.bottomAnchor.constraint(equalTo: notesContainer.bottomAnchor, constant: -16),
            saveBtn.centerXAnchor.constraint(equalTo: notesContainer.centerXAnchor)
        ])
    }

    // Evaluates the amount field, which doubles as a small calculator: "25*4"
    // converts 100. Deliberately hand-rolled instead of NSExpression, which
    // raises an Objective-C exception on malformed input — Swift cannot catch
    // those, so typing a half-finished "5*" would take the whole app down.
    // Returns nil for anything it can't evaluate; the caller treats that as
    // "no amount yet" rather than an error.
    // Turns ONE typed number into something Double() can read, deciding per
    // number — never over the whole expression, or "1,5+1,5" would look like it
    // had a thousands separator. A comma is a decimal point ("1,5") unless it
    // sits between a 1–3 digit group and exactly three digits ("1,000",
    // "12,345", "1,000,000"), which reads as thousands grouping. With both
    // separators present the LAST one is the decimal point ("1,000.50",
    // "1.000,50"). A lone "." stays a decimal point. Anything irregular is nil.
    func normalizeNumberLiteral(_ lit: String) -> String? {
        let commas = lit.filter { $0 == "," }.count
        let dots = lit.filter { $0 == "." }.count
        if commas == 0 { return dots <= 1 ? lit : nil }
        func validLeadingGroup(_ g: String) -> Bool { (1...3).contains(g.count) && !g.hasPrefix("0") }

        if dots == 0 {
            let groups = lit.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if commas == 1 {
                if groups[1].count == 3, validLeadingGroup(groups[0]) { return groups[0] + groups[1] }
                return groups[0] + "." + groups[1]
            }
            guard validLeadingGroup(groups[0]), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            return groups.joined()
        }

        guard let lastComma = lit.lastIndex(of: ","), let lastDot = lit.lastIndex(of: ".") else { return nil }
        let decimalSep: Character = lastComma > lastDot ? "," : "."
        let groupSep: Character = decimalSep == "," ? "." : ","
        guard lit.filter({ $0 == decimalSep }).count == 1 else { return nil }
        let parts = lit.split(separator: decimalSep, omittingEmptySubsequences: false).map(String.init)
        let intGroups = parts[0].split(separator: groupSep, omittingEmptySubsequences: false).map(String.init)
        guard validLeadingGroup(intGroups[0]) || intGroups.count == 1,
              intGroups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        return intGroups.joined() + "." + parts[1]
    }

    func evaluateArithmetic(_ input: String) -> Double? {
        enum Token: Equatable { case number(Double), plus, minus, times, divide, lparen, rparen }
        var tokens: [Token] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" { i += 1; continue }
            if c.isNumber || c == "." || c == "," {
                var literal = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "," {
                    literal.append(chars[i]); i += 1
                }
                guard let clean = normalizeNumberLiteral(literal),
                      let value = Double(clean), value.isFinite else { return nil }
                tokens.append(.number(value))
                continue
            }
            switch c {
            case "+": tokens.append(.plus)
            case "-": tokens.append(.minus)
            case "*", "\u{00D7}": tokens.append(.times)
            case "/", "\u{00F7}": tokens.append(.divide)
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            default: return nil
            }
            i += 1
        }
        guard !tokens.isEmpty else { return nil }

        var pos = 0
        func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }

        func parseFactor() -> Double? {
            guard let t = peek() else { return nil }
            switch t {
            case .minus:
                pos += 1
                guard let v = parseFactor() else { return nil }
                return -v
            case .plus:
                pos += 1
                return parseFactor()
            case .number(let v):
                pos += 1
                return v
            case .lparen:
                pos += 1
                guard let v = parseExpression() else { return nil }
                guard peek() == .rparen else { return nil }
                pos += 1
                return v
            default:
                return nil
            }
        }
        func parseTerm() -> Double? {
            guard var acc = parseFactor() else { return nil }
            while let t = peek(), t == .times || t == .divide {
                pos += 1
                guard let rhs = parseFactor() else { return nil }
                if t == .divide {
                    guard rhs != 0 else { return nil }
                    acc /= rhs
                } else {
                    acc *= rhs
                }
                guard acc.isFinite else { return nil }
            }
            return acc
        }
        func parseExpression() -> Double? {
            guard var acc = parseTerm() else { return nil }
            while let t = peek(), t == .plus || t == .minus {
                pos += 1
                guard let rhs = parseTerm() else { return nil }
                acc = (t == .plus) ? acc + rhs : acc - rhs
                guard acc.isFinite else { return nil }
            }
            return acc
        }

        guard let result = parseExpression() else { return nil }
        guard pos == tokens.count, result.isFinite else { return nil }
        return result
    }

    // Deliberately strict: only a plain non-negative number (comma or point as
    // decimal separator), capped at 100 — this is a rate someone typed by
    // hand, not an expression. Returns nil for anything else, which the
    // caller treats as "no tax" rather than an error.
    func parseTaxPercent(_ input: String) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard normalized.filter({ $0 == "." }).count <= 1 else { return nil }
        guard normalized.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        guard let value = Double(normalized), value.isFinite else { return nil }
        guard value >= 0, value <= 100 else { return nil }
        return value
    }

    func buildCurrencyTab() {
        // Wrapped in a scroll view, same pattern as Notes: a fixed-size,
        // non-scrolling stack of rows silently clips at the smallest panel
        // size (0.85x) the moment a row gets added — which is exactly what
        // happened here when the tax row landed. A scroll view means this
        // tab can never again go invisible-at-the-bottom regardless of how
        // many rows it grows to.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        currencyContainer.addSubview(scroll)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: currencyContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: currencyContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: currencyContainer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: currencyContainer.bottomAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        // Kept compact on purpose: at the smallest panel size the tax row
        // pushed the result label below the visible area. The scroll view
        // above is a safety net, but the real fix is fitting without needing
        // it — tighter fonts/gaps, and amount+tax sharing one row.
        let titleLbl = lbl("Currency", 13, .bold, C.textPrimary)
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleLbl)

        currencyAmountField = NSTextField()
        currencyAmountField.stringValue = "1"
        currencyAmountField.font = .systemFont(ofSize: 17, weight: .medium)
        currencyAmountField.textColor = C.textPrimary
        currencyAmountField.alignment = .center
        currencyAmountField.isBordered = false
        currencyAmountField.drawsBackground = false
        currencyAmountField.focusRingType = .none
        currencyAmountField.target = self
        currencyAmountField.action = #selector(runCurrencyConversion)
        currencyAmountField.delegate = self
        currencyAmountField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(currencyAmountField)

        currencyFromPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        currencyToPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for p in [currencyFromPopup!, currencyToPopup!] {
            p.addItems(withTitles: Self.currencyCodes)
            p.controlSize = .small
            p.target = self
            p.action = #selector(runCurrencyConversion)
            p.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(p)
        }
        currencyFromPopup.selectItem(withTitle: "USD")
        currencyToPopup.selectItem(withTitle: "EUR")

        let swapBtn = NSButton(image: NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Swap")!, target: self, action: #selector(swapCurrencies))
        swapBtn.bezelStyle = .inline; swapBtn.isBordered = false
        swapBtn.contentTintColor = C.textMuted
        swapBtn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(swapBtn)

        // Off by default — existing behavior (no tax) is unchanged unless the
        // user opts in. Checking it reveals a field prefilled with 16 (a
        // common VAT rate), which is just a starting point to edit or clear.
        currencyTaxCheckbox = NSButton(checkboxWithTitle: "Impuesto", target: self, action: #selector(toggleCurrencyTax))
        currencyTaxCheckbox.state = .off
        currencyTaxCheckbox.font = .systemFont(ofSize: 11, weight: .regular)
        currencyTaxCheckbox.contentTintColor = C.textMuted
        currencyTaxCheckbox.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(currencyTaxCheckbox)

        currencyTaxField = NSTextField()
        currencyTaxField.stringValue = Self.currencyDefaultTaxPercent
        currencyTaxField.font = .systemFont(ofSize: 11, weight: .medium)
        currencyTaxField.textColor = C.textPrimary
        currencyTaxField.alignment = .center
        currencyTaxField.isBordered = false
        currencyTaxField.drawsBackground = false
        currencyTaxField.focusRingType = .none
        currencyTaxField.target = self
        currencyTaxField.action = #selector(runCurrencyConversion)
        currencyTaxField.delegate = self
        currencyTaxField.isHidden = true
        currencyTaxField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(currencyTaxField)

        currencyTaxPercentSign = lbl("%", 11, .regular, C.textMuted)
        currencyTaxPercentSign.isHidden = true
        currencyTaxPercentSign.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(currencyTaxPercentSign)

        // Amount and tax share one row via a stack view rather than manual
        // centering math — a stack also auto-collapses the gap for the
        // field/percent-sign while they're hidden (tax off), so the row
        // shrinks back to just [amount, checkbox] with no extra code.
        let amountTaxRow = NSStackView(views: [currencyAmountField, currencyTaxCheckbox, currencyTaxField, currencyTaxPercentSign])
        amountTaxRow.orientation = .horizontal
        amountTaxRow.alignment = .centerY
        amountTaxRow.spacing = 6
        amountTaxRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(amountTaxRow)

        currencyResultLabel = lbl("—", 19, .bold, C.textPrimary)
        currencyResultLabel.alignment = .center
        currencyResultLabel.maximumNumberOfLines = 1
        currencyResultLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(currencyResultLabel)

        currencyStatusLabel = lbl("", 10, .regular, C.textMuted)
        currencyStatusLabel.alignment = .center
        currencyStatusLabel.maximumNumberOfLines = 1
        currencyStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(currencyStatusLabel)

        NSLayoutConstraint.activate([
            titleLbl.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            titleLbl.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            currencyAmountField.widthAnchor.constraint(equalToConstant: 60),
            currencyTaxField.widthAnchor.constraint(equalToConstant: 24),

            amountTaxRow.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 4),
            amountTaxRow.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            currencyFromPopup.topAnchor.constraint(equalTo: amountTaxRow.bottomAnchor, constant: 6),
            currencyFromPopup.trailingAnchor.constraint(equalTo: swapBtn.leadingAnchor, constant: -10),
            currencyFromPopup.widthAnchor.constraint(equalToConstant: 90),

            swapBtn.centerYAnchor.constraint(equalTo: currencyFromPopup.centerYAnchor),
            swapBtn.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            currencyToPopup.centerYAnchor.constraint(equalTo: currencyFromPopup.centerYAnchor),
            currencyToPopup.leadingAnchor.constraint(equalTo: swapBtn.trailingAnchor, constant: 10),
            currencyToPopup.widthAnchor.constraint(equalToConstant: 90),

            currencyResultLabel.topAnchor.constraint(equalTo: currencyFromPopup.bottomAnchor, constant: 8),
            currencyResultLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            currencyResultLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            currencyStatusLabel.topAnchor.constraint(equalTo: currencyResultLabel.bottomAnchor, constant: 3),
            currencyStatusLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            // This is what gives the document view its scrollable height —
            // nothing else pins content's bottom, so it grows to fit whatever
            // rows exist rather than clipping them. In normal use this fits
            // well within the visible area and the scroll never engages.
            content.bottomAnchor.constraint(equalTo: currencyStatusLabel.bottomAnchor, constant: 4),
        ])

        runCurrencyConversion()
    }

    @objc func toggleCurrencyTax(_ sender: NSButton) {
        let hidden = (sender.state == .off)
        currencyTaxField.isHidden = hidden
        currencyTaxPercentSign.isHidden = hidden
        updateCurrencyDisplay()
    }

    @objc func swapCurrencies() {
        let fromTitle = currencyFromPopup.titleOfSelectedItem
        let toTitle = currencyToPopup.titleOfSelectedItem
        currencyFromPopup.selectItem(withTitle: toTitle ?? "EUR")
        currencyToPopup.selectItem(withTitle: fromTitle ?? "USD")
        runCurrencyConversion()
    }

    // Live-updates the conversion as the user types. Deliberately calls the
    // local-only recompute: hitting the network per keystroke would fire four
    // requests for "1000".
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field === currencyAmountField || field === currencyTaxField else { return }
        updateCurrencyDisplay()
    }

    // Recomputes the displayed result from whatever rate is already cached.
    // Purely local — safe to call on every keystroke.
    func updateCurrencyDisplay() {
        guard let from = currencyFromPopup.titleOfSelectedItem, let to = currencyToPopup.titleOfSelectedItem else { return }
        let typed = currencyAmountField.stringValue
        guard let baseAmount = evaluateArithmetic(typed) else {
            // Half-typed expressions land here constantly ("25*"), so this is a
            // neutral hint, not an error state.
            currencyResultLabel.stringValue = "—"
            currencyStatusLabel.stringValue = typed.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Escribe un monto — también acepta operaciones como 25*4"
                : "No se puede calcular «\(typed)»"
            return
        }

        var parts: [String] = []

        // When the field held an actual operation, echo what it resolved to so
        // it's clear which number got converted. A plain "25" needs no echo.
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        let hasOperator = trimmed.dropFirst().rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/×÷()")) != nil
        if hasOperator {
            parts.append("\(trimmed) = \(formatCurrencyAmount(baseAmount, code: from))")
        }

        // Tax is opt-in via the checkbox; an invalid or empty percent while
        // checked is silently treated as no tax rather than blocking the result.
        var amount = baseAmount
        if currencyTaxCheckbox.state == .on, let taxPercent = parseTaxPercent(currencyTaxField.stringValue) {
            amount = baseAmount * (1 + taxPercent / 100)
            let taxLabel = taxPercent.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", taxPercent) : String(format: "%.2f", taxPercent)
            parts.append("+\(taxLabel)% = \(formatCurrencyAmount(amount, code: from))")
        }

        if from == to {
            currencyResultLabel.stringValue = formatCurrencyAmount(amount, code: to)
            parts.append("Misma moneda")
            currencyStatusLabel.stringValue = parts.joined(separator: " · ")
            return
        }
        if let cached = currencyRatesCache["\(from)_\(to)"] {
            currencyResultLabel.stringValue = formatCurrencyAmount(amount * cached.rate, code: to)
            parts.append("1 \(from) = \(String(format: "%.4f", cached.rate)) \(to) · \(cached.date)")
        } else {
            currencyResultLabel.stringValue = "—"
            parts.append("Cargando tasas…")
        }
        currencyStatusLabel.stringValue = parts.joined(separator: " · ")
    }

    // Updates the display, then refreshes the rate over the network if needed.
    // Only called on picker/swap/Enter — never per keystroke, so typing "1000"
    // doesn't fire four requests.
    @objc func runCurrencyConversion() {
        updateCurrencyDisplay()
        guard let from = currencyFromPopup.titleOfSelectedItem, let to = currencyToPopup.titleOfSelectedItem,
              from != to else { return }
        let pair = "\(from)_\(to)"
        // Rates are published once a day, so a same-day cached rate needs no
        // refetch. This also collapses repeated Enter presses into one request.
        let today = Self.currencyDayFormatter.string(from: Date())
        if let cached = currencyRatesCache[pair], cached.date == today { return }
        guard !currencyPairsInFlight.contains(pair) else { return }
        currencyPairsInFlight.insert(pair)

        fetchCurrencyRate(from: from, to: to) { [weak self] rate, date in
            DispatchQueue.main.async {
                guard let self else { return }
                self.currencyPairsInFlight.remove(pair)
                guard let rate else {
                    // Keep any cached figure on screen; just say it may be stale.
                    if self.currencyFromPopup.titleOfSelectedItem == from,
                       self.currencyToPopup.titleOfSelectedItem == to {
                        self.currencyStatusLabel.stringValue = "Sin conexión — no se pudo actualizar la tasa"
                    }
                    return
                }
                self.currencyRatesCache[pair] = (rate, date)
                // Only repaint if the user hasn't switched to a different pair
                // while the request was in flight.
                guard self.currencyFromPopup.titleOfSelectedItem == from,
                      self.currencyToPopup.titleOfSelectedItem == to else { return }
                self.updateCurrencyDisplay()
            }
        }
    }

    func formatCurrencyAmount(_ value: Double, code: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let number = f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "\(number) \(code)"
    }

    struct FrankfurterResponse: Decodable {
        let date: String
        let rates: [String: Double]
    }

    // Frankfurter.app: free, no API key, ECB-sourced daily rates. Fails closed —
    // a network error just leaves the cached rate (if any) on screen instead of
    // crashing or blocking the UI.
    func fetchCurrencyRate(from: String, to: String, completion: @escaping (Double?, String) -> Void) {
        guard let url = URL(string: "https://api.frankfurter.app/latest?from=\(from)&to=\(to)") else {
            completion(nil, "")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, error == nil,
                  let decoded = try? JSONDecoder().decode(FrankfurterResponse.self, from: data),
                  let rate = decoded.rates[to] else {
                completion(nil, "")
                return
            }
            completion(rate, decoded.date)
        }.resume()
    }

    @objc func saveNote() {
        let text = notesTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // The note text is passed to osascript as an ARGUMENT rather than spliced
        // into the script source. The previous version interpolated it directly and
        // only escaped the sequence \" — so a plain quote broke the script, and an
        // AppleScript string literal can't contain raw newlines at all, meaning any
        // multi-line note silently failed to save (runScriptOut discards errors).
        let script = """
        on run argv
            tell application "Notes"
                make new note with properties {body:(item 1 of argv)}
            end tell
        end run
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = self?.runScript(script, arguments: [text]) ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.notesTextView.string = ""
                } else {
                    NSLog("NotchDrop: saving note to Apple Notes failed")
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Entry
// ═══════════════════════════════════════════════════════════════════════════
// Decides whether the pointer being away from the panel should close it.
// A panel opened with ⌥⌘N has no reason to have the pointer near it (it's
// typically resting in a document), so distance alone used to close it within
// about a second of opening. Until the pointer has been inside once, a
// keyboard-opened panel stays open; afterwards it behaves like any other.
enum AutoCollapsePolicy {
    static func decide(pointer: NSPoint, paddedRect: NSRect, keyboardOpened: Bool, hasEntered: Bool) -> (collapse: Bool, hasEntered: Bool) {
        let inside = paddedRect.contains(pointer)
        let entered = hasEntered || inside
        if inside { return (false, entered) }
        if keyboardOpened && !entered { return (false, entered) }
        return (true, entered)
    }
}

// Elapsed time comes from wall-clock timestamps, not from counting timer
// fires. The old stopwatch added 0.1 s per fire, so anything that delayed the
// timer (scrolling, an open menu, a modal panel, sleep) silently lost time:
// measured 1.6 s displayed after 4.5 s of real time. Now the timer only
// redraws; the number is always derived from the clock.
struct StopwatchClock {
    private var accumulated: TimeInterval = 0
    private var startedAt: Date?
    var isRunning: Bool { startedAt != nil }

    mutating func start(at now: Date) { if startedAt == nil { startedAt = now } }
    mutating func pause(at now: Date) {
        guard let s = startedAt else { return }
        accumulated += max(0, now.timeIntervalSince(s))
        startedAt = nil
    }
    mutating func reset() { accumulated = 0; startedAt = nil }
    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
    // mm:ss.d — tenths are truncated, like a real stopwatch.
    static func format(_ t: TimeInterval) -> String {
        let tenths = max(0, Int(t * 10))
        return String(format: "%02d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

// How long to wait before restarting the Now Playing bridge after it exits, and
// when to stop trying. On macOS 15.4+ the direct MediaRemote fallback is
// rejected for third-party apps, so giving up after one exit meant Now Playing
// was gone until the app was relaunched.
enum BridgeRestartPolicy {
    static func delay(afterFailures n: Int) -> TimeInterval? {
        switch n { case 1: return 2; case 2: return 10; case 3: return 60; default: return nil }
    }
}

// MARK: - Updates

enum UpdateVersion {
    // "v3.13.0" / "3.13" → [3, 13, 0] / [3, 13]; nil for anything that isn't
    // purely non-negative integers separated by dots.
    static func components(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

enum UpdateSignature {
    // Public half of the release-signing key. The private half lives only in
    // the author's Keychain ("NotchDrop update signing key"); see RELEASING.md.
    // Empty means "no key configured": verify() then rejects everything, so
    // nothing can ever be installed.
    static var publicKeyBase64 = "p8w7TNtfGL/OsZa00LQMJp7xfNl0m2iqxXtd5aXu8fQ="

    static func verify(data: Data, signatureBase64: String, publicKeyBase64: String = UpdateSignature.publicKeyBase64) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              !sig.isEmpty
        else { return false }
        return key.isValidSignature(sig, for: data)
    }
}

struct UpdateRelease: Equatable {
    let version: String
    let zipURL: URL
    let signatureURL: URL
    let pageURL: URL
}

enum UpdateError: Error {
    case http(Int), network(String), noRelease, badSignature, invalidBundle(String), notWritable, extractFailed, replaceFailed(String)
    var message: String {
        switch self {
        case .http(let c): return "GitHub respondió con error \(c). Intenta más tarde."
        case .network(let m): return "Sin conexión: \(m)"
        case .noRelease: return "No encontré una versión publicada."
        case .badSignature: return "La actualización no pasó la verificación de seguridad y no se instaló."
        case .invalidBundle(let m): return "La actualización descargada no es válida (\(m)). No se instaló."
        case .notWritable: return "No tengo permiso para reemplazar la app en su carpeta. Descárgala a mano desde GitHub."
        case .extractFailed: return "No pude descomprimir la actualización."
        case .replaceFailed(let m): return "No pude reemplazar la app: \(m). Tu versión actual sigue intacta."
        }
    }
}

enum UpdateFeed {
    static let defaultURL = URL(string: "https://api.github.com/repos/marvalre/NotchDrop/releases/latest")!
    // Debug override for end-to-end tests against a local server. Signatures are
    // still required, so pointing it elsewhere can't install anything unsigned.
    static var url: URL {
        UserDefaults.standard.string(forKey: "NotchDropUpdateFeedURL").flatMap(URL.init(string:)) ?? defaultURL
    }

    static func isAllowed(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        return url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host ?? "")
    }

    static func parse(_ data: Data) -> UpdateRelease? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        if (obj["draft"] as? Bool) == true || (obj["prerelease"] as? Bool) == true { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard UpdateVersion.components(version) != nil else { return nil }
        func asset(_ name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }
                .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
                .flatMap { isAllowed($0) ? $0 : nil }
        }
        guard let zip = asset("NotchDrop-\(version).zip"),
              let sig = asset("NotchDrop-\(version).zip.sig") else { return nil }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? zip
        return UpdateRelease(version: version, zipURL: zip, signatureURL: sig, pageURL: page)
    }

    static func fetchLatest(completion: @escaping (Result<UpdateRelease, UpdateError>) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let result: Result<UpdateRelease, UpdateError>
            if let err { result = .failure(.network(err.localizedDescription)) }
            else if let h = resp as? HTTPURLResponse, h.statusCode != 200 { result = .failure(.http(h.statusCode)) }
            else if let rel = data.flatMap(parse) { result = .success(rel) }
            else { result = .failure(.noRelease) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}

enum UpdateInstaller {
    static func fetch(_ url: URL, timeout: TimeInterval = 120) throws -> Data {
        guard UpdateFeed.isAllowed(url) else { throw UpdateError.network("URL no permitida") }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, UpdateError> = .failure(.network("sin respuesta"))
        URLSession.shared.dataTask(with: req) { d, r, e in
            if let e { result = .failure(.network(e.localizedDescription)) }
            else if let h = r as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { result = .failure(.http(h.statusCode)) }
            else { result = .success(d ?? Data()) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }

    // Runs off the main thread; `completion` is called on main with the installed app.
    static func install(_ release: UpdateRelease, currentApp: URL, expectedBundleID: String,
                        completion: @escaping (Result<URL, UpdateError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try installSync(release, currentApp: currentApp, expectedBundleID: expectedBundleID) }
                .mapError { $0 as? UpdateError ?? .replaceFailed($0.localizedDescription) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // Order matters: nothing touches the installed app until the download is
    // verified AND unpacked AND validated, and the swap itself is atomic. If any
    // step fails, the app the user is running is exactly as it was.
    static func installSync(_ release: UpdateRelease, currentApp: URL, expectedBundleID: String) throws -> URL {
        let fm = FileManager.default
        let parent = currentApp.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable }

        let zipData = try fetch(release.zipURL)
        let sig = String(decoding: try fetch(release.signatureURL, timeout: 30), as: UTF8.self)
        guard UpdateSignature.verify(data: zipData, signatureBase64: sig) else { throw UpdateError.badSignature }

        let work = fm.temporaryDirectory.appendingPathComponent("NotchDropUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zipFile = work.appendingPathComponent("update.zip")
        try zipData.write(to: zipFile)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipFile.path, work.appendingPathComponent("x").path]
        guard runProcessBounded(unzip, timeout: 60).status == 0 else { throw UpdateError.extractFailed }
        let newApp = work.appendingPathComponent("x/NotchDrop.app")

        // Even a correctly signed zip must be what the release says it is.
        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == expectedBundleID else { throw UpdateError.invalidBundle("identificador distinto") }
        guard info?["CFBundleShortVersionString"] as? String == release.version else { throw UpdateError.invalidBundle("versión distinta a la publicada") }
        let cs = Process()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["--verify", "--deep", "--strict", newApp.path]
        guard runProcessBounded(cs, timeout: 60).status == 0 else { throw UpdateError.invalidBundle("firma de código inválida") }

        let backupName = "NotchDrop (anterior).app"
        let backup = parent.appendingPathComponent(backupName)
        if fm.fileExists(atPath: backup.path) { try? fm.trashItem(at: backup, resultingItemURL: nil) }
        let installed: URL
        do {
            installed = try fm.replaceItemAt(currentApp, withItemAt: newApp, backupItemName: backupName,
                                             options: [.withoutDeletingBackupItem]) ?? currentApp
        } catch { throw UpdateError.replaceFailed(error.localizedDescription) }
        // The previous version goes to the Trash, not oblivion, so it can be recovered.
        if fm.fileExists(atPath: backup.path) { try? fm.trashItem(at: backup, resultingItemURL: nil) }
        return installed
    }

    // Waits for this process to exit, then opens the new copy. The app path is
    // passed as $0, never spliced into the script text.
    static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

// Compiled out for the test runner (tests/run.sh), which links this file as a
// library next to tests/main.swift. An @main entry point rather than top-level
// statements because Swift rejects top-level code in a non-main file even inside
// an inactive #if.
#if !NOTCHDROP_TESTS
@main
enum NotchDropMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication.delegate is weak; this keeps the delegate alive for the
        // whole run loop instead of relying on the optimizer not releasing it.
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
