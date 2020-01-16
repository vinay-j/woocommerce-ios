import AVFoundation
import Foundation
import MobileCoreServices

extension URL {
    /// The URLResource uniform type identifier for the file at the URL, if available.
    ///
    var typeIdentifier: String? {
        let values = try? resourceValues(forKeys: [.typeIdentifierKey])
        return values?.typeIdentifier
    }

    var typeIdentifierFileExtension: String? {
        guard let type = typeIdentifier else {
            return nil
        }
        return URL.fileExtensionForUTType(type)
    }

    /// The expected file extension string for a given UTType identifier string.
    ///
    /// - param type: The UTType identifier string.
    /// - returns: The expected file extension or nil if unknown.
    ///
    static func fileExtensionForUTType(_ type: String) -> String? {
        let fileExtension = UTTypeCopyPreferredTagWithClass(type as CFString, kUTTagClassFilenameExtension)?.takeRetainedValue()
        return fileExtension as String?
    }

    /// Returns a URL with an incremental file name, if a file already exists at the given URL.
    ///
    /// Previously seen in MediaService.m within urlForMediaWithFilename:andExtension:
    ///
    func incrementalFilename() -> URL {
        var url = self
        let pathExtension = url.pathExtension
        let filename = url.deletingPathExtension().lastPathComponent
        var index = 1
        let fileManager = FileManager.default
        while fileManager.fileExists(atPath: url.path) {
            let incrementedName = "\(filename)-\(index)"
            url.deleteLastPathComponent()
            url.appendPathComponent(incrementedName, isDirectory: false)
            url.appendPathExtension(pathExtension)
            index += 1
        }
        return url
    }
}

extension Progress {

    /// Creates and returns progress object that is 100% completed.
    ///
    /// This is good to use on scenarios where tasks are small and quick and you want to just return a completed progress.
    ///
    /// - Returns: Progress object
    static func discreteCompletedProgress() -> Progress {
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        return progress
    }
}

/// Media export handling of UIImages.
///
final class MediaImageExporter: MediaExporter {

    var mediaDirectoryType: MediaDirectory = .uploads

    /// Export options.
    ///
    var options = Options()

    /// Available options for an image export.
    ///
    struct Options: MediaExportingOptions {
        /// Set a maximumImageSize for resizing images, or nil for exporting the full images.
        ///
        var maximumImageSize: CGFloat?

        /// Compression quality if the image type supports compression, defaults to no compression or maximum quality.
        ///
        var imageCompressionQuality = 1.0

        /// The target UTType of the exported image, typically a UTTypeJPEG or UTTypePNG,
        /// or nil if the original image's format should be used.
        ///
        /// - Note: The exporter may not support exporting the original image as
        ///   the set type, and will throw an error if it fails.
        ///
        var exportImageType: String?

        /// If the original asset contains geo location information, enabling this option will remove it.
        var stripsGeoLocationIfNeeded = false
    }

    public enum ImageExportError: MediaExportError {
        case imageDataRepresentationFailed
        case imageSourceCreationWithDataFailed
        case imageSourceCreationWithURLFailed
        case imageSourceIsAnUnknownType
        case imageSourceDestinationWithURLFailed
        case imageSourceThumbnailGenerationFailed
        case imageSourceDestinationWriteFailed
        var description: String {
            switch self {
            default:
                return NSLocalizedString("The image could not be added to the Media Library.",
                                         comment: "Message shown when an image failed to load while trying to add it to the Media library.")
            }
        }
    }

    /// Default filename used when writing media images locally, which may be appended with "-1" or "-thumbnail".
    ///
    private let defaultImageFilename = "image"

    private let data: Data?
    private let filename: String?
    private let typeHint: String?

    init(data: Data, filename: String?, typeHint: String? = nil) {
        self.filename = filename
        self.data = data
        self.typeHint = typeHint
    }

    @discardableResult func export(onCompletion: @escaping MediaExportCompletion) -> Progress {
        guard let data = data else {
            return Progress.discreteCompletedProgress()
        }
        return exportImage(withData: data, fileName: filename, typeHint: typeHint, onCompletion: onCompletion)
    }

