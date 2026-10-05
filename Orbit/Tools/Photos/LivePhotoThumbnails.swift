import AppKit
import Foundation
import Photos
import os

/// Thumbnails for photo cards through PhotoKit's caching image manager, with
/// `LivePhotoLibrary` the only place Orbit touches PhotoKit's data.
///
/// - Never over the network: a photo that is only in iCloud gets the best
///   version already on the Mac (PhotoKit's low-quality one), or none
///   (`.inCloud`); Orbit never starts a download.
/// - Never without access: nothing is fetched or requested unless Orbit may
///   read the library (PhotoKit would ask the user otherwise); without access
///   every thumbnail is `.unavailable` and the memory cache is emptied.
/// - Bounded memory: finished thumbnails stay in a cache limited by size
///   (`cacheCostLimit`) and count, PhotoKit prepares at most `maxPrepared`
///   thumbnails ahead for the cards on screen and stops when a card goes away,
///   and at most `maxRememberedAssets` looked-up assets are kept.
/// - Cancellation: when a tile goes away its task is cancelled, which cancels
///   PhotoKit's request at once (`ThumbnailRequest` answers exactly once; a
///   request that never finishes ends after `requestTimeout`).
/// PhotoKit lookups run on one serial queue, never on the main thread; the
/// images leave PhotoKit's callbacks as `CGImage`. Logs record nothing about
/// the photos.
final class LivePhotoThumbnails: PhotoThumbnailProviding, @unchecked Sendable {
    // @unchecked: `manager`, `assets` and `prepared` are only read and written
    // on `queue` (a serial queue); `images` is an NSCache, which is thread-safe.

    /// Bytes of finished thumbnails kept in memory at most.
    static let cacheCostLimit = 32 * 1024 * 1024
    static let cacheCountLimit = 400
    /// Thumbnails PhotoKit prepares ahead at most (one full card of 100 and some).
    static let maxPrepared = 120
    /// Assets kept after a lookup at most.
    static let maxRememberedAssets = 600
    /// A request that has not finished by then ends with what it has.
    static let requestTimeout: DispatchTimeInterval = .seconds(15)

    private let queue = DispatchQueue(label: "io.github.eric-volz.Orbit.photo-thumbnails", qos: .userInitiated)
    private var manager: PHCachingImageManager?
    private var assets: [String: PHAsset] = [:]
    /// How many cards prepared each thumbnail (key: `key(_:_:)`).
    private var prepared: [String: Int] = [:]
    private let images = ThumbnailCache(costLimit: LivePhotoThumbnails.cacheCostLimit,
                                        countLimit: LivePhotoThumbnails.cacheCountLimit)

    init() {}

    // MARK: PhotoThumbnailProviding

    func cachedThumbnail(for identifier: String, pixels: Int) -> PhotoThumbnail? {
        images.image(for: Self.key(identifier, pixels)).map(PhotoThumbnail.image)
    }

