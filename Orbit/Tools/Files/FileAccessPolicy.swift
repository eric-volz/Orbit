import Darwin
import Foundation

/// Which files the file tools may touch. `read_file`, `open_file` and
/// `reveal_in_finder` check it, and search results are filtered with it, so a
/// denied file never reaches the model, not even its name.
///
/// Denied for every purpose: credential stores and secrets (keychains, SSH and
/// GPG keys, cloud and developer credentials (~/.aws, ~/.kube, ~/.netrc, …),
/// password-manager data, private keys and certificates (.pem, .p12, .key …),
/// `.env` files, browser profiles) and, in a debug session, everything outside
/// ORBIT_DEBUG_FILE_SCOPE. Also denied, except for `reveal_in_finder`:
/// anything in ~/Library other than iCloud Drive and cloud storage, and Orbit's
/// own data folder. Showing such an item in Finder discloses nothing to the
/// model and changes nothing, so revealing is allowed ("show me where Orbit
/// keeps its chats").
///
/// Symlinks and alias spellings are resolved (`FilePath.canonical`) once the
/// path as given passes; the path as given and the resolved one must both be
/// allowed. System alias paths themselves (/System/Volumes/…, /dev/…, /.vol/…,
/// /.nofollow/…) are refused.
struct FileAccessPolicy: Sendable, Hashable {
    enum Purpose: Sendable, Hashable {
        /// Reading contents (`read_file`).
        case read
        /// Opening in the default app (`open_file`).
        case open
        /// Showing in Finder (`reveal_in_finder`).
        case reveal
        /// Listing as a search result.
        case list
    }

    enum Denial: Sendable, Hashable {
        /// A credential store or secret.
        case secret
        /// In ~/Library, outside iCloud Drive and cloud storage.
        case library
        /// Orbit's own data folder.
        case orbitData
        /// Outside the folder a debug session is restricted to.
        case outsideScope
        /// A system alias of a path (/System/Volumes/…, /dev/…, /.vol/…, …).
        case systemPath

        /// Why, for the model.
        var modelMessage: String {
            switch self {
            case .secret:
                """
                Access denied: this file may contain passwords, keys or other credentials (keychains, SSH/GPG keys, \
                cloud credentials, private keys, .env files, password-manager or browser data). Orbit never opens or \
                reads such files. Tell the user; do not try to reach it another way.
                """
            case .library:
                """
                Access denied: Orbit does not access files in ~/Library (app data, mail, caches), except iCloud Drive \
                and cloud storage folders. Tell the user.
                """
            case .orbitData:
                "Access denied: this is Orbit's own data folder."
            case .outsideScope:
                """
                Access denied: this path is outside the folder Orbit may use in this session. Use search_files to \
                find files in the allowed folder.
                """
            case .systemPath:
                """
                Access denied: this is a system path (/System/Volumes/…, /dev/… or a hidden folder at the root such \
                as /.vol or /.nofollow), not a file's usual path. Orbit uses files only under their usual paths, \
                e.g. ~/Documents/… as search_files lists them.
                """
            }
        }
    }

    var homeDirectory: String
    var orbitDataDirectory: String
    /// DEBUG (ORBIT_DEBUG_FILE_SCOPE): only paths inside it are allowed.
    var restriction: String?

    init(homeDirectory: String, orbitDataDirectory: String, restriction: String? = nil) {
        self.homeDirectory = FilePath.normalize(homeDirectory)
        self.orbitDataDirectory = FilePath.normalize(orbitDataDirectory)
        self.restriction = restriction.map(FilePath.normalize)
    }

