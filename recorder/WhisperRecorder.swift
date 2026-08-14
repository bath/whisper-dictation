import AudioToolbox
import AudioUnit
import CoreAudio
import Darwin
import Foundation

private struct Configuration {
    var deviceName: String?

    init(arguments: [String]) {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--device" where index + 1 < arguments.count:
                deviceName = arguments[index + 1]
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

private func deviceIsRunning(_ device: AudioDevice) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &running) == noErr else {
        return false
    }
    return running != 0
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

private let recorderInputCallback: AURenderCallback = { refCon, flags, timestamp, _, frames, _ in
    let recorder = Unmanaged<ColdRecorder>.fromOpaque(refCon).takeUnretainedValue()
    return recorder.receive(flags: flags, timestamp: timestamp, frames: frames)
}

private final class ColdRecorder: @unchecked Sendable {
    private let device: AudioDevice
    private let audioUnit: AudioUnit
    private let sampleRate: Int
    private let maximumFrames: UInt32
    private let renderStorage: UnsafeMutableRawPointer
    private let renderBuffers: UnsafeMutableAudioBufferListPointer
    private let lock = NSLock()

    private var firstBufferWaiter: DispatchSemaphore?
    private var recording = false
    private var deviceWasRunningBeforeCapture = false
    private var recorded: [Int16] = []
    private var outputPath = "/tmp/whisper-dictate.wav"

    init(configuration: Configuration) throws {
        device = try selectInputDevice(requestedName: configuration.deviceName)

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RecorderError.noInputDevice
        }
        var instance: AudioComponentInstance?
        try check(AudioComponentInstanceNew(component, &instance), "create HAL input unit")
        guard let instance else { throw RecorderError.noInputDevice }
        audioUnit = instance

        var enabled: UInt32 = 1
        try check(
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enabled,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "enable HAL input"
        )
        var disabled: UInt32 = 0
        try check(
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disabled,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "disable HAL output"
        )
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

        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                1,
                &deviceFormat,
                &formatSize
            ),
            "read input format"
        )
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        try check(
            AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &clientFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            "set mono PCM input format"
        )
        sampleRate = Int(clientFormat.mSampleRate)

        var sliceFrames: UInt32 = 0
        var sliceSize = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioUnitGetProperty(
                audioUnit,
                kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global,
                0,
                &sliceFrames,
                &sliceSize
            ),
            "read maximum input slice"
        )
        maximumFrames = max(4096, sliceFrames)
        renderStorage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(maximumFrames) * MemoryLayout<Int16>.size,
            alignment: MemoryLayout<Int16>.alignment
        )
        renderBuffers = AudioBufferList.allocate(maximumBuffers: 1)
        renderBuffers[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: maximumFrames * UInt32(MemoryLayout<Int16>.size),
            mData: renderStorage
        )

        var callback = AURenderCallbackStruct(
            inputProc: recorderInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            "set input callback"
        )
        try check(AudioUnitInitialize(audioUnit), "initialize HAL input")

        emit("ready", [
            "backend": "AUHAL",
            "device": device.name,
            "microphone_active": deviceIsRunning(device),
            "sample_rate": sampleRate,
        ])
    }

    func receive(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        guard frames <= maximumFrames else { return kAudio_ParamError }
        renderBuffers[0].mDataByteSize = frames * UInt32(MemoryLayout<Int16>.size)
        let status = AudioUnitRender(
            audioUnit,
            flags,
            timestamp,
            1,
            frames,
            renderBuffers.unsafeMutablePointer
        )
        guard status == noErr else { return status }

        let samples = UnsafeBufferPointer(
            start: renderStorage.assumingMemoryBound(to: Int16.self),
            count: Int(frames)
        )
        lock.lock()
        if recording { recorded.append(contentsOf: samples) }
        let waiter = firstBufferWaiter
        firstBufferWaiter = nil
        lock.unlock()
        waiter?.signal()
        return noErr
    }

    func start(path: String?) throws {
        guard !recording else {
            emit("error", ["message": "recorder is already active"])
            return
        }
        let received = monotonicNs()
        deviceWasRunningBeforeCapture = deviceIsRunning(device)
        lock.lock()
        if let path { outputPath = path }
        recorded = []
        recorded.reserveCapacity(sampleRate * 60)
        recording = true
        let firstBuffer = DispatchSemaphore(value: 0)
        firstBufferWaiter = firstBuffer
        lock.unlock()

        do {
            try check(AudioOutputUnitStart(audioUnit), "start HAL input")
            guard firstBuffer.wait(timeout: .now() + 3) == .success else {
                throw RecorderError.firstBufferTimeout
            }
        } catch {
            AudioOutputUnitStop(audioUnit)
            lock.lock()
            recording = false
            firstBufferWaiter = nil
            lock.unlock()
            throw error
        }

        emit("started", [
            "command_to_first_buffer_ms": Double(monotonicNs() - received) / 1_000_000,
            "microphone_active": deviceIsRunning(device),
            "sample_rate": sampleRate,
        ])
    }

    func stop() throws {
        let received = monotonicNs()
        lock.lock()
        recording = false
        lock.unlock()

        let releaseStarted = monotonicNs()
        try check(AudioOutputUnitStop(audioUnit), "stop HAL input")
        if !deviceWasRunningBeforeCapture {
            let releaseDeadline = releaseStarted + 250_000_000
            while deviceIsRunning(device) && monotonicNs() < releaseDeadline {
                usleep(1_000)
            }
        }

        lock.lock()
        let captured = recorded
        let path = outputPath
        lock.unlock()

        let wavStarted = monotonicNs()
        try writeWav(samples: captured, sampleRate: sampleRate, to: path)
        emit("stopped", [
            "command_to_wav_ms": Double(monotonicNs() - received) / 1_000_000,
            "microphone_active": deviceIsRunning(device),
            "microphone_release_ms": Double(wavStarted - releaseStarted) / 1_000_000,
            "path": path,
            "samples": captured.count,
            "wav_write_ms": Double(monotonicNs() - wavStarted) / 1_000_000,
        ])
    }

    func state() {
        lock.lock()
        let current = recording ? "recording" : "idle"
        lock.unlock()
        emit("state", [
            "state": current,
            "microphone_active": deviceIsRunning(device),
        ])
    }

    func shutdown() {
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        renderBuffers.unsafeMutablePointer.deallocate()
        renderStorage.deallocate()
    }
}

do {
    let configuration = Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
    let recorder = try ColdRecorder(configuration: configuration)
    while let line = readLine() {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first?.uppercased() ?? "" {
        case "START": try recorder.start(path: parts.count == 2 ? parts[1] : nil)
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
