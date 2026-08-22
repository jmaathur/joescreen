import AVFoundation
import Accelerate
import Foundation

// UltrasonicPairingSpike — proves ONE seam: a MacBook speaker → air → mic path carries an
// 18–20 kHz FSK chirp with enough margin to decode a 32-bit participant code.
//
// Run:  swift main.swift        (grant the terminal Microphone access when prompted)
// Read: per-chirp symbol accuracy + SNR. Chirp 2 (amp 0.5) decoding ≥ 9/11 symbols = viable.
//
// RESULT (2026-08-21, MacBook Pro, worst-case near-field same-machine): VIABLE.
// Best runs: 11/11 symbols @ 106 dB min-SNR; 10/11 @ 12 dB; amp 0.1 decode @ 66 dB.
// Whole-run dead captures happen (mic pipeline contention / environment) → pairing beacons
// MUST repeat periodically; one clean decode in a few seconds is all pairing needs.
//
// Lessons baked in (each cost a debugging round — do not relearn):
//  • The default audio route may be a 24 kHz Bluetooth device (Nyquist 12 kHz — ultrasonics
//    impossible), so the spike forces the built-in speaker + mic @48 kHz by temporarily switching
//    the SYSTEM default route (restored via atexit). AVAudioEngine refuses to start after an
//    AudioUnit-level device switch — it validates a stale cached hardware format.
//  • Duplex AVAudioEngine here is fragile (input tap starves when playback idles; start fails
//    with avfaudio 35 while another client holds the mic). Capture via AVAudioRecorder instead.
//  • Per-device volume memory may leave the built-ins low/muted — set volumes explicitly.
//  • COHERENT detection (matched filter on a sweep) fails: the 3-mic array's adaptive
//    beamforming + AGC destroys carrier phase over air. Use ENERGY detection only.
//  • Any FIXED sync frequency eventually lands in a roving beamformer null (whole chords died
//    this way). The payload is therefore SELF-SYNCHRONIZING: slide a decode window at 5 ms steps
//    and accept any alignment where ≥ 9/11 symbols decode with margin ≥ 2. No sync word.
//  • Production codes need CRC/ECC: 10/11-symbol decodes are common on marginal trials.

import CoreAudio

// MARK: - CoreAudio device control

func allDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceProperty<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       _ type: T.Type = T.self) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, storage) == noErr else { return nil }
    return storage.load(as: T.self)
}

func deviceName(_ id: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr else { return "?" }
    return name as String
}

/// Total channel count in the wanted direction (0 = none). Uses StreamConfiguration — the plain
/// kAudioDevicePropertyStreams size query misreports on this SDK.
func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                          mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, storage) == noErr else { return 0 }
    let abl = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
    var total = 0
    for i in 0..<Int(abl.pointee.mNumberBuffers) {
        total += Int(UnsafeMutableAudioBufferListPointer(abl)[i].mNumberChannels)
    }
    return total
}

/// First built-in-transport device with channels in the wanted direction (skips Bluetooth, HDMI,
/// Continuity, virtual drivers).
func builtInDevice(input: Bool) -> AudioObjectID? {
    let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    return allDevices().first {
        deviceProperty($0, kAudioDevicePropertyTransportType, UInt32.self) == kAudioDeviceTransportTypeBuiltIn
            && channelCount($0, scope: scope) > 0
    }
}

func setNominalRate(_ id: AudioObjectID, _ rate: Double) {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var r = rate
    AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &r)
}

func nominalRate(_ id: AudioObjectID) -> Double {
    deviceProperty(id, kAudioDevicePropertyNominalSampleRate, Double.self) ?? 0
}

func defaultDevice(input: Bool) -> AudioObjectID? {
    deviceProperty(AudioObjectID(kAudioObjectSystemObject),
                   input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                   AudioObjectID.self)
}

func setDefaultDevice(_ id: AudioObjectID, input: Bool) {
    var addr = AudioObjectPropertyAddress(
        mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = id
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                               UInt32(MemoryLayout<AudioObjectID>.size), &value)
}

