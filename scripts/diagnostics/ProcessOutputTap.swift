import AVFoundation
import CoreAudio
import Foundation

@MainActor final class OutputTap {
    var tap: AudioObjectID = 0
    var aggregate: AudioObjectID = 0
    var io: AudioDeviceIOProcID?
    let signal = Signal()
    func check(_ status: OSStatus) throws { if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) } }
    func start() throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid(); var process: AudioObjectID = 0; var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process))
        guard process != 0 else { throw NSError(domain: "No process audio", code: 1) }
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.name = "Horse cue test only"; description.isPrivate = true; description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap))
        var asbd = AudioStreamBasicDescription(); size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address.mSelector = kAudioTapPropertyFormat
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd))
        let format = AVAudioFormat(streamDescription: &asbd)!
        let config: [String: Any] = [kAudioAggregateDeviceNameKey: "Horse cue test", kAudioAggregateDeviceUIDKey: UUID().uuidString, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate))
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil, Self.callback(format, signal.tap())))
        try check(AudioDeviceStart(aggregate, io))
        print("PROCESS_TAP \(format)")
    }
    nonisolated static func callback(_ format: AVAudioFormat, _ receive: @escaping AVAudioNodeTapBlock) -> AudioDeviceIOBlock {
        { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            receive(buffer, AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
        }
    }
    func stop() {
        if let io { AudioDeviceStop(aggregate, io); AudioDeviceDestroyIOProcID(aggregate, io) }; io = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
}
