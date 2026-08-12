import AVFAudio

protocol MicrophoneAuthorizing: Sendable {
    func requestAccess() async -> Bool
}

struct MicrophonePermissionService: MicrophoneAuthorizing {
    func requestAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