    /// Checks `path` (absolute) and the item it resolves to (symlinks and alias
    /// spellings resolved). The path as given is decided first, without
    /// touching the disk: resolving opens the item (`FilePath.canonical`), and
    /// a path the rules deny as written is never opened. Only then it reads
    /// the file system: the resolved path, and for `*.key` files their
    /// metadata, and their first bytes when that decides (never downloading
    /// a file for listing or revealing).
    func check(_ path: String, purpose: Purpose) -> Denial? {
        // An invalid debug scope allows nothing, decided without touching the disk.
        if let restriction, !restriction.hasPrefix("/") { return .outsideScope }
        let given = FilePath.normalize(path)
        // A `*.key` item may still be a Keynote document; the item itself decides that below.
        if let denial = rules(for: given, purpose: purpose, isKeynoteDocument: true) {
            return denial
        }
        let resolved = FilePath.canonical(given)
        if let restriction, !FilePath.isInside(resolved, restriction) {
            return .outsideScope
        }
        var keynote = false
        if given.lowercased().hasSuffix(".key") || resolved.lowercased().hasSuffix(".key") {
            // Undecided without downloading it: listing leaves it out, showing it in Finder discloses nothing.
            keynote = Self.isKeynoteDocument(atPath: resolved, mayDownload: purpose == .read || purpose == .open)
                ?? (purpose == .reveal)
        }
        for candidate in given == resolved ? [given] : [given, resolved] {
            if let denial = rules(for: candidate, purpose: purpose, isKeynoteDocument: keynote) {
                return denial
            }
        }
        return nil
    }

    /// The rules for one absolute, normalized path, without touching the disk
    /// (the restriction is left to `check`, which compares the resolved path).
    /// `isKeynoteDocument`: whether a `*.key` item is a Keynote document rather
    /// than a private key.
    func rules(for path: String, purpose: Purpose, isKeynoteDocument: Bool = false) -> Denial? {
        // Volumes are usually case-insensitive: "~/.AWS" is "~/.aws", so every rule ignores case.
        let path = path.lowercased()
        if Self.isSystemPath(path) { return .systemPath }
        if isSecret(path, isKeynoteDocument: isKeynoteDocument) { return .secret }
        guard purpose != .reveal else { return nil }
        if FilePath.isInside(path, orbitDataDirectory.lowercased()) { return .orbitData }
        let library = homeDirectory.lowercased() + "/library"
        if FilePath.isInside(path, library), !FileVisibility.visibleLibraryFolders.contains(where: {
            FilePath.isInside(path, library + "/" + $0.lowercased())
        }) {
            return .library
        }
        return nil
    }

    /// The pure rules; `rules(for:purpose:)` with the purpose of listing.
    func allowsListing(_ path: String, isKeynoteDocument: Bool = false) -> Bool {
        rules(for: path, purpose: .list, isKeynoteDocument: isKeynoteDocument) == nil
    }

    /// `path` lowercased: a spelling that reaches items through a system alias
    /// rather than their usual path: the data volume and other volumes under
    /// /System/Volumes ("/System/Volumes/Data/Users/…" is "/Users/…"), device
    /// files and open file descriptors (/dev, /dev/fd/<n>), and hidden folders
    /// at the root such as /.vol/<device>/<inode>, /.nofollow and /.resolve/<n>.
    /// Neither Spotlight nor Finder reports such paths, and the location rules
    /// below would not recognize them.
    static func isSystemPath(_ path: String) -> Bool {
        if FilePath.isInside(path, "/system/volumes") || FilePath.isInside(path, "/dev") { return true }
        return path.split(separator: "/").first?.hasPrefix(".") == true
    }

    // MARK: Secrets

    /// Relative to the home folder.
    static let homeSecrets = [
        ".ssh", ".gnupg", ".aws", ".config/gcloud", ".azure", ".kube", ".docker/config.json", ".netrc", ".npmrc",
        ".pypirc", ".git-credentials", ".config/gh", ".config/op", ".password-store", ".pgpass", ".vault-token",
        ".cargo/credentials", ".cargo/credentials.toml", ".gem/credentials", ".terraform.d/credentials.tfrc.json",
        ".claude.json", ".claude/.credentials.json", ".mozilla", ".thunderbird", "Library/Keychains",
    ]

    static let systemSecrets = ["/Library/Keychains", "/System/Library/Keychains", "/Network/Library/Keychains"]

    /// File extensions of keychains, password databases, private keys and certificates.
    static let secretExtensions: Set<String> = [
        "keychain", "keychain-db", "kdbx", "kdb", "1pif", "opvault", "agilekeychain", "psafe3", "pem", "p12", "pfx",
        "p8", "ppk", "key", "keystore", "jks",
    ]

    /// Exact file names (lowercased).
    static let secretNames: Set<String> = [
        ".env", ".envrc", ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass", ".vault-token",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "id_ecdsa_sk", "id_ed25519_sk",
    ]

    /// Folder names (lowercased substrings) of password managers.
    static let passwordManagerMarkers = [
        "1password", "agilebits", "bitwarden", "keepass", "lastpass", "dashlane", "enpass", "strongbox",
    ]