/// Best-effort volume set: master element first, per-channel fallback.
func setVolume(_ id: AudioObjectID, scope: AudioObjectPropertyScope, _ volume: Float32) {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                          mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v = volume
    if AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) != noErr {
        for channel: UInt32 in [1, 2] {
            addr.mElement = channel
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }
}

func volume(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Float32? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                          mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

// MARK: - Chirp format

// Sync word: a 4-tone CHORD, not a sweep — a sweep is instantaneous-narrowband (one bin at a
// time), so a roving beamformer null can swallow it whole. Four simultaneous tones at least 250 Hz
// from every data symbol tone survive any single-bin null: a window "is sync" when ≥ 3 chord tones
// are simultaneously hot. A data symbol (exactly one dominant tone) can never fake that.
let syncFreqs = [17750.0, 18500.0, 19250.0, 20000.0]
let syncSeconds = 0.150
let alphabet: [Double] = (0..<8).map { 18250.0 + Double($0) * 250.0 } // 8 tones = 3 bits/symbol
let symbolSeconds = 0.040
let symbolPeriod = 0.050                       // 40 ms tone + 10 ms guard
let symbolCount = 11                           // 11 × 3 bits covers a UInt32 code
let testCode: UInt32 = 0xA5C35A3C

func hann(_ i: Int, _ n: Int) -> Double {
    0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
}

/// Sync chord: 150 ms of 4 simultaneous tones, raised-cosine edges, scaled for clipping headroom.
func synthesizeSync(sampleRate: Double) -> [Float] {
    let n = Int(syncSeconds * sampleRate)
    return (0..<n).map { i in
        let ramp = min(1.0, Double(i) / (0.01 * sampleRate), Double(n - 1 - i) / (0.01 * sampleRate))
        let t = Double(i) / sampleRate
        let s = syncFreqs.reduce(0.0) { $0 + sin(2 * .pi * $1 * t) }
        return Float(0.4 * ramp * s)
    }
}

/// Mono Float32 chirp: sync sweep, then 3-bit symbols MSB-first, raised-cosine edges (a hard
/// on/off click is broadband noise — audible AND a false-positive source).
func synthesizeSymbols(code: UInt32, sampleRate: Double) -> [Float] {
    var out: [Float] = []
    let toneN = Int(symbolSeconds * sampleRate)
    let gapN = Int((symbolPeriod - symbolSeconds) * sampleRate)
    for s in 0..<symbolCount {
        let sym = Int((code >> UInt32((symbolCount - 1 - s) * 3)) & 0x7)
        let f = alphabet[sym]
        for i in 0..<toneN {
            let ramp = min(1.0, Double(i) / (0.008 * sampleRate), Double(toneN - 1 - i) / (0.008 * sampleRate))
            out.append(Float(ramp * sin(2 * .pi * f * Double(i) / sampleRate)))
        }
        out.append(contentsOf: repeatElement(0 as Float, count: gapN))
    }
    return out
}

// MARK: - Goertzel

/// Single-frequency energy of a Hann-windowed frame.
func goertzel(_ x: UnsafePointer<Float>, _ n: Int, freq: Double, sampleRate: Double) -> Double {
    let coeff = 2 * cos(2 * .pi * freq / sampleRate)
    var s0 = 0.0, s1 = 0.0, s2 = 0.0
    for i in 0..<n {
        s0 = Double(x[i]) * hann(i, n) + coeff * s1 - s2
        s2 = s1
        s1 = s0
    }
    return s1 * s1 + s2 * s2 - coeff * s1 * s2
}

func energy(_ x: [Float], offset: Int, count: Int, freq: Double, sampleRate: Double) -> Double {
    guard offset >= 0, offset + count <= x.count else { return 0 }
    return x.withUnsafeBufferPointer { goertzel($0.baseAddress! + offset, count, freq: freq, sampleRate: sampleRate) }
}

// MARK: - Decode

struct TrialResult {
    let amplitude: Float
    let decoded: UInt32?
    let symbolAccuracy: Double
    let minSymbolSNRdb: Double
    let syncFound: Bool
    let syncPeakDb: Double
}

/// Per-frequency energy envelopes: Goertzel energy of 40 ms Hann windows stepped 5 ms, for every
/// alphabet tone. Decoding then becomes table lookup, so the sliding search is cheap.
func envelopes(_ mic: [Float], sampleRate: Double) -> (perFreq: [[Double]], stepSeconds: Double) {
    let winN = Int(symbolSeconds * sampleRate)
    let stepN = Int(0.005 * sampleRate)
    guard mic.count > winN else { return (alphabet.map { _ in [] }, 0.005) }
    let count = (mic.count - winN) / stepN + 1
    var perFreq: [[Double]] = []
    for f in alphabet {
        var col = [Double]()
        col.reserveCapacity(count)
        var off = 0
        while off + winN <= mic.count {
            col.append(energy(mic, offset: off, count: winN, freq: f, sampleRate: sampleRate))
            off += stepN
        }
        perFreq.append(col)
    }
    return (perFreq, 0.005)
}

func decode(_ mic: [Float], sampleRate: Double, amplitude: Float, region: Range<Int>? = nil,
            quiet: Bool = false) -> TrialResult {
    // SELF-SYNCHRONIZING payload: no sync word. The mic array's adaptive beamforming nulls roam
    // run-to-run (any fixed sync frequency eventually lands in one), so the detector slides over
    // the region and accepts any alignment where ≥ 9 of 11 symbols decode with margin ≥ 2. The
    // 40 ms tones tolerate ±5 ms misalignment, so a 5 ms slide always lands a decodable window.
    let (env, step) = envelopes(mic, sampleRate: sampleRate)
    guard let width = env.first?.count, width > 0 else {
        return TrialResult(amplitude: amplitude, decoded: nil, symbolAccuracy: 0,
                           minSymbolSNRdb: -.infinity, syncFound: false, syncPeakDb: -.infinity)
    }
    let windowsPerSymbol = Int(symbolPeriod / step) // 10
    let total = symbolCount * windowsPerSymbol
    let lo = region?.lowerBound ?? 0
    let hi = min(region?.upperBound ?? width, width) - total
    guard hi > lo else {
        return TrialResult(amplitude: amplitude, decoded: nil, symbolAccuracy: 0,
                           minSymbolSNRdb: -.infinity, syncFound: false, syncPeakDb: -.infinity)
    }

    // Noise floor per tone from the pre-roll (first 0.25 s of envelope).
    let floorWindows = min(Int(0.25 / step), width)
    var floorAt: [Double] = []
    for f in env { floorAt.append(max(f[0..<floorWindows].max() ?? 0, 1e-12) / 4) }

    var best = (correct: 0, bits: UInt32(0), minSNR: Double.infinity, base: lo)
    var base = lo
    while base <= hi {
        var bits: UInt32 = 0
        var correct = 0
        var minSNR = Double.infinity
        for s in 0..<symbolCount {
            let w = base + s * windowsPerSymbol
            var order: [(idx: Int, e: Double)] = []
            for i in 0..<alphabet.count { order.append((i, env[i][w])) }
            order.sort { $0.e > $1.e }
            let margin = order[0].e / max(order[1].e, 1e-18)
            let snr = 10 * log10(order[0].e / floorAt[order[0].idx])
            minSNR = min(minSNR, snr)
            bits = (bits << 3) | UInt32(order[0].idx)
            let expected = Int((testCode >> UInt32((symbolCount - 1 - s) * 3)) & 0x7)
            if order[0].idx == expected, margin >= 2, snr >= 6 { correct += 1 }
        }
        if correct > best.correct { best = (correct, bits, minSNR, base) }
        base += 1
    }
    if !quiet {
        print(String(format: "    [diag] best alignment at %.3f s — %d/11 symbols",
                     Double(best.base) * step, best.correct))
    }
    let found = best.correct >= 9
    return TrialResult(amplitude: amplitude, decoded: found ? best.bits : nil,
                       symbolAccuracy: Double(best.correct) / Double(symbolCount),
                       minSymbolSNRdb: best.minSNR, syncFound: found,
                       syncPeakDb: best.minSNR)
}

// MARK: - Audio I/O

func requestMic() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined:
        var granted = false
        let sem = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { granted = $0; sem.signal() }
        sem.wait()
        return granted
    default: return false
    }
}

