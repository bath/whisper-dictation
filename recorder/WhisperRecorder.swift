import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

private struct Configuration {
    var deviceName: String?
    var preRollMs = 250

    init(arguments: [String]) {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--device" where index + 1 < arguments.count:
                deviceName = arguments[index + 1]
                index += 2
            case "--pre-roll-ms" where index + 1 < arguments.count:
                preRollMs = Int(arguments[index + 1]) ?? preRollMs
                index += 2
            default:
                index += 1
            }
        }
    }
}

private enum RecorderError: Error, CustomStringConvertible {
    case audioStatus(String, OSStatus)
    case deviceNotFound(String)
    case noInputDevice
    case firstBufferTimeout

    var description: String {
        switch self {
        case let .audioStatus(operation, status):
            return "\(operation) failed with Core Audio status \(status)"
        case let .deviceNotFound(name):
            return "input device not found: \(name)"
        case .noInputDevice:
            return "no input audio device found"
        case .firstBufferTimeout:
            return "timed out waiting for the first microphone buffer"
        }
    }
}

private struct AudioDevice {
    let id: AudioDeviceID
    let name: String
}

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw RecorderError.audioStatus(operation, status) }
}

private func audioDevices() throws -> [AudioDevice] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    try check(
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount),
        "list audio devices"
    )

    let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    try check(
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &ids),
        "read audio devices"
    )

    return ids.compactMap { id in
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &unmanagedName) == noErr,
              let name = unmanagedName?.takeUnretainedValue() else {
            return nil
        }

        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &inputAddress, 0, nil, &inputSize) == noErr,
              inputSize >= MemoryLayout<AudioStreamID>.size else {
            return nil
        }
        return AudioDevice(id: id, name: name as String)
    }
}

private func selectInputDevice(requestedName: String?) throws -> AudioDevice {
    let devices = try audioDevices()
    guard !devices.isEmpty else { throw RecorderError.noInputDevice }

    if let requestedName {
        guard let requested = devices.first(where: { $0.name == requestedName }) else {
            throw RecorderError.deviceNotFound(requestedName)
        }
        return requested
    }

    if let builtIn = devices.first(where: {
        $0.name == "Built-in Microphone" ||
        ($0.name.hasPrefix("MacBook ") && $0.name.hasSuffix(" Microphone"))
    }) {
        return builtIn
    }

    return devices[0]
}

private func monotonicNs() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

private func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var payload = fields
    payload["event"] = event
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

private func writeWav(samples: [Int16], sampleRate: Int, to path: String) throws {
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let bytesPerSample = Int(bitsPerSample / 8)
    let dataBytes = samples.count * bytesPerSample

    var wav = Data(capacity: 44 + dataBytes)
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

    samples.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(baseAddress).assumingMemoryBound(to: UInt8.self),
            count: dataBytes
        )
        wav.append(contentsOf: bytes)
    }
    try wav.write(to: URL(fileURLWithPath: path), options: .atomic)
}

private final class WarmRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let firstBuffer = DispatchSemaphore(value: 0)
    private let preRollMs: Int

    private var sampleRate = 0
    private var ring: [Int16] = []
    private var ringCount = 0
    private var ringWriteIndex = 0
    private var recording = false
    private var recorded: [Int16] = []
    private var outputPath = "/tmp/whisper-dictate.wav"
    private var hasSeenFirstBuffer = false

    init(configuration: Configuration) throws {
        preRollMs = max(0, configuration.preRollMs)
        let device = try selectInputDevice(requestedName: configuration.deviceName)
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else { throw RecorderError.noInputDevice }
        var deviceID = device.id
        try check(
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            "select input device"
        )

        let format = input.outputFormat(forBus: 0)
        sampleRate = Int(format.sampleRate)
        ring = [Int16](repeating: 0, count: max(1, sampleRate * preRollMs / 1000))

        let bootStarted = monotonicNs()
        input.installTap(onBus: 0, bufferSize: 256, format: format) { [weak self] buffer, _ in
            self?.accept(buffer)
        }
        engine.prepare()
        try engine.start()
        guard firstBuffer.wait(timeout: .now() + 3) == .success else {
            throw RecorderError.firstBufferTimeout
        }

        emit("ready", [
            "boot_to_first_buffer_ms": Double(monotonicNs() - bootStarted) / 1_000_000,
            "device": device.name,
            "pre_roll_ms": preRollMs,
            "sample_rate": sampleRate,
        ])
    }

    private func accept(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let incoming = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))

        lock.lock()
        for sample in incoming {
            let pcmSample = Int16(max(-1, min(1, sample)) * Float(Int16.max))
            ring[ringWriteIndex] = pcmSample
            ringWriteIndex = (ringWriteIndex + 1) % ring.count
            ringCount = min(ring.count, ringCount + 1)
            if recording { recorded.append(pcmSample) }
        }
        if !hasSeenFirstBuffer {
            hasSeenFirstBuffer = true
            firstBuffer.signal()
        }
        lock.unlock()
    }

    private func ringSnapshot() -> [Int16] {
        if ringCount < ring.count {
            return Array(ring[0..<ringCount])
        }
        return Array(ring[ringWriteIndex..<ring.count]) + Array(ring[0..<ringWriteIndex])
    }

    func start(path: String?) {
        let received = monotonicNs()
        lock.lock()
        if let path { outputPath = path }
        recorded = ringSnapshot()
        let buffered = recorded.count
        recording = true
        lock.unlock()
        emit("started", [
            "command_to_armed_ms": Double(monotonicNs() - received) / 1_000_000,
            "pre_roll_samples": buffered,
        ])
    }

    func stop() throws {
        let received = monotonicNs()
        lock.lock()
        recording = false
        let captured = recorded
        let path = outputPath
        lock.unlock()

        let wavStarted = monotonicNs()
        try writeWav(samples: captured, sampleRate: sampleRate, to: path)
        emit("stopped", [
            "command_to_wav_ms": Double(monotonicNs() - received) / 1_000_000,
            "path": path,
            "samples": captured.count,
            "wav_write_ms": Double(monotonicNs() - wavStarted) / 1_000_000,
        ])
    }

    func state() {
        lock.lock()
        let current = recording ? "recording" : "warm"
        let buffered = ringCount
        lock.unlock()
        emit("state", ["state": current, "ring_samples": buffered])
    }

    func shutdown() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}

do {
    let configuration = Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
    let recorder = try WarmRecorder(configuration: configuration)
    while let line = readLine() {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first?.uppercased() ?? "" {
        case "START": recorder.start(path: parts.count == 2 ? parts[1] : nil)
        case "STOP": try recorder.stop()
        case "STATE": recorder.state()
        case "QUIT":
            recorder.shutdown()
            emit("exited")
            exit(0)
        default: emit("error", ["message": "unknown recorder command"])
        }
    }
    recorder.shutdown()
} catch {
    emit("error", ["message": String(describing: error)])
    exit(1)
}
