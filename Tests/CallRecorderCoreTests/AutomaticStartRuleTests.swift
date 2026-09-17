import Testing
@testable import CallRecorderCore

/// Starting a recording by itself needs a call, not only a busy microphone.
@Suite("Automatic start rule")
struct AutomaticStartRuleTests {
    private func input(_ pid: Int32, _ bundle: String?) -> AudioActivityDecision.Input {
        AudioActivityDecision.Input(processID: pid, bundleID: bundle)
    }

    @Test("a process that holds the microphone and plays nothing is not a call")
    func microphoneAloneIsNotACall() {
        let inputs = [input(101, "ru.keepcoder.Telegram")]
        #expect(
            AudioActivityDecision.hasExternalInput(
                inputs: inputs, ownProcessID: 9, ignoringNonCallApps: false
            )
        )
        #expect(
            !AudioActivityDecision.hasTwoWayCall(
                inputs: inputs, playingOutput: [], ownProcessID: 9, ignoringNonCallApps: false
            ),
            "a voice message holds the microphone and plays nothing"
        )
    }

    @Test("a process that holds the microphone and plays the other side is a call")
    func twoWayIsACall() {
        let inputs = [input(101, "us.zoom.xos")]
        #expect(
            AudioActivityDecision.hasTwoWayCall(
                inputs: inputs, playingOutput: [101], ownProcessID: 9, ignoringNonCallApps: false
            )
        )
    }

    @Test("the recorder's own audio never qualifies")
    func ownAudioNeverQualifies() {
        let own = [input(9, "local.callrecorder.app")]
        #expect(
            !AudioActivityDecision.hasTwoWayCall(
                inputs: own, playingOutput: [9], ownProcessID: 9, ignoringNonCallApps: false
            )
        )
    }

    @Test("the holder is named for the log, and it is the one that counts")
    func theHolderIsNamed() {
        let inputs = [input(9, "local.callrecorder.app"), input(44, "com.hnc.Discord")]
        #expect(
            AudioActivityDecision.holder(
                inputs: inputs, ownProcessID: 9, ignoringNonCallApps: true
            )?.bundleID == "com.hnc.Discord"
        )
    }

    @Test("the confirmation window is short, and longer than a voice message")
    func theWindowIsSane() {
        #expect(AutomaticRecordingRails.confirmationSeconds >= 3)
        #expect(AutomaticRecordingRails.confirmationSeconds <= 15)
    }
}