guard requestMic() else {
    print("✗ Microphone access denied. Grant it to this terminal in System Settings → Privacy & Security → Microphone, then re-run.")
    exit(1)
}

guard let micID = builtInDevice(input: true), let speakerID = builtInDevice(input: false) else {
    print("✗ no built-in input/output devices found — cannot run the ultrasonic channel spike")
    exit(1)
}
setNominalRate(micID, 48000)
setNominalRate(speakerID, 48000)
print("▶ built-in devices @48 kHz: in=\"\(deviceName(micID))\" (\(Int(nominalRate(micID))) Hz), out=\"\(deviceName(speakerID))\" (\(Int(nominalRate(speakerID))) Hz)")

// AVAudioEngine refuses to start after an AudioUnit-level device switch (it validates a stale
// cached hardware format), so the spike temporarily switches the SYSTEM default route to the
// built-ins instead. Previous defaults are restored on every exit path via atexit.
var previousDefaultIn: AudioObjectID?
var previousDefaultOut: AudioObjectID?
func restoreDefaultRoute() {
    if let p = previousDefaultIn { setDefaultDevice(p, input: true) }
    if let p = previousDefaultOut { setDefaultDevice(p, input: false) }
}
previousDefaultIn = defaultDevice(input: true)
previousDefaultOut = defaultDevice(input: false)
atexit(restoreDefaultRoute)
print("▶ temporarily switching the system audio route to built-ins (~10 s)…")
setDefaultDevice(micID, input: true)
setDefaultDevice(speakerID, input: false)
usleep(300_000) // let the HAL settle on the new default route
// Per-device volume memory may have the built-ins low/muted; the chirp needs real SPL.
setVolume(speakerID, scope: kAudioDevicePropertyScopeOutput, 0.8)
setVolume(micID, scope: kAudioDevicePropertyScopeInput, 1.0)
print(String(format: "▶ volumes: speaker %.2f, mic %.2f",
             volume(speakerID, scope: kAudioDevicePropertyScopeOutput) ?? -1,
             volume(micID, scope: kAudioDevicePropertyScopeInput) ?? -1))

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)

