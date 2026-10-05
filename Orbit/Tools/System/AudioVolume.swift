import AudioToolbox
import CoreAudio
import Foundation

/// The Mac's current output device as `set_volume` sees it.
struct AudioOutputDevice: Sendable, Hashable {
    /// As macOS names it ("MacBook Pro-Lautsprecher").
    var name: String
    /// 0…1; nil when the device has no volume Orbit can read.
    var volume: Double?
    /// nil when the device cannot be muted.
    var isMuted: Bool?
    var canSetVolume: Bool
    var canMute: Bool
    /// Which device it is (Core Audio's device UID), also when two have the
    /// same name; nil when unknown.
    var identifier: String?

    /// The volume in percent (0 to 100), rounded.
    var percent: Int? {
        volume.map { AudioVolumeLevel.percent(fromScalar: $0) }
    }
}

enum AudioVolumeError: Error, Sendable, Hashable {
    /// Not in this session (a DEBUG session restricted with ORBIT_DEBUG_FILE_SCOPE).
    case unavailable
    /// macOS has no output device right now.
    case noOutputDevice
    /// The device does not let macOS change its volume (e.g. HDMI or digital outputs).
    case volumeNotAdjustable(deviceName: String)
    /// The device cannot be muted.
    case cannotMute(deviceName: String)
    /// The default output device is another one than the user confirmed
    /// (`deviceName` is the current one's name).
    case deviceChanged(deviceName: String)
    /// Core Audio refused a change (its error code).
    case failed(code: Int32)
}

/// The volume of the default output device. Live: Core Audio (no permission
/// needed); restricted debug sessions change nothing, the DEBUG fake-data mode
/// keeps an invented device, tests use a mock; the real device is never
/// touched in tests.
protocol AudioVolumeControlling: Sendable {
    func outputDevice() async throws -> AudioOutputDevice
    /// Sets the volume (0…1) and/or muting of the default output device and
    /// returns the device afterwards, only while that is still the device
    /// `deviceID` names (the one the user confirmed; nil: whichever it is),
    /// checked on the same lookup that changes it. Throws `AudioVolumeError`
    /// (`.deviceChanged` for another device). The device's volume and muting
    /// as read afterwards may still be the old ones: Core Audio applies a
    /// change asynchronously.
    func set(volume: Double?, muted: Bool?, on deviceID: String?) async throws -> AudioOutputDevice
}

/// Changes nothing (DEBUG sessions restricted with ORBIT_DEBUG_FILE_SCOPE, and
/// the default of `AppServices`).
struct UnavailableAudioVolume: AudioVolumeControlling {
    func outputDevice() async throws -> AudioOutputDevice { throw AudioVolumeError.unavailable }
    func set(volume: Double?, muted: Bool?, on deviceID: String?) async throws -> AudioOutputDevice {
        throw AudioVolumeError.unavailable
    }
}

/// Volume levels (pure).
enum AudioVolumeLevel {
    static func percent(fromScalar scalar: Double) -> Int {
        Int((min(max(scalar, 0), 1) * 100).rounded())
    }

    static func scalar(fromPercent percent: Int) -> Double {
        Double(min(max(percent, 0), 100)) / 100
    }
}

/// The default output device through Core Audio, read and changed on a
/// background queue: its main ("virtual") volume (or, for devices without
/// one, the volume of their first two channels) and its mute switch. Devices
/// that offer neither (many HDMI and digital outputs) are reported as not
/// adjustable. Logs outcomes and Core Audio's error codes, never device names.
struct LiveAudioVolume: AudioVolumeControlling {
    func outputDevice() async throws -> AudioOutputDevice {
        try await Self.onBackground { try CoreAudioDevice.defaultOutput().snapshot() }
    }

