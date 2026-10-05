import AppKit

/// Orbit's Photos script (`Resources/AppleScripts/photos-show.applescript`):
/// shows one photo or video in Photos: what a click on a photo card's tile
/// does. Photos' `spotlight` command takes a media item, whose scripting `id`
/// is PhotoKit's localIdentifier (Photos' dictionary maps it to
/// `localIdentifier`); that it reveals the item is a live check. Live through
/// `LiveAppleScriptRunner` (needs Automation: Photos; macOS asks on the first
/// click); tests pass a mock runner, the DEBUG fake-data mode one that records.
struct PhotosService: Sendable {
    static let showScript = AppleScript(name: "photos-show", app: .photos, timeout: .seconds(30))
    static let scripts = [showScript]

    let runner: any AppleScriptRunning

    /// Shows the item in Photos and brings Photos to the front. Throws
    /// `PhotosFailure` or `AppleScriptError`.
    func show(id: String) async throws {
        guard PhotoID.isValid(id) else { throw PhotosFailure.invalidIdentifier }
        let output = try await runner.run(Self.showScript, arguments: [id])
        let answer: ShowAnswer
        do {
            answer = try JSONDecoder().decode(ShowAnswer.self, from: Data(output.utf8))
        } catch {
            Log.tools.error("AppleScript \(Self.showScript.name, privacy: .public) printed output that is not the expected JSON")
            throw AppleScriptError.invalidOutput
        }
        if answer.error == "notFound" { throw PhotosFailure.itemNotFound }
        guard answer.shown == true else { throw AppleScriptError.invalidOutput }
    }

    /// `{"shown": true}` or `{"error": "notFound"}`.
    struct ShowAnswer: Codable, Sendable, Hashable {
        var shown: Bool?
        var error: String?
    }
}

/// What the Photos script reports instead of showing the item.
enum PhotosFailure: Error, Sendable, Hashable {
    /// Photos has no media item with this id (deleted, or not in this library).
    case itemNotFound
    /// Not an identifier PhotoKit gives (never passed to the script).
    case invalidIdentifier
}

/// Whether a text is an identifier as PhotoKit gives them ("UUID/L0/001").
enum PhotoID {
    static let maxLength = 200

    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= maxLength && id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "/-_.".unicodeScalars.contains(scalar))
        }
    }
}

/// Opens Photos, when a photo card cannot show the photo itself. Live:
/// NSWorkspace on the main actor; restricted debug sessions cannot, the DEBUG
/// fake-data mode only records, and tests use a recorder.
protocol PhotosAppOpening: Sendable {
    /// Brings Photos to the front. Throws when it does not open.
    func openPhotos() async throws
}

struct LivePhotosAppOpener: PhotosAppOpening {
    static let bundleID = "com.apple.Photos"

    struct NotInstalled: Error {}

    func openPhotos() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Task { @MainActor in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
                    continuation.resume(throwing: NotInstalled())
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    continuation.resume(with: error.map { .failure($0) } ?? .success(()))
                }
            }
        }
    }
}

/// Opens nothing (DEBUG sessions restricted with ORBIT_DEBUG_FILE_SCOPE, and
/// the default of `AppServices`): Photos is never reached.
struct DisabledPhotosAppOpener: PhotosAppOpening {
    struct Disabled: Error {}

    func openPhotos() async throws {
        throw Disabled()
    }
}
