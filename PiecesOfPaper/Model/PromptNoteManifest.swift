import Foundation
import UniformTypeIdentifiers

struct PromptNoteSchemaVersion: Codable, Equatable {
    static let current = PromptNoteSchemaVersion(major: 2, minor: 0)

    var major: Int
    var minor: Int
}

enum PromptNoteLayoutMode: String, Codable, Equatable {
    case freeform
    case paged
}

/// Persisted PencilKit coordinates are PDF points in a top-left coordinate
/// system after the source page rotation has been applied. They never depend
/// on the current screen width or zoom scale.
enum PromptNoteCoordinateSpace: String, Codable, Equatable {
    case rotatedPagePointsTopLeft
}

struct PromptNotePageSize: Codable, Equatable {
    var width: Double
    var height: Double

    static let defaultFreeform = PromptNotePageSize(width: 1_024, height: 1_366)
}

struct PromptNoteRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct PromptNotePDFPageGeometry: Codable, Equatable {
    /// The source PDF crop box, including a potentially non-zero origin.
    var sourceCropBox: PromptNoteRect
    /// PDF rotation normalized to 0, 90, 180, or 270 degrees clockwise.
    var rotationDegrees: Int

    var rotatedSize: PromptNotePageSize {
        switch rotationDegrees {
        case 90, 270:
            PromptNotePageSize(width: sourceCropBox.height, height: sourceCropBox.width)
        default:
            PromptNotePageSize(width: sourceCropBox.width, height: sourceCropBox.height)
        }
    }
}

struct PromptNotePageBackground: Codable, Equatable {
    enum Kind: String, Codable {
        case blank
        case image
        case pdf
    }

    var kind: Kind
    var attachmentID: UUID?
    var pdfPageIndex: Int?
    var pdfGeometry: PromptNotePDFPageGeometry?

    static let blank = PromptNotePageBackground(kind: .blank)

    static func image(attachmentID: UUID) -> PromptNotePageBackground {
        PromptNotePageBackground(kind: .image, attachmentID: attachmentID)
    }

    static func pdf(attachmentID: UUID,
                    pageIndex: Int,
                    geometry: PromptNotePDFPageGeometry) -> PromptNotePageBackground {
        PromptNotePageBackground(
            kind: .pdf,
            attachmentID: attachmentID,
            pdfPageIndex: pageIndex,
            pdfGeometry: geometry
        )
    }
}

struct PromptNotePage: Codable, Equatable, Identifiable {
    var id: UUID
    var size: PromptNotePageSize
    var coordinateSpace: PromptNoteCoordinateSpace
    var background: PromptNotePageBackground
    var drawingRevision: UUID
    var drawingRelativePath: String
    var previewRelativePath: String?
    var previewDrawingRevision: UUID?
}

struct PromptNoteAttachment: Codable, Equatable, Identifiable {
    var id: UUID
    var originalFilename: String
    var contentTypeIdentifier: String
    var originalRelativePath: String
    var byteCount: Int64
    var sha256Hex: String
    var pageCount: Int?
}

struct PromptNoteManifest: Codable, Equatable {
    static let drawingFormatVersion = 1
    static let coordinateTransformVersion = 1

    var schemaVersion: PromptNoteSchemaVersion
    var drawingFormatVersion: Int
    var coordinateTransformVersion: Int
    var documentID: UUID
    var title: String
    var tagIDs: [UUID]
    var createdDate: Date
    var updatedDate: Date
    var layoutMode: PromptNoteLayoutMode
    var pages: [PromptNotePage]
    var attachments: [PromptNoteAttachment]

