import Foundation
import ImageIO
import InkwellCore
import UniformTypeIdentifiers

public struct ImportedImage: Sendable, Equatable {
    /// Site path such as `/assets/images/morality-guinea-worm.jpg`.
    public var sitePath: String
    public var fileURL: URL
    public var originalBytes: Int
    public var finalBytes: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var removedLocation: Bool

    public func markdown(alt: String, useRelativeURL: Bool) -> String {
        let target = useRelativeURL ? "{{ '\(sitePath)' | relative_url }}" : sitePath
        return "![\(alt)](\(target))"
    }
}

public enum ImageImportError: Error, LocalizedError {
    case unreadable(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(name): "\(name) could not be read as an image."
        case let .writeFailed(name): "\(name) could not be saved."
        }
    }
}

/// Prepares a picture for the web: HEIC and RAW become JPEG, the long edge is capped, the picture is turned upright,
/// and camera metadata (GPS above all) is left behind. GIFs are copied as they are, so animation survives.
public struct ImageImport: Sendable {
    public var maxPixelSize = 2400
    public var jpegQuality = 0.82
    public var folder = "assets/images"

    public init() {}

    public func importImage(at source: URL, siteRoot: URL, slug: String) throws -> ImportedImage {
        let name = source.lastPathComponent
        let originalBytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(image) as String? else {
            throw ImageImportError.unreadable(name)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] ?? [:]
        let hadGPS = properties[kCGImagePropertyGPSDictionary] != nil
        let destinationFolder = siteRoot.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        if type == UTType.gif.identifier || type == UTType.svg.identifier {
            let ext = type == UTType.gif.identifier ? "gif" : "svg"
            let target = freeURL(in: destinationFolder, base: fileBase(slug: slug, original: name), ext: ext)
            try FileManager.default.copyItem(at: source, to: target)
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            return ImportedImage(sitePath: sitePath(target, siteRoot: siteRoot), fileURL: target, originalBytes: originalBytes,
                                 finalBytes: originalBytes, pixelWidth: width, pixelHeight: height, removedLocation: false)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else {
            throw ImageImportError.unreadable(name)
        }
        let keepsAlpha = type == UTType.png.identifier && cgImage.alphaInfo != .none && cgImage.alphaInfo != .noneSkipLast
            && cgImage.alphaInfo != .noneSkipFirst
        let outType = keepsAlpha ? UTType.png : UTType.jpeg
        let target = freeURL(in: destinationFolder, base: fileBase(slug: slug, original: name), ext: keepsAlpha ? "png" : "jpg")
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, outType.identifier as CFString, 1, nil) else {
            throw ImageImportError.writeFailed(name)
        }
        // Only the pixels and the colour profile carried by the image itself go into the new file.
        let writeOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
            kCGImagePropertyOrientation: 1,
        ]
        CGImageDestinationAddImage(destination, cgImage, writeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageImportError.writeFailed(name) }
        let finalBytes = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ImportedImage(sitePath: sitePath(target, siteRoot: siteRoot), fileURL: target, originalBytes: originalBytes,
                             finalBytes: finalBytes, pixelWidth: cgImage.width, pixelHeight: cgImage.height, removedLocation: hadGPS)
    }

    func sitePath(_ url: URL, siteRoot: URL) -> String {
        let root = siteRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : "/" + url.lastPathComponent
    }

    /// `slug-descriptor`, where the descriptor comes from the original name unless that is a camera counter like IMG_4821.
    func fileBase(slug: String, original: String) -> String {
        let stem = (original as NSString).deletingPathExtension
        let cameraName = stem.range(of: #"^(IMG|DSC|DSCF|PXL|MVIMG|Screenshot|Photo|image|P\d|_MG|GOPR|DJI)[_ -]?[\d_ -]*"#,
                                    options: [.regularExpression, .caseInsensitive]).map { $0.upperBound == stem.endIndex } ?? false
        let descriptor = cameraName ? "" : Slug.make(stem, maxWords: 4)
        if descriptor.isEmpty || descriptor == "untitled" { return slug }
        return descriptor.hasPrefix(slug) ? descriptor : "\(slug)-\(descriptor)"
    }

    func freeURL(in folder: URL, base: String, ext: String) -> URL {
        var candidate = folder.appending(path: "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Whether a file still carries location data, for the publish checklist and tests.
    public static func hasLocation(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyGPSDictionary] != nil
    }
}
