import Foundation

enum PromptNotePackageError: LocalizedError {
    case invalidPackageExtension(String)
    case destinationAlreadyExists(String)
    case packageNotFound(String)
    case manifestMissing
    case invalidManifest(String)
    case unsupportedSchemaMajor(found: Int, supported: Int)
    case readOnlyFutureMinor(found: Int, supported: Int)
    case unsupportedDrawingFormat(Int)
    case unsupportedCoordinateTransform(Int)
    case invalidRelativePath(String)
    case invalidBackground(UUID)
    case requiredFileMissing(String)
    case requiredFileNotRegular(String)
    case symbolicLinkNotAllowed(String)
    case resourceAlias(String)
    case resourceLimitExceeded(String)
    case drawingUnreadable(UUID)
    case attachmentSizeMismatch(String)
    case attachmentChecksumMismatch(String)
    case pageNotFound(UUID)
    case attachmentNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidPackageExtension(let path):
            "The document package must use the .promptnote extension: \(path)"
        case .destinationAlreadyExists(let path):
            "A document already exists at \(path)."
        case .packageNotFound(let path):
            "No PromptNote package exists at \(path)."
        case .manifestMissing:
            "The PromptNote package has no manifest."
        case .invalidManifest(let reason):
            "The PromptNote manifest is invalid: \(reason)"
        case let .unsupportedSchemaMajor(found, supported):
            "This document uses schema version \(found), but this app supports version \(supported)."
        case let .readOnlyFutureMinor(found, supported):
            "This document uses schema minor version \(found). Version \(supported) can open it read-only."
        case .unsupportedDrawingFormat(let version):
            "This document uses unsupported drawing format version \(version)."
        case .unsupportedCoordinateTransform(let version):
            "This document uses unsupported coordinate transform version \(version)."
        case .invalidRelativePath(let path):
            "The manifest contains an unsafe or misplaced path: \(path)"
        case .invalidBackground(let pageID):
            "Page \(pageID) has an invalid background reference."
        case .requiredFileMissing(let path):
            "The package is missing required file \(path)."
        case .requiredFileNotRegular(let path):
            "The package entry must be a regular file: \(path)"
        case .symbolicLinkNotAllowed(let path):
            "Symbolic links are not allowed in PromptNote packages: \(path)"
        case .resourceAlias(let path):
            "Multiple package entries refer to the same file resource: \(path)"
        case .resourceLimitExceeded(let reason):
            "The package exceeds a safety limit: \(reason)"
        case .drawingUnreadable(let pageID):
            "The drawing for page \(pageID) cannot be read."
        case .attachmentSizeMismatch(let path):
            "The attachment size does not match the manifest: \(path)"
        case .attachmentChecksumMismatch(let path):
            "The attachment checksum does not match the manifest: \(path)"
        case .pageNotFound(let pageID):
            "No page with ID \(pageID) exists in this document."
        case .attachmentNotFound(let attachmentID):
            "No attachment with ID \(attachmentID) exists in this document."
        }
    }
}
