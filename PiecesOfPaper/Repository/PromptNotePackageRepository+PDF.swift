import Foundation
import PDFKit
import PencilKit
import UniformTypeIdentifiers

extension PromptNotePackageRepository {
    func createPDF(from sourceURL: URL,
                   at packageURL: URL,
                   documentID: UUID = UUID(),
                   title: String? = nil,
                   tagIDs: [UUID] = [],
                   createdDate: Date = Date(),
                   updatedDate: Date? = nil) async throws -> PromptNotePackageDescriptor {
        guard NoteFileFormat.detect(from: packageURL) == .package else {
            throw PromptNotePackageError.invalidPackageExtension(packageURL.path)
        }
        let source = try inspectPDF(at: sourceURL)
        let manifest = PromptNoteManifest(
            schemaVersion: .current,
            drawingFormatVersion: PromptNoteManifest.drawingFormatVersion,
            coordinateTransformVersion: PromptNoteManifest.coordinateTransformVersion,
            documentID: documentID,
            title: title ?? sourceURL.deletingPathExtension().lastPathComponent,
            tagIDs: tagIDs,
            createdDate: createdDate,
            updatedDate: updatedDate ?? createdDate,
            layoutMode: .paged,
            pages: source.pages,
            attachments: [source.attachment]
        )
        return try await create(
            manifest: manifest,
            drawings: source.drawings,
            attachmentSources: [source.attachmentSource],
            at: packageURL
        )
    }

    private func inspectPDF(at sourceURL: URL) throws -> PDFImportSource {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PromptNotePackageError.requiredFileNotRegular(sourceURL.path)
        }
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard byteCount >= 0, byteCount <= limits.maximumAttachmentByteCount else {
            throw PromptNotePackageError.resourceLimitExceeded("the PDF is too large")
        }
        guard let document = PDFDocument(url: sourceURL), document.pageCount > 0 else {
            throw PromptNotePackageError.invalidPDF("The file has no readable pages.")
        }
        guard !document.isLocked else {
            throw PromptNotePackageError.invalidPDF("Password-protected PDFs are not supported yet.")
        }
        guard document.pageCount <= limits.maximumPageCount else {
            throw PromptNotePackageError.resourceLimitExceeded("the PDF has too many pages")
        }
        let attachmentID = UUID()
        let path = attachmentPath(for: attachmentID, sourceURL: sourceURL)
        let attachment = PromptNoteAttachment(
            id: attachmentID,
            originalFilename: sourceURL.lastPathComponent,
            contentTypeIdentifier: UTType.pdf.identifier,
            originalRelativePath: path,
            byteCount: byteCount,
            sha256Hex: try PromptNoteFileChecksum.sha256Hex(of: sourceURL),
            pageCount: document.pageCount
        )
        let content = try makePages(from: document, attachmentID: attachmentID)
        return PDFImportSource(
            attachment: attachment,
            pages: content.pages,
            drawings: content.drawings,
            attachmentSource: AttachmentSource(sourceURL: sourceURL, relativePath: path)
        )
    }

    private func makePages(from document: PDFDocument,
                           attachmentID: UUID) throws -> PDFPageContent {
        var drawings = [UUID: PKDrawing]()
        let pages = try (0..<document.pageCount).map { pageIndex in
            guard let pdfPage = document.page(at: pageIndex) else {
                throw PromptNotePackageError.invalidPDF("Page \(pageIndex + 1) cannot be read.")
            }
            let rotation = ((pdfPage.rotation % 360) + 360) % 360
            guard [0, 90, 180, 270].contains(rotation) else {
                throw PromptNotePackageError.invalidPDF(
                    "Page \(pageIndex + 1) has an unsupported rotation."
                )
            }
            let geometry = pageGeometry(pdfPage, rotation: rotation)
            let pageID = UUID()
            let revision = UUID()
            drawings[pageID] = PKDrawing()
            return PromptNotePage(
                id: pageID,
                size: geometry.rotatedSize,
                coordinateSpace: .rotatedPagePointsTopLeft,
                background: .pdf(attachmentID: attachmentID, pageIndex: pageIndex, geometry: geometry),
                drawingRevision: revision,
                drawingRelativePath: PromptNoteManifest.drawingRelativePath(
                    pageID: pageID,
                    revision: revision
                )
            )
        }
        return PDFPageContent(pages: pages, drawings: drawings)
    }

    private func pageGeometry(_ page: PDFPage, rotation: Int) -> PromptNotePDFPageGeometry {
        let cropBox = page.bounds(for: .cropBox)
        return PromptNotePDFPageGeometry(
            sourceCropBox: PromptNoteRect(
                x: Double(cropBox.origin.x),
                y: Double(cropBox.origin.y),
                width: Double(cropBox.width),
                height: Double(cropBox.height)
            ),
            rotationDegrees: rotation
        )
    }

    private func attachmentPath(for id: UUID, sourceURL: URL) -> String {
        [
            "attachments",
            PromptNoteManifest.pathComponent(for: id),
            sourceURL.lastPathComponent
        ].joined(separator: "/")
    }
}

private struct PDFImportSource {
    let attachment: PromptNoteAttachment
    let pages: [PromptNotePage]
    let drawings: [UUID: PKDrawing]
    let attachmentSource: PromptNotePackageRepository.AttachmentSource
}

private struct PDFPageContent {
    let pages: [PromptNotePage]
    let drawings: [UUID: PKDrawing]
}
