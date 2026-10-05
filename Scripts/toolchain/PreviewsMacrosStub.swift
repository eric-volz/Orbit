// No-op stand-in for Xcode's PreviewsMacros compiler plugin (CLT-only builds).
// Speaks the compiler plugin wire protocol: 8-byte little-endian length + JSON.
import Foundation

func readExactly(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        let chunk = FileHandle.standardInput.readData(ofLength: count - data.count)
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

func send(_ json: String) {
    let payload = Data(json.utf8)
    var length = UInt64(payload.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &length, count: 8))
    FileHandle.standardOutput.write(payload)
}

while let header = readExactly(8) {
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    guard let body = readExactly(Int(length)),
          let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let kind = message.keys.first else { break }
    switch kind {
    case "getCapability":
        send(#"{"getCapabilityResult":{"capability":{"protocolVersion":7}}}"#)
    case "expandFreestandingMacro", "expandAttachedMacro":
        send(#"{"expandMacroResult":{"expandedSource":"","diagnostics":[]}}"#)
    case "loadPluginLibrary":
        send(#"{"loadPluginLibraryResult":{"loaded":false,"diagnostics":[]}}"#)
    default:
        break
    }
}