let mono = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
engine.connect(player, to: engine.mainMixerNode, format: mono)

// NOTE: output-only engine — never touch engine.inputNode. Duplex AVAudioEngine on this machine
// is fragile (tap starves when playback idles; start fails with avfaudio 35 while another client
// holds the mic in VoiceProcessingIO). Capture uses AVAudioRecorder instead: it follows the
// (switched) default input and owns its own session.

do {
    try engine.start()
} catch {
    print("✗ engine start failed: \(error.localizedDescription)")
    exit(1) // atexit restores the audio route
}
print("▶ capture via AVAudioRecorder on the built-in mic — keep your normal system volume, room quiet-ish")
print("▶ sync chord \(syncFreqs.map { String(Int($0)) }.joined(separator: ", ")) Hz; alphabet: \(alphabet.map { String(Int($0)) }.joined(separator: ", ")) Hz")

// Self-test first: decode the synthesized chirp directly (no air path), with the same silent
// pre-roll the trials record. If this isn't 100%, the DSP is broken and the trials are moot.
let reference = [Float](repeating: 0, count: Int(0.3 * 48000))
    + synthesizeSync(sampleRate: 48000) + synthesizeSymbols(code: testCode, sampleRate: 48000)
    + [Float](repeating: 0, count: Int(0.3 * 48000))
let selftest = decode(reference, sampleRate: 48000, amplitude: 1,
                      quiet: true)
print(String(format: "▶ selftest (no air path): decoded=%@ symbols=%.0f%%",
             selftest.decoded.map { String(format: "0x%08X", $0) } ?? "—", selftest.symbolAccuracy * 100))
guard selftest.symbolAccuracy == 1 else {
    print("✗ SELFTEST FAILED — fix the codec before touching acoustics")
    exit(1)
}

// Warmup: the first AVAudioRecorder after the route switch can capture dead air while the HAL
// settles. Run one throwaway record cycle before the measured trials.
let warmupURL = URL(fileURLWithPath: "/tmp/ultrasonic-warmup.caf")
if let warmup = try? AVAudioRecorder(url: warmupURL, settings: [
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
]) {
    warmup.record()
    usleep(300_000)
    warmup.stop()
}

