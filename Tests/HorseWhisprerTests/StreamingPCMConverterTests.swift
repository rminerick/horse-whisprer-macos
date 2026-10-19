import AVFoundation
import XCTest
@testable import HorseWhisprer

final class StreamingPCMConverterTests: XCTestCase {
    func testContinuousResamplingPreservesDurationAcrossUnevenChunks() throws {
        for rate in [44_100.0, 48_000.0, 16_000.0] {
            let converter = StreamingPCMConverter()
            let samples = (0..<Int(rate * 3)).map { Float(sin(Double($0) * 2 * .pi * 440 / rate)) }
            var outputCount = 0
            for start in stride(from: 0, to: samples.count, by: 4096) {
                let chunk = DictationAudioChunk(samples: Array(samples[start..<min(start + 4096, samples.count)]), sampleRate: rate)
                outputCount += try converter.convert(chunk).count
            }
            outputCount += try converter.finish().count
            XCTAssertEqual(Double(outputCount), 48_000, accuracy: 64, "Sample rate \(rate)")
        }
    }

    func testRejectsRouteFormatChangeAndInvalidAudio() throws {
        let converter = StreamingPCMConverter()
        _ = try converter.convert(.init(samples: [0, 1], sampleRate: 48_000))
        XCTAssertThrowsError(try converter.convert(.init(samples: [0, 1], sampleRate: 44_100)))
        XCTAssertThrowsError(try converter.convert(.init(samples: [], sampleRate: 48_000)))
        XCTAssertThrowsError(try StreamingPCMConverter().convert(.init(samples: [1], sampleRate: .nan)))
    }
}