    /// Exports and writes an image's data, expected as PNG or JPEG format, to a local Media URL.
    ///
    /// - Parameters:
    ///     - fileName: Filename if it's known.
    ///     - typeHint: Hint towards the UTType of data, such as PNG or JPEG.
    ///     - onCompletion: Called on successful export, with the local file URL of the exported UIImage.
    ///     - onError: Called if an error was encountered during creation.
    ///
    /// - Returns: a progress object that report the current state of the export process.
    ///
    func exportImage(withData data: Data, fileName: String?, typeHint: String?, onCompletion: @escaping MediaExportCompletion) -> Progress {
        do {
            let hint = typeHint ?? kUTTypeJPEG as String
            let sourceOptions: [String: Any] = [kCGImageSourceTypeIdentifierHint as String: hint as CFString]
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
                throw ImageExportError.imageSourceCreationWithDataFailed
            }
            guard let utType = CGImageSourceGetType(source) else {
                throw ImageExportError.imageSourceIsAnUnknownType
            }
            return exportImageSource(source,
                              filename: fileName,
                              type: options.exportImageType ?? utType as String,
                              onCompletion: onCompletion)
        } catch {
            onCompletion(nil, exporterErrorWith(error: error))
        }
        return Progress.discreteCompletedProgress()
    }

    /// Exports and writes an image source, to a local Media URL.
    ///
    /// - Parameters:
    ///     - fileName: Filename if it's known.
    ///     - onCompletion: Called on successful export, with the local file URL of the exported UIImage.
    ///     - onError: Called if an error was encountered during creation.
    ///
    /// - Returns: a progress object that report the current state of the export process.
    ///
    func exportImageSource(_ source: CGImageSource, filename: String?, type: String, onCompletion: @escaping MediaExportCompletion) -> Progress {
        do {
            let filename = filename ?? defaultImageFilename
            // Make a new URL within the local Media directory
            let url = try mediaFileManager.makeLocalMediaURL(withFilename: filename,
                                                             fileExtension: URL.fileExtensionForUTType(type))

            // Check MediaSettings and configure the image writer as needed.
            var writer = ImageSourceWriter(url: url, sourceUTType: type as CFString)
            if let maximumImageSize = options.maximumImageSize {
                writer.maximumSize = maximumImageSize as CFNumber
            }
            writer.lossyCompressionQuality = options.imageCompressionQuality
            writer.nullifyGPSData = options.stripsGeoLocationIfNeeded
            _ = try writer.writeImageSource(source)

            let exported = ExportedMedia(localURL: url,
                                         filename: url.lastPathComponent,
                                         mimeType: url.mimeTypeForPathExtension())
            onCompletion(exported, nil)
        } catch {
            onCompletion(nil, exporterErrorWith(error: error))
        }
        return Progress.discreteCompletedProgress()
    }
}

private extension MediaImageExporter {
    /// Configurable struct for writing an image to a URL from a CGImageSource, via CGImageDestination, particular to the needs of a MediaImageExporter.
    ///
    struct ImageSourceWriter {

        /// File URL where the image should be written
        ///
        var url: URL

        /// The UTType of the image source
        ///
        var sourceUTType: CFString

        /// The Compression quality used, defaults to 1.0 or full
        ///
        var lossyCompressionQuality = 1.0

        /// Whether or not GPS data should be nullified.
        ///
        var nullifyGPSData = false

        /// A maximum size required for the image to be written, or nil.
        ///
        var maximumSize: CFNumber?

        init(url: URL, sourceUTType: CFString) {
            self.url = url
            self.sourceUTType = sourceUTType
        }

        /// Struct for returned result from writing an image, and any properties worth keeping track of.
        ///
        struct WriteResultProperties {
            let width: CGFloat?
            let height: CGFloat?
        }

        /// Write a given image source, succeeds unless an error is thrown, returns the resulting properties if available.
        ///
        func writeImageSource(_ source: CGImageSource) throws -> WriteResultProperties {
            // Create the destination with the URL, or error
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, sourceUTType, 1, nil) else {
                throw ImageExportError.imageSourceDestinationWithURLFailed
            }

            // Configure image properties for the image source and image destination methods
            // Preserve any existing properties from the source.
            var imageProperties: [NSString: Any] = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? Dictionary) ?? [:]
            // Configure destination properties
            imageProperties[kCGImageDestinationLossyCompressionQuality] = lossyCompressionQuality

            // Keep track of the image's width and height
            var width: CGFloat?
            var height: CGFloat?

            // Configure orientation properties to default .up or 1
            imageProperties[kCGImagePropertyOrientation] = Int(CGImagePropertyOrientation.up.rawValue) as CFNumber
            if var tiffProperties = imageProperties[kCGImagePropertyTIFFDictionary] as? [NSString: Any] {
                // Remove TIFF orientation value
                tiffProperties.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                imageProperties[kCGImagePropertyTIFFDictionary] = tiffProperties
            }
            if var iptcProperties = imageProperties[kCGImagePropertyIPTCDictionary] as? [NSString: Any] {
                // Remove IPTC orientation value
                iptcProperties.removeValue(forKey: kCGImagePropertyIPTCImageOrientation)
                imageProperties[kCGImagePropertyIPTCDictionary] = iptcProperties
            }

            // Configure options for generating the thumbnail, such as the maximum size.
            var thumbnailOptions: [NSString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceTypeIdentifierHint: sourceUTType,
                kCGImageSourceCreateThumbnailWithTransform: true ]

            if let maximumSize = maximumSize {
                thumbnailOptions[kCGImageSourceThumbnailMaxPixelSize] = maximumSize
            }

            // Create a thumbnail of the image source.
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                throw ImageExportError.imageSourceThumbnailGenerationFailed
            }

            if nullifyGPSData == true {
                // When removing GPS data for a thumbnail, we have to remove the dictionary
                // itself for the CGImageDestinationAddImage method.
                imageProperties.removeValue(forKey: kCGImagePropertyGPSDictionary)
            }

            // Add the thumbnail image as the destination's image.
            CGImageDestinationAddImage(destination, image, imageProperties as CFDictionary?)

            // Get the dimensions from the CGImage itself
            width = CGFloat(image.width)
            height = CGFloat(image.height)

            // Write the image to the file URL
            let written = CGImageDestinationFinalize(destination)
            guard written == true else {
                throw ImageExportError.imageSourceDestinationWriteFailed
            }

            // Return the result with any interesting properties.
            return WriteResultProperties(width: width,
                                         height: height)
        }
    }
}
