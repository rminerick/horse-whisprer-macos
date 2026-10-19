import XCTest
@testable import HorseWhisprer

final class TranscriptCopyFeedbackTests: XCTestCase {
    func testRepeatedCopyKeepsFeedbackUntilLatestAttemptExpires() {
        var feedback = TranscriptCopyFeedback()
        feedback.record(success: true)
        let first = feedback.generation
        feedback.record(success: true)
        feedback.reset(generation: first)
        XCTAssertEqual(feedback.succeeded, true)
        feedback.reset(generation: feedback.generation)
        XCTAssertNil(feedback.succeeded)
    }

    func testFailedCopyDoesNotKeepEarlierSuccessFeedback() {
        var feedback = TranscriptCopyFeedback()
        feedback.record(success: true)
        let first = feedback.generation
        feedback.record(success: false)
        feedback.reset(generation: first)
        XCTAssertEqual(feedback.succeeded, false)
        feedback.record(success: true)
        XCTAssertEqual(feedback.succeeded, true)
    }
}
