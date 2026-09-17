import Foundation

enum VoiceActionTranscript {
    /// Fresh user speech since the previous delegation, including fragments interleaved
    /// with spoken backchannels. Assistant speech and already delegated text are excluded.
    static func currentUtterance(
        _ fragments: [(speaker: LiveTranscriptSegment.Speaker, text: String, endMS: Double)],
        afterOffset: Double = -1, throughOffset: Double = .greatestFiniteMagnitude
    ) -> String {
        let utterance = fragments.filter {
            $0.speaker == .user && $0.endMS.isFinite && $0.endMS > afterOffset && $0.endMS <= throughOffset
        }.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject instead of truncating: dropping a prefix could turn a negation into a command.
        return utterance.utf8.count <= 4000 ? utterance : ""
    }
}
