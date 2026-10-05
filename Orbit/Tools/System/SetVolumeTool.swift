import Foundation

/// `set_volume`: sets the volume of the Mac's output device and/or mutes or
/// unmutes it, only after the user confirmed it on a card. Before the card,
/// the device is checked: one whose volume macOS cannot change never asks.
/// The change goes only to the device the card named.
struct SetVolumeTool: Tool {
    /// Display-only argument the card shows (the device's name): set by
    /// `prepareForConfirmation`, never by the model (tool-private).
    static let deviceKey = "_device"
    /// The device the card names (its identifier, tool-private): the volume
    /// changes only while it is still the output device.
    static let deviceIDKey = "_device_id"
    /// The level before the change, for the card (tool-private).
    static let currentLevelKey = "_current_level"
    /// Whether the device was muted before the change, for the card (tool-private).
    static let currentMutedKey = "_current_muted"
    /// Points "louder" or "quieter" means, as the description tells the model.
    static let step = 15

    let context: SystemToolContext

    let name = "set_volume"
    var displayName: String { String(localized: "Change volume") }
    var description: String {
        """
        Sets the output volume of the Mac's current output device (0 to 100%) and/or mutes or unmutes it, only after \
        the user confirmed it on a card, which shows the current and the new level; they can still change the new \
        one there. Use it when the user asks to make the sound louder or quieter, set a volume, mute or unmute. Give \
        'level' (0 to 100) for a volume the user names. For "louder" ("lauter") or "quieter" ("leiser") give 'change' \
        instead: about +\(Self.step) or -\(Self.step) points (more for "much louder"); Orbit adds it to the current \
        level, so do not ask the user for a number. 'muted' (true/false) mutes or unmutes; a 'level' above 0 or a \
        positive 'change' also unmutes a muted device unless 'muted' is true, while a negative 'change' keeps it \
        muted (it only lowers the level it has once unmuted). Some devices (e.g. HDMI or digital outputs) do not let \
        macOS change their volume: then nothing changes and you get an error.
        """
    }
    var inputSchema: JSONSchema {
        .object(properties: [
            "level": .integer(description: "The volume in percent, 0 to 100.", minimum: 0, maximum: 100),
            "change": .integer(description: "Instead of 'level': points to add to the current volume, e.g. \(Self.step) for louder or -\(Self.step) for quieter.",
                               minimum: -100, maximum: 100),
            "muted": .boolean(description: "true mutes the output, false unmutes it."),
        ])
    }
    let riskLevel: ToolRiskLevel = .write
    let category: ToolCategory = .system

    func statusText(for arguments: ToolArguments) -> String {
        String(localized: "Changing the volume…")
    }

    // MARK: Confirmation

    func prepareForConfirmation(_ arguments: ToolArguments) async throws -> ToolArguments {
        let device = try await perform { try await context.volume.outputDevice() }
        let request = try Request(arguments, current: device)
        // After the user edited the card: still the device it named?
        try Self.check(device, isTheOneIn: arguments)
        let change = try request.change(for: device)
        var values: [String: JSONValue] = [Self.deviceKey: .string(device.name)]
        if let identifier = device.identifier { values[Self.deviceIDKey] = .string(identifier) }
        if let level = change.level {
            values["level"] = .number(Double(level))
            if let current = device.percent {
                values[Self.currentLevelKey] = .number(Double(current))
                if device.isMuted == true { values[Self.currentMutedKey] = .bool(true) }
            }
        }
        if let muted = change.muted { values["muted"] = .bool(muted) }
        return ToolArguments(values)
    }