    /// Consecutive folder names (lowercased) of browser and mail profiles.
    static let profileFolders: [[String]] = [
        ["google", "chrome"], ["chromium"], ["bravesoftware"], ["microsoft edge"], ["vivaldi"],
        ["firefox", "profiles"], ["arc", "user data"], ["opera software"], ["thunderbird", "profiles"],
    ]

    /// `path` lowercased.
    private func isSecret(_ path: String, isKeynoteDocument: Bool) -> Bool {
        if Self.systemSecrets.contains(where: { FilePath.isInside(path, $0.lowercased()) }) { return true }
        let home = homeDirectory.lowercased()
        if Self.homeSecrets.contains(where: { FilePath.isInside(path, home + "/" + $0.lowercased()) }) { return true }
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            // A folder in the path is never a private key file (a `*.key` folder is a Keynote package).
            let isLast = index == components.count - 1
            if Self.isSecretName(component, isKeynoteDocument: isLast ? isKeynoteDocument : true) {
                return true
            }
            if Self.passwordManagerMarkers.contains(where: { component.contains($0) }) { return true }
            for folders in Self.profileFolders where components.dropFirst(index).starts(with: folders) {
                return true
            }
        }
        return false
    }

    /// `name` lowercased.
    static func isSecretName(_ name: String, isKeynoteDocument: Bool) -> Bool {
        if secretNames.contains(name) { return true }
        if name.hasPrefix(".env.") || name.hasSuffix(".env") { return true }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let pathExtension = String(name[name.index(after: dot)...])
        if pathExtension == "key" { return !isKeynoteDocument }
        return secretExtensions.contains(pathExtension)
    }

    /// Whether the `*.key` item at `path` is a Keynote document (a package
    /// folder or a ZIP file, single-file Keynote) rather than a private key,
    /// which is plain text (PEM) or DER, never a ZIP. The file's UTType cannot
    /// decide this: macOS types every flat `.key` file as Keynote
    /// (com.apple.iwork.keynote.sffkey).
    ///
    /// Search results are filtered with it, and filtering must neither download
    /// nor block, so metadata decides first (`keynoteDecision`). Only a small,
    /// local regular file is read (its first 4 bytes); a dataless one (in
    /// iCloud Drive or cloud storage and not downloaded, so reading it would
    /// download it) only with `mayDownload`, else the answer is nil (undecided).
    static func isKeynoteDocument(atPath path: String, mayDownload: Bool) -> Bool? {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        switch keynoteDecision(type: info.st_mode & S_IFMT, size: Int64(info.st_size),
                               isDataless: info.st_flags & UInt32(SF_DATALESS) != 0, mayDownload: mayDownload) {
        case .keynote: return true
        case .notKeynote: return false
        case .undecided: return nil
        case .readFirstBytes: return startsLikeZip(path)
        }
    }

    enum KeynoteDecision: Sendable, Hashable {
        case keynote
        case notKeynote
        /// Only reading could tell, and reading is not allowed.
        case undecided
        case readFirstBytes
    }

    /// Key files are a few KB; anything larger is a presentation.
    static let largestKeyFileSize: Int64 = 256_000

    /// The metadata part of `isKeynoteDocument`: a folder is a Keynote package;
    /// pipes, devices and sockets are not documents (and are never opened: a
    /// pipe would block); a regular file larger than `largestKeyFileSize` is a
    /// presentation (a dataless file reports its full size too); a dataless one
    /// is read only with `mayDownload`.
    static func keynoteDecision(type: mode_t, size: Int64, isDataless: Bool, mayDownload: Bool) -> KeynoteDecision {
        if type == S_IFDIR { return .keynote }
        guard type == S_IFREG else { return .notKeynote }
        if size > largestKeyFileSize { return .keynote }
        if isDataless, !mayDownload { return .undecided }
        return .readFirstBytes
    }

    /// Whether the regular file at `path` starts with a ZIP header. Opened
    /// non-blocking; nothing but a regular file is read.
    private static func startsLikeZip(_ path: String) -> Bool {
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        var magic = [UInt8](repeating: 0, count: 4)
        return read(descriptor, &magic, magic.count) == magic.count && magic == [0x50, 0x4B, 0x03, 0x04]
    }
}