    func validate() throws {
        guard schemaVersion.major == PromptNoteSchemaVersion.current.major else {
            throw PromptNotePackageError.unsupportedSchemaMajor(
                found: schemaVersion.major,
                supported: PromptNoteSchemaVersion.current.major
            )
        }
        guard schemaVersion.minor >= 0 else {
            throw PromptNotePackageError.invalidManifest("Schema minor version cannot be negative.")
        }
        guard drawingFormatVersion == Self.drawingFormatVersion else {
            throw PromptNotePackageError.unsupportedDrawingFormat(drawingFormatVersion)
        }
        guard coordinateTransformVersion == Self.coordinateTransformVersion else {
            throw PromptNotePackageError.unsupportedCoordinateTransform(coordinateTransformVersion)
        }
        guard !pages.isEmpty else {
            throw PromptNotePackageError.invalidManifest("A document must contain at least one page.")
        }
        try validateUniqueIDs()
        let attachmentsByID = try validateAttachments()
        try validatePages(attachmentsByID: attachmentsByID)
    }

    private func validateUniqueIDs() throws {
        guard Set(tagIDs).count == tagIDs.count else {
            throw PromptNotePackageError.invalidManifest("Tag IDs must be unique.")
        }
        guard Set(pages.map(\.id)).count == pages.count else {
            throw PromptNotePackageError.invalidManifest("Page IDs must be unique.")
        }
        guard Set(attachments.map(\.id)).count == attachments.count else {
            throw PromptNotePackageError.invalidManifest("Attachment IDs must be unique.")
        }
    }

    private func validateAttachments() throws -> [UUID: PromptNoteAttachment] {
        var attachmentsByID: [UUID: PromptNoteAttachment] = [:]
        var paths = Set<String>()
        for attachment in attachments {
            try Self.validateDisplayFilename(attachment.originalFilename)
            guard UTType(attachment.contentTypeIdentifier) != nil else {
                throw PromptNotePackageError.invalidManifest(
                    "Attachment \(attachment.id) has an invalid content type identifier."
                )
            }
            try Self.validateRelativePath(attachment.originalRelativePath)
            let expectedPrefix = "attachments/\(Self.pathComponent(for: attachment.id))/"
            guard attachment.originalRelativePath.hasPrefix(expectedPrefix) else {
                throw PromptNotePackageError.invalidRelativePath(attachment.originalRelativePath)
            }
            guard attachment.byteCount >= 0 else {
                throw PromptNotePackageError.invalidManifest("Attachment byte counts cannot be negative.")
            }
            guard attachment.sha256Hex.count == 64,
                  attachment.sha256Hex == attachment.sha256Hex.lowercased(),
                  attachment.sha256Hex.allSatisfy({ $0.isHexDigit }) else {
                throw PromptNotePackageError.invalidManifest(
                    "Attachment checksums must be lowercase SHA-256 hex strings."
                )
            }
            let contentType = UTType(attachment.contentTypeIdentifier)
            if contentType?.conforms(to: .pdf) == true {
                guard let pageCount = attachment.pageCount, pageCount > 0 else {
                    throw PromptNotePackageError.invalidManifest("PDF attachments require a positive page count.")
                }
            } else if attachment.pageCount != nil {
                throw PromptNotePackageError.invalidManifest("Only PDF attachments can declare a page count.")
            }
            guard paths.insert(attachment.originalRelativePath).inserted else {
                throw PromptNotePackageError.invalidManifest("Attachment paths must be unique.")
            }
            attachmentsByID[attachment.id] = attachment
        }
        return attachmentsByID
    }

    private func validatePages(attachmentsByID: [UUID: PromptNoteAttachment]) throws {
        var drawingPaths = Set<String>()
        for page in pages {
            try Self.validate(page.size)
            guard page.coordinateSpace == .rotatedPagePointsTopLeft else {
                throw PromptNotePackageError.invalidManifest("Page coordinate space is unsupported.")
            }
            let pageDirectory = "pages/\(Self.pathComponent(for: page.id))"
            let revision = Self.pathComponent(for: page.drawingRevision)
            let expectedDrawingPath = "\(pageDirectory)/drawings/\(revision).data"
            try Self.validateRelativePath(page.drawingRelativePath)
            guard page.drawingRelativePath == expectedDrawingPath else {
                throw PromptNotePackageError.invalidRelativePath(page.drawingRelativePath)
            }
            guard drawingPaths.insert(page.drawingRelativePath).inserted else {
                throw PromptNotePackageError.invalidManifest("Drawing paths must be unique.")
            }
            try validatePreview(for: page, pageDirectory: pageDirectory)
            try validate(
                page.background,
                pageID: page.id,
                pageSize: page.size,
                attachmentsByID: attachmentsByID
            )
        }
    }