    func confirmationRequest(for arguments: ToolArguments) -> ConfirmationRequest {
        let level = (try? arguments.optionalInt("level")) ?? nil
        let muted = arguments["muted"]?.boolValue
        var fields: [ConfirmationField] = []
        if let level {
            fields.append(ConfirmationField(id: "level", label: String(localized: "Volume (0 to 100)"), value: String(level),
                                            kind: .text))
            if let current = (try? arguments.optionalInt(Self.currentLevelKey)) ?? nil {
                // "50% (muted)": a muted device says so; the level alone would sound like it can be heard.
                let value = arguments[Self.currentMutedKey]?.boolValue == true
                    ? String(format: String(localized: "%lld%% (muted)"), current)
                    : String(format: String(localized: "%lld%%"), current)
                fields.append(ConfirmationField(id: Self.currentLevelKey, label: String(localized: "Current"), value: value,
                                                kind: .readOnly))
            }
        }
        if let muted {
            fields.append(ConfirmationField(id: "muted", label: String(localized: "Sound"),
                                            value: muted ? String(localized: "Off") : String(localized: "On"), kind: .readOnly))
        }
        if let device = arguments.optionalString(Self.deviceKey) {
            fields.append(ConfirmationField(id: Self.deviceKey, label: String(localized: "Output device"), value: device,
                                            kind: .readOnly))
        }
        let message = level == nil && muted == true ? String(localized: "Orbit mutes the sound.")
            : String(localized: "Orbit sets the volume of your output device.")
        return ConfirmationRequest(toolName: name, riskLevel: riskLevel, title: String(localized: "Change volume"),
                                   message: message, fields: fields, confirmLabel: String(localized: "Set"))
    }

    // MARK: Run

    func run(arguments: ToolArguments) async throws -> ToolResult {
        let device = try await perform { try await context.volume.outputDevice() }
        let request = try Request(arguments, current: device)
        try Self.check(device, isTheOneIn: arguments)
        let change = try request.change(for: device)
        // Only on the device the card named, or, without a card, the one just checked.
        let deviceID = arguments.optionalString(Self.deviceIDKey) ?? device.identifier
        let after = try await perform {
            try await context.volume.set(volume: change.level.map(AudioVolumeLevel.scalar(fromPercent:)), muted: change.muted,
                                         on: deviceID)
        }
        return Self.result(after, change: change, before: device)
    }

    /// Refuses when the arguments name another device than `device` (the
    /// output device changed while the card waited).
    private static func check(_ device: AudioOutputDevice, isTheOneIn arguments: ToolArguments) throws {
        guard let confirmed = arguments.optionalString(deviceIDKey), device.identifier != confirmed else { return }
        throw toolError(.deviceChanged(deviceName: device.name))
    }

