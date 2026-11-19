import Foundation
import CryptoKit
import UIKit

/// Shared memory and disk cache for remote book-cover images.
///
/// Cache entries are keyed by the complete image URL. Changing a cover URL
/// therefore naturally creates a new cache entry.
@MainActor
final class BookCoverImageCache {
    static let shared = BookCoverImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private var inFlightTasks: [String: Task<Data?, Never>] = [:]

    private init() {
        memoryCache.totalCostLimit = 64 * 1024 * 1024

        let cachesDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        cacheDirectory = cachesDirectory.appendingPathComponent(
            "BookCoverImages",
            isDirectory: true
        )

        try? fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Returns a cached image when available; otherwise downloads and stores it.
    /// Concurrent requests for the same URL share one download task.
    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString

        if let cachedImage = memoryCache.object(forKey: key as NSString) {
            return cachedImage
        }

        let diskURL = cacheFileURL(for: key)
        if let diskImage = UIImage(contentsOfFile: diskURL.path) {
            memoryCache.setObject(
                diskImage,
                forKey: key as NSString,
                cost: imageCost(diskImage)
            )
            return diskImage
        }

        if let existingTask = inFlightTasks[key] {
            guard let data = await existingTask.value else { return nil }
            return cacheImage(from: data, key: key)
        }

        let task = Task<Data?, Never> {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let response = response as? HTTPURLResponse,
                   !(200...299).contains(response.statusCode) {
                    return nil
                }

                try? data.write(to: diskURL, options: .atomic)
                return data
            } catch {
                return nil
            }
        }

        inFlightTasks[key] = task
        let data = await task.value
        inFlightTasks[key] = nil
        guard let data else { return nil }
        return cacheImage(from: data, key: key)
    }

    /// Removes the cached image for one URL from both memory and disk.
    func removeImage(for url: URL) {
        let key = url.absoluteString
        memoryCache.removeObject(forKey: key as NSString)
        try? fileManager.removeItem(at: cacheFileURL(for: key))
    }

    /// Removes all persisted and in-memory cover images.
    func clearCache() {
        memoryCache.removeAllObjects()
        inFlightTasks.values.forEach { $0.cancel() }
        inFlightTasks.removeAll()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    private func cacheImage(from data: Data, key: String) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        memoryCache.setObject(
            image,
            forKey: key as NSString,
            cost: data.count
        )
        return image
    }

    private func cacheFileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private func imageCost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
