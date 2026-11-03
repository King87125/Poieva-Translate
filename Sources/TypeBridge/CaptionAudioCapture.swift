import AppKit
import AVFoundation
import CoreAudio
import TypeBridgeCore

/// Runs conversion on the audio callback queue. The output is always mono
/// little-endian PCM16 / 24 kHz, delivered in 200 ms packets with bounded buffering.
private final class CaptionPCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private var pending = Data()
    private let continuation: AsyncThrowingStream<CaptionAudioFrame, Error>.Continuation
    init(input: AVAudioFormat, continuation: AsyncThrowingStream<CaptionAudioFrame, Error>.Continuation) throws {
        guard input.sampleRate > 0, input.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { throw CaptionFailure.audioFormat }
        self.converter = converter; self.output = output; self.continuation = continuation
    }
    func consume(_ input: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 24_000 / input.format.sampleRate) + 64)
        guard capacity <= 48_000, let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { continuation.finish(throwing: CaptionFailure.audioFormat); return }
        var supplied = false, error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard status != .error, error == nil else { continuation.finish(throwing: CaptionFailure.audioFormat); return }
        let bytes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let first = bytes.first, let data = first.mData else { return }
        pending.append(data.assumingMemoryBound(to: UInt8.self), count: Int(first.mDataByteSize))
        while pending.count >= 9_600 {
            let packet = pending.prefix(9_600); pending.removeFirst(9_600)
            do {
                if case .dropped = continuation.yield(try CaptionAudioFrame(pcm: Data(packet))) { continuation.finish(throwing: CaptionFailure.backlog); return }
            } catch { continuation.finish(throwing: error); return }
        }
    }
}

@MainActor
final class CaptionAudioCapture {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<CaptionAudioFrame, Error>.Continuation?
    private let queue = DispatchQueue(label: "studio.typebridge.caption-audio", qos: .userInitiated)
    func startSystem(bundleID: String?) throws -> AsyncThrowingStream<CaptionAudioFrame, Error> {
        stop()
        if let bundleID, !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) { throw CaptionFailure.sourceGone }
        var output: AsyncThrowingStream<CaptionAudioFrame, Error>.Continuation!
        let stream = AsyncThrowingStream<CaptionAudioFrame, Error>(bufferingPolicy: .bufferingOldest(20)) { output = $0 }
        continuation = output
        do {
            let description = CATapDescription()
            description.name = "Poieva Live Captions"; description.uuid = UUID(); description.isPrivate = true
            description.isMono = true; description.isMixdown = true; description.muteBehavior = .unmuted
            description.isExclusive = bundleID == nil
            description.bundleIDs = [bundleID ?? Bundle.main.bundleIdentifier ?? "studio.typebridge.mac"]
            description.isProcessRestoreEnabled = true
            guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { throw CaptionFailure.capture }
            var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr,
                  let inputFormat = AVAudioFormat(streamDescription: &format) else { throw CaptionFailure.audioFormat }
            let converter = try CaptionPCMConverter(input: inputFormat, continuation: output)
            let properties: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Poieva Live Captions", kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            guard AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregate) == noErr else { throw CaptionFailure.capture }
            let result = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, queue) { _, input, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: input, deallocator: nil) else { return }
                converter.consume(buffer)
            }
            guard result == noErr, let ioProc, AudioDeviceStart(aggregate, ioProc) == noErr else { throw CaptionFailure.capture }
            let capturedTap = tap
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                var next = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                var property = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                if AudioObjectGetPropertyData(capturedTap, &property, 0, nil, &size, &next) != noErr || AVAudioFormat(streamDescription: &next) != inputFormat {
                    output.finish(throwing: CaptionFailure.audioFormat)
                }
            }
            if AudioObjectAddPropertyListenerBlock(tap, &address, queue, listener) == noErr { formatListener = listener }
            return stream
        } catch { stop(); throw error }
    }
    func startMicrophone() async throws -> AsyncThrowingStream<CaptionAudioFrame, Error> {
        stop()
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        try Task.checkCancellation()
        guard allowed else { throw CaptionFailure.microphone }
        var output: AsyncThrowingStream<CaptionAudioFrame, Error>.Continuation!
        let stream = AsyncThrowingStream<CaptionAudioFrame, Error>(bufferingPolicy: .bufferingOldest(20)) { output = $0 }
        continuation = output
        let engine = AVAudioEngine(), format = engine.inputNode.outputFormat(forBus: 0)
        let converter = try CaptionPCMConverter(input: format, continuation: output)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in converter.consume(buffer) }
        self.engine = engine
        do { engine.prepare(); try engine.start(); return stream }
        catch { stop(); throw CaptionFailure.microphone }
    }
    func stop() {
        if let formatListener, tap != 0 {
            var property = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(tap, &property, queue, formatListener); self.formatListener = nil
        }
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop(); self.engine = nil }
        if let ioProc, aggregate != 0 { AudioDeviceStop(aggregate, ioProc); AudioDeviceDestroyIOProcID(aggregate, ioProc) }
        ioProc = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        continuation?.finish(); continuation = nil
    }
    /// Explicit file replay is useful for checking an API without recording the
    /// desktop or microphone. It uses the same resampling and transport pipeline.
    static func replay(_ url: URL) throws -> AsyncThrowingStream<CaptionAudioFrame, Error> {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, Double(file.length) / file.processingFormat.sampleRate <= 60 else { throw CaptionFailure.audioFormat }
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(20)) { continuation in
            let task = Task.detached {
                do {
                    let converter = try CaptionPCMConverter(input: file.processingFormat, continuation: continuation)
                    while file.framePosition < file.length, !Task.isCancelled {
                        let frames = AVAudioFrameCount(min(4096, file.length - file.framePosition))
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw CaptionFailure.audioFormat }
                        try file.read(into: buffer); converter.consume(buffer)
                        try await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate))
                    }
                    try Task.checkCancellation()
                    // Flush the gate with enough silence to commit a final phrase.
                    for _ in 0..<4 {
                        continuation.yield(try CaptionAudioFrame(pcm: Data(repeating: 0, count: 9600)))
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
