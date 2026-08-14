// PROTOTYPE — answers whether a warm AVAudioEngine can arm push-to-talk in
// under 100 ms while retaining a short in-memory pre-roll.

import AVFoundation
import Foundation

private let preRollSeconds = 0.25
private let engine = AVAudioEngine()
private let input = engine.inputNode
private let format = input.outputFormat(forBus: 0)
private let sampleRate = Int(format.sampleRate)
private let ringCapacity = max(1, Int(format.sampleRate * preRollSeconds))
private let lock = NSLock()
private let firstBuffer = DispatchSemaphore(value: 0)

private var ring: [Float] = []
private var recording = false
private var recorded: [Float] = []
private var outputPath = "/tmp/whisper-warm-prototype.wav"
private var hasSeenFirstBuffer = false

private func monotonicNs() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

private func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var payload = fields
    payload["event"] = event
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

private func writeWav(samples: [Float], to path: String) throws {
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let bytesPerSample = Int(bitsPerSample / 8)
    let dataBytes = samples.count * bytesPerSample

    var wav = Data()
    wav.append("RIFF".data(using: .ascii)!)
    wav.appendLE(UInt32(36 + dataBytes))
    wav.append("WAVE".data(using: .ascii)!)
    wav.append("fmt ".data(using: .ascii)!)
    wav.appendLE(UInt32(16))
    wav.appendLE(UInt16(1))
    wav.appendLE(channels)
    wav.appendLE(UInt32(sampleRate))
    wav.appendLE(UInt32(sampleRate * Int(channels) * bytesPerSample))
    wav.appendLE(UInt16(Int(channels) * bytesPerSample))
    wav.appendLE(bitsPerSample)
    wav.append("data".data(using: .ascii)!)
    wav.appendLE(UInt32(dataBytes))

    for sample in samples {
        let clipped = max(-1, min(1, sample))
        wav.appendLE(Int16(clipped * Float(Int16.max)))
    }

    try wav.write(to: URL(fileURLWithPath: path), options: .atomic)
}

let bootStarted = monotonicNs()
input.installTap(onBus: 0, bufferSize: 256, format: format) { buffer, _ in
    guard let channel = buffer.floatChannelData?[0] else { return }
    let count = Int(buffer.frameLength)
    let incoming = Array(UnsafeBufferPointer(start: channel, count: count))

    lock.lock()
    ring.append(contentsOf: incoming)
    if ring.count > ringCapacity {
        ring.removeFirst(ring.count - ringCapacity)
    }
    if recording {
        recorded.append(contentsOf: incoming)
    }
    if !hasSeenFirstBuffer {
        hasSeenFirstBuffer = true
        firstBuffer.signal()
    }
    lock.unlock()
}

engine.prepare()
try engine.start()
guard firstBuffer.wait(timeout: .now() + 3) == .success else {
    emit("error", ["message": "timed out waiting for the first microphone buffer"])
    exit(1)
}

emit("ready", [
    "boot_to_first_buffer_ms": Double(monotonicNs() - bootStarted) / 1_000_000,
    "sample_rate": sampleRate,
    "pre_roll_ms": Int(preRollSeconds * 1000),
])

while let line = readLine() {
    let received = monotonicNs()
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    let command = parts.first?.uppercased() ?? ""

    if command == "START" {
        lock.lock()
        if parts.count == 2 { outputPath = parts[1] }
        recorded = ring
        recording = true
        let buffered = recorded.count
        lock.unlock()
        emit("started", [
            "command_to_armed_ms": Double(monotonicNs() - received) / 1_000_000,
            "pre_roll_samples": buffered,
        ])
    } else if command == "STOP" {
        lock.lock()
        recording = false
        let captured = recorded
        lock.unlock()

        let finalizeStarted = monotonicNs()
        try writeWav(samples: captured, to: outputPath)
        emit("stopped", [
            "command_to_wav_ms": Double(monotonicNs() - received) / 1_000_000,
            "wav_write_ms": Double(monotonicNs() - finalizeStarted) / 1_000_000,
            "samples": captured.count,
            "path": outputPath,
        ])
    } else if command == "STATE" {
        lock.lock()
        let state = recording ? "recording" : "warm"
        let ringSamples = ring.count
        lock.unlock()
        emit("state", ["state": state, "ring_samples": ringSamples])
    } else if command == "QUIT" {
        break
    }
}

engine.stop()
input.removeTap(onBus: 0)
emit("exited")

