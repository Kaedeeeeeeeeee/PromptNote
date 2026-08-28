import Foundation

struct PromptNotePackageLimits: Equatable {
    var maximumManifestByteCount = 4 * 1_024 * 1_024
    var maximumPageCount = 2_000
    var maximumAttachmentCount = 256
    var maximumDrawingByteCount: Int64 = 64 * 1_024 * 1_024
    var maximumTotalDrawingByteCount: Int64 = 512 * 1_024 * 1_024
    var maximumAttachmentByteCount: Int64 = 2 * 1_024 * 1_024 * 1_024
    var maximumTotalAttachmentByteCount: Int64 = 8 * 1_024 * 1_024 * 1_024

    static let standard = PromptNotePackageLimits()
}

struct PromptNotePackageDescriptor: Equatable {
    let fileURL: URL
    var manifest: PromptNoteManifest
}

enum PromptNotePackageReader {
    static let manifestFileName = "manifest.plist"

    static func loadManifest(from packageURL: URL,
                             fileManager: FileManager = .default,
                             limits: PromptNotePackageLimits = .standard,
                             requiresPackageExtension: Bool = true) throws -> PromptNotePackageDescriptor {
        try validatePackageURL(
            packageURL,
            fileManager: fileManager,
            requiresPackageExtension: requiresPackageExtension
        )
        let manifestURL = try containedURL(
            for: manifestFileName,
            in: packageURL,
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw PromptNotePackageError.manifestMissing
        }
        let manifestInfo = try regularFileInfo(at: manifestURL, fileManager: fileManager)
        guard manifestInfo.byteCount <= Int64(limits.maximumManifestByteCount) else {
            throw PromptNotePackageError.resourceLimitExceeded("manifest is too large")
        }

        let manifest: PromptNoteManifest
        do {
            manifest = try PropertyListDecoder().decode(
                PromptNoteManifest.self,
                from: Data(contentsOf: manifestURL, options: .mappedIfSafe)
            )
        } catch let error as PromptNotePackageError {
            throw error
        } catch {
            throw PromptNotePackageError.invalidManifest(error.localizedDescription)
        }
        try manifest.validate()
        guard manifest.pages.count <= limits.maximumPageCount else {
            throw PromptNotePackageError.resourceLimitExceeded("too many pages")
        }
        guard manifest.attachments.count <= limits.maximumAttachmentCount else {
            throw PromptNotePackageError.resourceLimitExceeded("too many attachments")
        }
        return PromptNotePackageDescriptor(fileURL: packageURL, manifest: manifest)
    }

    /// Performs bounded metadata validation without decoding PencilKit drawings
    /// or hashing large attachments. Normal document opening uses this path.
    static func validateStructure(_ descriptor: PromptNotePackageDescriptor,
                                  fileManager: FileManager = .default,
                                  limits: PromptNotePackageLimits = .standard) throws {
        let packageURL = descriptor.fileURL
        let manifestURL = try containedURL(
            for: manifestFileName,
            in: packageURL,
            fileManager: fileManager
        )
        var resourceIdentities = Set<String>()
        let manifestInfo = try regularFileInfo(at: manifestURL, fileManager: fileManager)
        resourceIdentities.insert(manifestInfo.identity)
        try validateDrawings(
            descriptor,
            fileManager: fileManager,
            limits: limits,
            resourceIdentities: &resourceIdentities
        )
        try validateAttachments(
            descriptor,
            fileManager: fileManager,
            limits: limits,
            resourceIdentities: &resourceIdentities
        )
    }

    /// Import and migration gates use deep validation. It streams attachment
    /// checksums in 1 MiB chunks and therefore does not load a large PDF at once.
    static func validateAttachmentChecksums(_ descriptor: PromptNotePackageDescriptor,
                                            fileManager: FileManager = .default) throws {
        for attachment in descriptor.manifest.attachments {
            let url = try containedURL(
                for: attachment.originalRelativePath,
                in: descriptor.fileURL,
                fileManager: fileManager
            )
            guard try PromptNoteFileChecksum.sha256Hex(of: url) == attachment.sha256Hex else {
                throw PromptNotePackageError.attachmentChecksumMismatch(attachment.originalRelativePath)
            }
        }
    }

    static func drawingURL(pageID: UUID,
                           in descriptor: PromptNotePackageDescriptor,
                           fileManager: FileManager = .default,
                           limits: PromptNotePackageLimits = .standard) throws -> URL {
        guard let page = descriptor.manifest.pages.first(where: { $0.id == pageID }) else {
            throw PromptNotePackageError.pageNotFound(pageID)
        }
        let url = try containedURL(
            for: page.drawingRelativePath,
            in: descriptor.fileURL,
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: url.path) else {
            throw PromptNotePackageError.requiredFileMissing(page.drawingRelativePath)
        }
        let info = try regularFileInfo(at: url, fileManager: fileManager)
        guard info.byteCount <= limits.maximumDrawingByteCount else {
            throw PromptNotePackageError.resourceLimitExceeded("a drawing is too large")
        }
        return url
    }

