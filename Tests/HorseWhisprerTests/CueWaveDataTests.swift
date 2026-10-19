import AVFoundation
import XCTest
@testable import HorseWhisprer

final class CueWaveDataTests: XCTestCase {
    func testEncodedCuePreservesStereoSignalAndLeadingSilence() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let left: [Float] = [0.2, -0.3, 0.5, -0.7]
        let right: [Float] = [-0.1, 0.4, -0.6, 0.8]
        for i in 0..<4 { buffer.floatChannelData![0][i] = left[i]; buffer.floatChannelData![1][i] = right[i] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try CueWaveData.encode(buffer, leadingSilence: 0.01, trailingSilence: 0.02).write(to: url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 244)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 244))
        try file.read(into: decoded)
        for channel in 0..<2 {
            let expected = channel == 0 ? left : right
            for i in 0..<80 { XCTAssertEqual(decoded.floatChannelData![channel][i], 0) }
            for i in 0..<4 { XCTAssertEqual(decoded.floatChannelData![channel][80+i], expected[i], accuracy: 0.0001) }
            for i in 84..<244 { XCTAssertEqual(decoded.floatChannelData![channel][i], 0) }
        }
    }
}
