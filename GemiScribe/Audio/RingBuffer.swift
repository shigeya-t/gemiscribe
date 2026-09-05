import Foundation

/// Fixed-capacity FIFO of audio samples that decouples each capture callback
/// from the mixer's steady 100 ms pull. Overflow drops the oldest samples,
/// which is the right trade for live transcription: never block the audio thread.
struct RingBuffer {
    private var storage: [Float]
    private var readIndex = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: max(1, capacity))
    }

    var capacity: Int { storage.count }

    mutating func write(_ samples: [Float]) {
        for sample in samples {
            let writeIndex = (readIndex + count) % capacity
            storage[writeIndex] = sample
            if count == capacity {
                readIndex = (readIndex + 1) % capacity // overwrite oldest
            } else {
                count += 1
            }
        }
    }

    /// Reads exactly `frames` samples, zero-padding if the buffer has run dry.
    mutating func read(frames: Int) -> [Float] {
        var result = [Float](repeating: 0, count: frames)
        let available = min(frames, count)
        for index in 0..<available {
            result[index] = storage[(readIndex + index) % capacity]
        }
        readIndex = (readIndex + available) % capacity
        count -= available
        return result
    }

    mutating func removeAll() {
        readIndex = 0
        count = 0
    }
}