    private func validatePreview(for page: PromptNotePage, pageDirectory: String) throws {
        switch (page.previewRelativePath, page.previewDrawingRevision) {
        case (nil, nil):
            return
        case let (path?, revision?):
            try Self.validateRelativePath(path)
            guard path == "\(pageDirectory)/preview.png",
                  revision == page.drawingRevision else {
                throw PromptNotePackageError.invalidManifest(
                    "A page preview must match the current drawing revision."
                )
            }
        default:
            throw PromptNotePackageError.invalidManifest(
                "A page preview path and drawing revision must be stored together."
            )
        }
    }

    private func validate(_ background: PromptNotePageBackground,
                          pageID: UUID,
                          pageSize: PromptNotePageSize,
                          attachmentsByID: [UUID: PromptNoteAttachment]) throws {
        switch background.kind {
        case .blank:
            guard background.attachmentID == nil,
                  background.pdfPageIndex == nil,
                  background.pdfGeometry == nil else {
                throw PromptNotePackageError.invalidBackground(pageID)
            }
        case .image:
            guard let attachmentID = background.attachmentID,
                  let attachment = attachmentsByID[attachmentID],
                  UTType(attachment.contentTypeIdentifier)?.conforms(to: .image) == true,
                  background.pdfPageIndex == nil,
                  background.pdfGeometry == nil else {
                throw PromptNotePackageError.invalidBackground(pageID)
            }
        case .pdf:
            guard let attachmentID = background.attachmentID,
                  let attachment = attachmentsByID[attachmentID],
                  UTType(attachment.contentTypeIdentifier)?.conforms(to: .pdf) == true,
                  let pageIndex = background.pdfPageIndex,
                  let pageCount = attachment.pageCount,
                  pageIndex >= 0,
                  pageIndex < pageCount,
                  let geometry = background.pdfGeometry else {
                throw PromptNotePackageError.invalidBackground(pageID)
            }
            try Self.validate(geometry)
            guard Self.approximatelyEqual(pageSize, geometry.rotatedSize) else {
                throw PromptNotePackageError.invalidBackground(pageID)
            }
        }
    }

    static func pathComponent(for id: UUID) -> String {
        id.uuidString.lowercased()
    }

    static func drawingRelativePath(pageID: UUID, revision: UUID) -> String {
        "pages/\(pathComponent(for: pageID))/drawings/\(pathComponent(for: revision)).data"
    }

    static func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PromptNotePackageError.invalidRelativePath(path)
        }
    }

    private static func validateDisplayFilename(_ filename: String) throws {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PromptNotePackageError.invalidManifest("Attachment filenames must be safe single components.")
        }
    }

    private static func validate(_ size: PromptNotePageSize) throws {
        guard size.width.isFinite, size.width > 0,
              size.height.isFinite, size.height > 0 else {
            throw PromptNotePackageError.invalidManifest("Page dimensions must be finite and positive.")
        }
    }

    private static func validate(_ geometry: PromptNotePDFPageGeometry) throws {
        let box = geometry.sourceCropBox
        guard box.x.isFinite,
              box.y.isFinite,
              box.width.isFinite,
              box.width > 0,
              box.height.isFinite,
              box.height > 0,
              [0, 90, 180, 270].contains(geometry.rotationDegrees) else {
            throw PromptNotePackageError.invalidManifest("PDF page geometry is invalid.")
        }
    }

    private static func approximatelyEqual(_ lhs: PromptNotePageSize,
                                           _ rhs: PromptNotePageSize) -> Bool {
        abs(lhs.width - rhs.width) <= 0.001 && abs(lhs.height - rhs.height) <= 0.001
    }
}