    func set(volume: Double?, muted: Bool?, on deviceID: String?) async throws -> AudioOutputDevice {
        try await Self.onBackground {
            let device = try CoreAudioDevice.defaultOutput()
            let before = device.snapshot()
            if let deviceID, before.identifier != deviceID {
                Log.tools.notice("Core Audio: the default output device changed before the volume was set")
                throw AudioVolumeError.deviceChanged(deviceName: before.name)
            }
            if let volume {
                guard before.canSetVolume else { throw AudioVolumeError.volumeNotAdjustable(deviceName: before.name) }
                try device.setVolume(Float32(min(max(volume, 0), 1)))
            }
            if let muted {
                guard before.canMute else { throw AudioVolumeError.cannotMute(deviceName: before.name) }
                try device.setMuted(muted)
            }
            return device.snapshot()
        }
    }

    private static func onBackground<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        let result: Result<Value, any Error> = await Background.run {
            Result { try work() }
        }
        return try result.get()
    }
}

/// One Core Audio device (live only).
private struct CoreAudioDevice {
    let id: AudioObjectID

    static func defaultOutput() throws -> CoreAudioDevice {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            Log.tools.error("Core Audio: no default output device (\(status))")
            throw AudioVolumeError.noOutputDevice
        }
        return CoreAudioDevice(id: device)
    }

    func snapshot() -> AudioOutputDevice {
        let volumeTarget = self.volumeTarget()
        let volume: Double? = switch volumeTarget {
        case .main: readFloat(Self.mainVolume).map(Double.init)
        case .channels(let channels): channels.compactMap { readFloat(Self.channelVolume($0)) }.max().map(Double.init)
        case nil: nil
        }
        let muted = has(Self.mute) ? readUInt32(Self.mute).map { $0 != 0 } : nil
        return AudioOutputDevice(name: name() ?? "", volume: volume, isMuted: muted, canSetVolume: volumeTarget != nil,
                                 canMute: has(Self.mute) && isSettable(Self.mute),
                                 identifier: uid() ?? "audio-object-\(id)")
    }

    func setVolume(_ volume: Float32) throws {
        switch volumeTarget() {
        case .main:
            try write(volume, to: Self.mainVolume)
        case .channels(let channels):
            for channel in channels {
                try write(volume, to: Self.channelVolume(channel))
            }
        case nil:
            throw AudioVolumeError.volumeNotAdjustable(deviceName: name() ?? "")
        }
    }

    func setMuted(_ muted: Bool) throws {
        var value: UInt32 = muted ? 1 : 0
        var address = Self.mute
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else {
            Log.tools.error("Core Audio: muting failed (\(status))")
            throw AudioVolumeError.failed(code: status)
        }
    }

    // MARK: Properties

    private enum VolumeTarget: Equatable {
        /// The device's main volume.
        case main
        /// The volume of these channels (1 = left, 2 = right).
        case channels([UInt32])
    }

    private static let mainVolume = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                               mScope: kAudioDevicePropertyScopeOutput,
                                                               mElement: kAudioObjectPropertyElementMain)
    private static let mute = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                         mElement: kAudioObjectPropertyElementMain)

    private static func channelVolume(_ channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: channel)
    }

    private func volumeTarget() -> VolumeTarget? {
        if has(Self.mainVolume), isSettable(Self.mainVolume) { return .main }
        let channels = [UInt32(1), 2].filter { has(Self.channelVolume($0)) && isSettable(Self.channelVolume($0)) }
        return channels.isEmpty ? nil : .channels(channels)
    }

    private func has(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(id, &address)
    }

    private func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    private func readFloat(_ address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func readUInt32(_ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func write(_ value: Float32, to address: AudioObjectPropertyAddress) throws {
        var address = address
        var value = value
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        guard status == noErr else {
            Log.tools.error("Core Audio: setting the volume failed (\(status))")
            throw AudioVolumeError.failed(code: status)
        }
    }

    private func name() -> String? {
        string(kAudioObjectPropertyName)
    }

    /// The device's UID: it tells devices apart, also two with the same name.
    private func uid() -> String? {
        string(kAudioDevicePropertyDeviceUID)
    }

    private func string(_ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