    func thumbnail(for identifier: String, pixels: Int) async -> PhotoThumbnail {
        guard Self.hasAccess else {
            images.removeAll()
            return .unavailable
        }
        if let cached = cachedThumbnail(for: identifier, pixels: pixels) { return cached }
        guard !Task.isCancelled else { return .unavailable }
        let request = ThumbnailRequest()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PhotoThumbnail, Never>) in
                request.install(continuation)
                queue.async { [self] in
                    guard !request.isFinished else { return }
                    guard let asset = asset(for: identifier) else {
                        request.finish(.unavailable)
                        return
                    }
                    let manager = imageManager()
                    let requestID = manager.requestImage(for: asset, targetSize: Self.size(pixels), contentMode: .aspectFill,
                                                         options: Self.options()) { image, info in
                        request.deliver(Self.cgImage(image), isDegraded: Self.flag(PHImageResultIsDegradedKey, in: info),
                                        isInCloud: Self.flag(PHImageResultIsInCloudKey, in: info))
                    }
                    request.started(requestID, manager: manager)
                    queue.asyncAfter(deadline: .now() + Self.requestTimeout) {
                        request.timeOut()
                    }
                }
            }
        } onCancel: {
            request.cancel()
        }
        if case .image(let image) = result {
            images.insert(image, for: Self.key(identifier, pixels))
        }
        return result
    }

    func prepare(_ identifiers: [String], pixels: Int) {
        guard !identifiers.isEmpty else { return }
        // Called from the main thread (a card appeared): everything, the access check too, on the queue.
        queue.async { [self] in
            guard Self.hasAccess else { return }
            let missing = identifiers.filter { assets[$0] == nil }
            if !missing.isEmpty {
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
                for index in 0..<fetched.count {
                    remember(fetched.object(at: index))
                }
            }
            var fresh: [PHAsset] = []
            for identifier in identifiers {
                let key = Self.key(identifier, pixels)
                if let count = prepared[key] {
                    prepared[key] = count + 1
                } else if prepared.count < Self.maxPrepared, let asset = assets[identifier] {
                    prepared[key] = 1
                    fresh.append(asset)
                }
            }
            guard !fresh.isEmpty else { return }
            imageManager().startCachingImages(for: fresh, targetSize: Self.size(pixels), contentMode: .aspectFill,
                                              options: Self.options())
        }
    }

    func release(_ identifiers: [String], pixels: Int) {
        guard !identifiers.isEmpty else { return }
        queue.async { [self] in
            var done: [PHAsset] = []
            for identifier in identifiers {
                let key = Self.key(identifier, pixels)
                guard let count = prepared[key] else { continue }
                if count > 1 {
                    prepared[key] = count - 1
                } else {
                    prepared[key] = nil
                    if let asset = assets[identifier] { done.append(asset) }
                }
            }
            guard !done.isEmpty, let manager else { return }
            manager.stopCachingImages(for: done, targetSize: Self.size(pixels), contentMode: .aspectFill, options: Self.options())
        }
    }

    // MARK: On the queue

    private func imageManager() -> PHCachingImageManager {
        if let manager { return manager }
        let created = PHCachingImageManager()
        // Thumbnails only: prepared images may be of lower quality, which saves memory.
        created.allowsCachingHighQualityImages = false
        manager = created
        return created
    }

    private func asset(for identifier: String) -> PHAsset? {
        if let asset = assets[identifier] { return asset }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        remember(asset)
        return asset
    }

    private func remember(_ asset: PHAsset) {
        if assets.count >= Self.maxRememberedAssets {
            // Assets prepared ahead stay (`release` needs them); the others are looked up again.
            let keep = Set(prepared.keys.map { String($0.drop { $0 != ":" }.dropFirst()) })
            assets = assets.filter { keep.contains($0.key) }
        }
        assets[asset.localIdentifier] = asset
    }

    // MARK: Requests (pure)

    /// Whether Orbit may read the library: the check before any fetch (never
    /// on the main thread: macOS may have to look it up).
    private static var hasAccess: Bool {
        LivePhotoLibrary.access(PHPhotoLibrary.authorizationStatus(for: .readWrite)).allowsReading
    }

    /// The same options for requests and preparing, so prepared images are used.
    private static func options() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        // A quick low-quality image first, then the right size, both from the Mac only.
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        options.version = .current
        return options
    }

    static func size(_ pixels: Int) -> CGSize {
        CGSize(width: max(1, pixels), height: max(1, pixels))
    }

    /// The cache key: the size and the identifier.
    static func key(_ identifier: String, _ pixels: Int) -> String {
        "\(pixels):\(identifier)"
    }

    private static func flag(_ key: String, in info: [AnyHashable: Any]?) -> Bool {
        (info?[key] as? NSNumber)?.boolValue ?? false
    }

    private static func cgImage(_ image: NSImage?) -> CGImage? {
        image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// One thumbnail request: answers its caller exactly once, with the image,
/// with the best image so far when the request is cancelled by its timeout,
/// or `.unavailable` when the tile went away (PhotoKit's request is cancelled
/// too and may never answer).
/// @unchecked: its state is behind the lock; the manager is only used to
/// cancel the request, which PhotoKit allows from any thread.
private final class ThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PhotoThumbnail, Never>?
    private var requestID: PHImageRequestID?
    private var manager: PHImageManager?
    /// A low-quality image delivered first: the answer if the right size never comes.
    private var fallback: CGImage?
    private var result: PhotoThumbnail?

    var isFinished: Bool { lock.withLock { result != nil } }

    func install(_ continuation: CheckedContinuation<PhotoThumbnail, Never>) {
        let finished = lock.withLock { () -> PhotoThumbnail? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        // Cancelled before the continuation existed.
        if let finished { continuation.resume(returning: finished) }
    }

    func started(_ requestID: PHImageRequestID, manager: PHImageManager) {
        let cancelNow = lock.withLock { () -> Bool in
            self.requestID = requestID
            self.manager = manager
            return result != nil
        }
        if cancelNow { manager.cancelImageRequest(requestID) }
    }

    /// PhotoKit's answer: a degraded image is kept as the fallback; the final
    /// one ends the request (without an image: the fallback, else whether the
    /// photo is only in iCloud).
    func deliver(_ image: CGImage?, isDegraded: Bool, isInCloud: Bool) {
        if isDegraded {
            if let image { lock.withLock { self.fallback = image } }
            return
        }
        let earlier = lock.withLock { self.fallback }
        if let image = image ?? earlier {
            finish(.image(image))
        } else {
            finish(isInCloud ? .inCloud : .unavailable)
        }
    }

    /// The request took too long: what it has so far.
    func timeOut() {
        let fallback = lock.withLock { self.fallback }
        cancelRequest()
        finish(fallback.map(PhotoThumbnail.image) ?? .unavailable)
    }

    /// The tile went away.
    func cancel() {
        cancelRequest()
        finish(.unavailable)
    }

    /// The first answer wins; later ones are dropped.
    func finish(_ thumbnail: PhotoThumbnail) {
        let waiting = lock.withLock { () -> CheckedContinuation<PhotoThumbnail, Never>? in
            guard result == nil else { return nil }
            result = thumbnail
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: thumbnail)
    }

    private func cancelRequest() {
        let pending = lock.withLock { () -> (PHImageRequestID, PHImageManager)? in
            guard result == nil, let requestID, let manager else { return nil }
            return (requestID, manager)
        }
        if let pending { pending.1.cancelImageRequest(pending.0) }
    }
}

/// Finished thumbnails in memory, bounded by bytes and count (NSCache also
/// gives memory back when the system needs it).
/// @unchecked: NSCache is thread-safe.
final class ThumbnailCache: @unchecked Sendable {
    private final class Entry {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private let cache = NSCache<NSString, Entry>()

    init(costLimit: Int, countLimit: Int) {
        cache.totalCostLimit = costLimit
        cache.countLimit = countLimit
    }

    func image(for key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func insert(_ image: CGImage, for key: String) {
        cache.setObject(Entry(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