    private func perform<Value: Sendable>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch let error as AudioVolumeError {
            throw Self.toolError(error)
        }
    }

    static func toolError(_ error: AudioVolumeError) -> ToolError {
        switch error {
        case .unavailable:
            .unavailable("Changing the volume is not available in this debug session (ORBIT_DEBUG_FILE_SCOPE is set without ORBIT_DEBUG_FAKE_PERSONAL_DATA).")
        case .noOutputDevice:
            .failed("The Mac has no sound output device right now. Nothing changed.")
        case .volumeNotAdjustable(let device):
            .failed("The current output device\(shown(device)) does not let macOS change its volume (e.g. an HDMI or digital output). Nothing changed; the user can change it on the device itself.")
        case .cannotMute(let device):
            .failed("The current output device\(shown(device)) cannot be muted by macOS. Nothing changed.")
        case .deviceChanged(let device):
            .failed("The output device changed since the user saw the card: it is now\(shown(device)). Nothing changed. Ask the user again before you set the volume of this device.")
        case .failed(let code):
            .failed("macOS refused to change the volume (Core Audio error \(code)).")
        }
    }

    /// ` "MacBook Pro-Lautsprecher"`, or nothing for a device without a name.
    private static func shown(_ device: String) -> String {
        device.isEmpty ? "" : " \"\(TurnContext.inline(device, maxCharacters: 100))\""
    }

    /// ` The current volume of the output device "…" is 50 %.` (or muted), nothing without a device.
    static func currentState(of device: AudioOutputDevice?) -> String {
        guard let device else { return "" }
        let level = device.percent.map { "is \($0) %" } ?? "cannot be read"
        return " The current volume of the output device\(shown(device.name)) \(level)\(device.isMuted == true ? " (muted)" : "")."
    }

    /// What changed: the level and muting that were set. Core Audio applies
    /// a change asynchronously (Bluetooth, AirPlay, USB), so the device read
    /// right after it may still report the old ones; its name comes from it.
    static func result(_ device: AudioOutputDevice, change: Request.Change, before: AudioOutputDevice? = nil) -> ToolResult {
        let percent = change.level ?? device.percent
        let isMuted = change.muted ?? (device.isMuted == true)
        var state: String
        if isMuted {
            // A level set on a muted device ("quieter" keeps it muted) is the one it has once unmuted.
            state = change.level.map { "at \($0) % and muted" } ?? "muted"
        } else {
            state = percent.map { "at \($0) %" } ?? "changed"
            if change.muted == false { state += ", unmuted" }
        }
        if change.level != nil, let previous = before?.percent { state += " (before: \(previous) %)" }
        let deviceText = device.name.isEmpty ? "the output device" : "the output device \"\(TurnContext.inline(device.name, maxCharacters: 100))\""
        let title: String
        let symbol: String
        if isMuted {
            title = String(localized: "Sound off")
            symbol = "speaker.slash.fill"
        } else if let percent {
            title = String(format: String(localized: "Volume: %lld%%"), percent)
            symbol = percent == 0 ? "speaker.fill" : (percent < 34 ? "speaker.wave.1.fill" : (percent < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
        } else {
            title = String(localized: "Sound on")
            symbol = "speaker.wave.2.fill"
        }
        let summary: String = if isMuted, let level = change.level {
            String(format: String(localized: "Volume set to %lld%%, sound off"), level)
        } else if isMuted {
            String(localized: "Sound muted")
        } else if change.level != nil, let percent {
            String(format: String(localized: "Volume set to %lld%%"), percent)
        } else {
            String(localized: "Sound unmuted")
        }
        return ToolResult(text: "The volume of \(deviceText) is now \(state).",
                          card: .info(InfoItem(title: title, detail: device.name.isEmpty ? nil : device.name, systemImage: symbol)),
                          summary: summary)
    }

    /// The level, change and muting asked for, checked.
    struct Request: Sendable, Hashable {
        var level: Int?
        /// Points to add to the current level ('change').
        var step: Int?
        var muted: Bool?

        /// `current`: the output device, named with its level when nothing was asked for.
        init(_ arguments: ToolArguments, current: AudioOutputDevice? = nil) throws {
            level = try arguments.optionalInt("level")
            step = try arguments.optionalInt("change")
            muted = arguments.has("muted") ? try arguments.bool("muted", default: false) : nil
            guard level != nil || step != nil || muted != nil else {
                throw ToolError.invalidArgument("Give 'level' (0 to 100), 'change' (e.g. \(SetVolumeTool.step) for louder, -\(SetVolumeTool.step) for quieter) or 'muted'."
                    + SetVolumeTool.currentState(of: current))
            }
            guard level == nil || step == nil else {
                throw ToolError.invalidArgument("Give either 'level' or 'change', not both.")
            }
            if let level, !(0...100).contains(level) {
                throw ToolError.invalidArgument("'level' must be between 0 and 100.")
            }
            if let step, !(-100...100).contains(step) {
                throw ToolError.invalidArgument("'change' must be between -100 and 100.")
            }
        }

        /// What changes on `device`: a change is added to its current level
        /// (within 0 to 100); a level above 0 also unmutes a muted device unless
        /// muting was asked for, but "quieter" (a change below 1) keeps it
        /// muted, and only lowers the level it has once unmuted. Throws when
        /// the device cannot do what is asked.
        struct Change: Sendable, Hashable {
            var level: Int?
            var muted: Bool?
        }

        func change(for device: AudioOutputDevice) throws -> Change {
            if level != nil || step != nil, !device.canSetVolume {
                throw SetVolumeTool.toolError(.volumeNotAdjustable(deviceName: device.name))
            }
            var level = level
            if let step {
                guard let current = device.percent else {
                    throw ToolError.invalidArgument("Orbit cannot read the current volume of the output device\(SetVolumeTool.shown(device.name)), so it cannot change it by \(step) points. Give 'level' (0 to 100) instead.")
                }
                level = min(max(current + step, 0), 100)
            }
            var muted = muted
            if muted == nil, let level, device.isMuted == true, device.canMute {
                // Said on the card: "Ton: Aus" stays, or "Ton: An".
                if let step, step < 1 {
                    muted = true
                } else if level > 0 {
                    muted = false
                }
            }
            if muted != nil, !device.canMute { throw SetVolumeTool.toolError(.cannotMute(deviceName: device.name)) }
            return Change(level: level, muted: muted)
        }
    }
}