    static func attachmentURL(attachmentID: UUID,
                              in descriptor: PromptNotePackageDescriptor,
                              fileManager: FileManager = .default) throws -> URL {
        guard let attachment = descriptor.manifest.attachments.first(where: { $0.id == attachmentID }) else {
            throw PromptNotePackageError.attachmentNotFound(attachmentID)
        }
        let url = try containedURL(
            for: attachment.originalRelativePath,
            in: descriptor.fileURL,
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: url.path) else {
            throw PromptNotePackageError.requiredFileMissing(attachment.originalRelativePath)
        }
        _ = try regularFileInfo(at: url, fileManager: fileManager)
        return url
    }

    static func containedURL(for relativePath: String,
                             in packageURL: URL,
                             fileManager: FileManager = .default) throws -> URL {
        try PromptNoteManifest.validateRelativePath(relativePath)
        let rootURL = packageURL.standardizedFileURL
        let candidateURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard candidateURL.path.hasPrefix(rootURL.path + "/") else {
            throw PromptNotePackageError.invalidRelativePath(relativePath)
        }
        try rejectSymbolicLinks(
            from: rootURL,
            through: relativePath,
            fileManager: fileManager
        )
        return candidateURL
    }

    static func validatePackageURL(_ packageURL: URL,
                                   fileManager: FileManager = .default,
                                   requiresPackageExtension: Bool = true) throws {
        if requiresPackageExtension,
           NoteFileFormat.detect(from: packageURL) != .package {
            throw PromptNotePackageError.invalidPackageExtension(packageURL.path)
        }
        if isSymbolicLink(packageURL, fileManager: fileManager) {
            throw PromptNotePackageError.symbolicLinkNotAllowed(packageURL.path)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PromptNotePackageError.packageNotFound(packageURL.path)
        }
    }

    private struct RegularFileInfo {
        let byteCount: Int64
        let identity: String
    }

    private static func regularFileInfo(at url: URL,
                                        fileManager: FileManager) throws -> RegularFileInfo {
        if isSymbolicLink(url, fileManager: fileManager) {
            throw PromptNotePackageError.symbolicLinkNotAllowed(url.path)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PromptNotePackageError.requiredFileNotRegular(url.path)
        }
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let identity: String
        if let systemNumber, let fileNumber {
            identity = "\(systemNumber):\(fileNumber)"
        } else {
            let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey])
            if let resourceIdentifier = values.fileResourceIdentifier {
                identity = "resource:\(String(describing: resourceIdentifier))"
            } else {
                identity = "path:\(url.standardizedFileURL.path)"
            }
        }
        return RegularFileInfo(byteCount: byteCount, identity: identity)
    }

    private static func validateDrawings(_ descriptor: PromptNotePackageDescriptor,
                                         fileManager: FileManager,
                                         limits: PromptNotePackageLimits,
                                         resourceIdentities: inout Set<String>) throws {
        var totalByteCount: Int64 = 0
        for page in descriptor.manifest.pages {
            let url = try drawingURL(
                pageID: page.id,
                in: descriptor,
                fileManager: fileManager,
                limits: limits
            )
            let info = try regularFileInfo(at: url, fileManager: fileManager)
            guard resourceIdentities.insert(info.identity).inserted else {
                throw PromptNotePackageError.resourceAlias(page.drawingRelativePath)
            }
            totalByteCount += info.byteCount
            guard totalByteCount <= limits.maximumTotalDrawingByteCount else {
                throw PromptNotePackageError.resourceLimitExceeded("drawings are too large")
            }
        }
    }

    private static func validateAttachments(_ descriptor: PromptNotePackageDescriptor,
                                            fileManager: FileManager,
                                            limits: PromptNotePackageLimits,
                                            resourceIdentities: inout Set<String>) throws {
        var totalByteCount: Int64 = 0
        for attachment in descriptor.manifest.attachments {
            let path = attachment.originalRelativePath
            let url = try containedURL(for: path, in: descriptor.fileURL, fileManager: fileManager)
            guard fileManager.fileExists(atPath: url.path) else {
                throw PromptNotePackageError.requiredFileMissing(path)
            }
            let info = try regularFileInfo(at: url, fileManager: fileManager)
            guard info.byteCount == attachment.byteCount else {
                throw PromptNotePackageError.attachmentSizeMismatch(path)
            }
            guard info.byteCount <= limits.maximumAttachmentByteCount else {
                throw PromptNotePackageError.resourceLimitExceeded("an attachment is too large")
            }
            totalByteCount += info.byteCount
            guard totalByteCount <= limits.maximumTotalAttachmentByteCount else {
                throw PromptNotePackageError.resourceLimitExceeded("attachments are too large")
            }
            guard resourceIdentities.insert(info.identity).inserted else {
                throw PromptNotePackageError.resourceAlias(path)
            }
        }
    }

    private static func rejectSymbolicLinks(from rootURL: URL,
                                            through relativePath: String,
                                            fileManager: FileManager) throws {
        if isSymbolicLink(rootURL, fileManager: fileManager) {
            throw PromptNotePackageError.symbolicLinkNotAllowed(rootURL.path)
        }
        var currentURL = rootURL
        for component in relativePath.split(separator: "/") {
            currentURL.appendPathComponent(String(component))
            if fileManager.fileExists(atPath: currentURL.path),
               isSymbolicLink(currentURL, fileManager: fileManager) {
                throw PromptNotePackageError.symbolicLinkNotAllowed(currentURL.path)
            }
        }
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

}
