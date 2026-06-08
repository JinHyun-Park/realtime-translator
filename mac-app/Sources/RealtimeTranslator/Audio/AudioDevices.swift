import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
}

/// Enumerates CoreAudio devices so the UI can offer mic/output pickers.
enum AudioDevices {
    static func all() -> [AudioDevice] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.map { id in
            AudioDevice(
                id: id,
                name: name(of: id),
                hasInput: channels(of: id, scope: kAudioObjectPropertyScopeInput) > 0,
                hasOutput: channels(of: id, scope: kAudioObjectPropertyScopeOutput) > 0
            )
        }
    }

    static func inputs() -> [AudioDevice] { all().filter { $0.hasInput } }
    static func outputs() -> [AudioDevice] { all().filter { $0.hasOutput } }

    private static func name(of id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let st = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        return st == noErr ? (cf as String) : "Device \(id)"
    }

    private static func channels(of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let bl = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bl.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bl) == noErr else { return 0 }
        let abl = bl.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Watches CoreAudio for hot-plug changes (device list, default in/out) and
/// calls `onChange` on the main queue whenever they change — so the pickers
/// stay live instead of being read once at launch.
final class AudioDeviceWatcher {
    private var onChange: (() -> Void)?
    private let queue = DispatchQueue.main
    // We listen on three properties: the device set, and the default in/out.
    private var selectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
    ]
    private var block: AudioObjectPropertyListenerBlock?

    func start(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange?()
        }
        self.block = block
        for sel in selectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: sel,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, queue, block
            )
        }
    }

    func stop() {
        guard let block else { return }
        for sel in selectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: sel,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, queue, block
            )
        }
        self.block = nil
        self.onChange = nil
    }

    deinit { stop() }
}
