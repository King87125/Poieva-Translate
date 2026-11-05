import Foundation

public struct CaptionAudioFrame: Sendable, Equatable {
    public let sampleRate: Int
    public let pcm: Data
    public init(pcm: Data, sampleRate: Int = 24_000) throws {
        guard [16_000, 24_000].contains(sampleRate), !pcm.isEmpty, pcm.count <= sampleRate * 4 / 5, pcm.count.isMultiple(of: 2) else { throw CaptionFailure.audioFormat }
        self.pcm = pcm; self.sampleRate = sampleRate
    }
    public var duration: Double { Double(pcm.count) / Double(sampleRate * 2) }
    public var level: Double {
        let sum: Double = pcm.withUnsafeBytes { bytes in
            var sum = 0.0
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                let value = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
                sum += value * value
            }
            return sum
        }
        return sqrt(sum / Double(pcm.count / 2))
    }
}

/// A small energy gate, not a local speech model. Keeps 400 ms of pre-roll and
/// commits at a pause or an eight-second boundary so translation cannot wait forever.
public struct CaptionAudioGate: Sendable {
    public enum Action: Sendable, Equatable { case append(Data), commit }
    private var preRoll: [CaptionAudioFrame] = []
    private var active = false, duration = 0.0, silence = 0.0
    public let threshold: Double
    public init(threshold: Double = 0.008) { self.threshold = threshold }
    public mutating func consume(_ frame: CaptionAudioFrame) -> [Action] {
        let voiced = frame.level >= threshold
        if !active {
            if !voiced {
                preRoll.append(frame)
                while preRoll.reduce(0, { $0 + $1.duration }) > 0.4, !preRoll.isEmpty { preRoll.removeFirst() }
                return []
            }
            active = true; duration = preRoll.reduce(0, { $0 + $1.duration }); silence = 0
            let actions = preRoll.map { Action.append($0.pcm) }; preRoll = []
            duration += frame.duration
            return actions + [.append(frame.pcm)]
        }
        duration += frame.duration; silence = voiced ? 0 : silence + frame.duration
        if silence >= 0.6 || duration >= 8 {
            active = false; duration = 0; silence = 0; preRoll = []
            return [.append(frame.pcm), .commit]
        }
        return [.append(frame.pcm)]
    }
}