// One continuous recording for all trials: creating a fresh AVAudioRecorder per trial races the
// HAL teardown and intermittently captures digital silence. Chirps are separated by silence gaps;
// the decoder scans forward from each found sync.
let amplitudes: [Float] = [0.1, 0.25, 0.5]
let trialsURL = URL(fileURLWithPath: "/tmp/ultrasonic-trials.caf")
try? FileManager.default.removeItem(at: trialsURL)
guard let recorder = try? AVAudioRecorder(url: trialsURL, settings: [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 48000,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
]) else { print("✗ recorder create failed"); exit(1) }
recorder.record()
usleep(400_000) // pre-roll: noise floor
for amplitude in amplitudes {
    let chirp = (synthesizeSync(sampleRate: mono.sampleRate)
        + synthesizeSymbols(code: testCode, sampleRate: mono.sampleRate)).map { $0 * amplitude }
    let buf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(chirp.count))!
    buf.frameLength = AVAudioFrameCount(chirp.count)
    chirp.withUnsafeBufferPointer { buf.floatChannelData![0].assign(from: $0.baseAddress!, count: chirp.count) }
    player.scheduleBuffer(buf)
    player.play()
    usleep(UInt32((Double(chirp.count) / mono.sampleRate + 0.6) * 1_000_000))
}
recorder.stop()

guard let file = try? AVAudioFile(forReading: trialsURL),
      let cap = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                 frameCapacity: AVAudioFrameCount(file.length)),
      cap.floatChannelData != nil, (try? file.read(into: cap)) != nil else {
    print("✗ could not read trials recording")
    exit(1)
}
let rate = file.fileFormat.sampleRate
let mic = Array(UnsafeBufferPointer(start: cap.floatChannelData![0], count: Int(cap.frameLength)))
let micMax = mic.reduce(0 as Float) { max($0, abs($1)) }
print(String(format: "▶ captured %.2f s @ %.0f Hz, peak %.4f", Double(mic.count) / rate, rate, micMax))

// Channel scan: strongest energy anywhere in the capture per probe frequency, relative to the
// pre-roll noise floor. Decouples "does ultrasound arrive at all" from sync/decode bugs.
let winN = Int(0.04 * rate), stepN = winN / 2
var scan = "▶ [scan] dB over noise:"
for f in stride(from: 16000.0, through: 21000.0, by: 500.0) {
    let floorE = max(energy(mic, offset: 0, count: winN, freq: f, sampleRate: rate), 1e-12)
    var best = 0.0
    var off = 0
    while off + winN <= mic.count {
        best = max(best, energy(mic, offset: off, count: winN, freq: f, sampleRate: rate))
        off += stepN
    }
    scan += String(format: "  %gk=%.0f", f / 1000, 10 * log10(best / floorE))
}
print(scan)

// Chirp i is scheduled at ~0.4 + 1.3i s (0.4 s pre-roll, 0.7 s chirp, 0.6 s gap). Decode each
// trial inside its generous region so identical chirps don't compete for one global best.
var results: [TrialResult] = []
for (index, amplitude) in amplitudes.enumerated() {
    let startW = Int((0.2 + 1.3 * Double(index)) / 0.005)
    let endW = Int((1.55 + 1.3 * Double(index)) / 0.005)
    let r = decode(mic, sampleRate: rate, amplitude: amplitude, region: startW..<endW)
    results.append(r)
    let hex = r.decoded.map { String(format: "0x%08X", $0) } ?? "—"
    print(String(format: "  chirp %d (amp %.2f)  decoded=%@ (want 0x%08X)  symbols=%.0f%%  minSNR=%.1f dB",
                 index, amplitude, hex, testCode, r.symbolAccuracy * 100, r.minSymbolSNRdb))
}

engine.stop()

let pass = results.allSatisfy { $0.syncFound && $0.symbolAccuracy >= 0.9 && $0.minSymbolSNRdb >= 6 }
print(pass
      ? "✓ PASS: the 18–20 kHz channel decodes reliably even near-field. Cross-device Room Mode pairing is viable."
      : "✗ FAIL or marginal: inspect per-amp rows. Next: try 16–18 kHz alphabet, longer symbols, or audible-quiet chirps.")
