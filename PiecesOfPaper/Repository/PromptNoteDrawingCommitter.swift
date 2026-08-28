import Foundation

/// Commits one drawing with a copy-on-write revision. The manifest is the
/// package's logical commit point, so a failed manifest replacement leaves the
/// previously referenced drawing intact.
struct PromptNoteDrawingCommitter {
    typealias ManifestWriter = (PromptNoteManifest, URL) throws -> Void
    typealias DataWriter = (Data, URL) throws -> Void

    let fileManager: FileManager
    let limits: PromptNotePackageLimits
    let manifestWriter: ManifestWriter
    let drawingWriter: DataWriter

    func save(_ drawingData: Data,
              pageID: UUID,
              in packageURL: URL,
              updatedDate: Date) throws -> PromptNotePackageDescriptor {
        var descriptor = try PromptNotePackageReader.loadManifest(
            from: packageURL,
            fileManager: fileManager,
            limits: limits
        )
        try requireWritableSchema(descriptor.manifest.schemaVersion)
        guard let pageIndex = descriptor.manifest.pages.firstIndex(where: { $0.id == pageID }) else {
            throw PromptNotePackageError.pageNotFound(pageID)
        }

        let oldPage = descriptor.manifest.pages[pageIndex]
        let oldDrawingURL = try PromptNotePackageReader.drawingURL(
            pageID: pageID,
            in: descriptor,
            fileManager: fileManager,
            limits: limits
        )
        let newDrawing = try writeNewRevision(
            drawingData,
            pageID: pageID,
            packageURL: packageURL
        )
        update(
            &descriptor.manifest,
            pageIndex: pageIndex,
            revision: newDrawing.revision,
            relativePath: newDrawing.relativePath,
            updatedDate: updatedDate
        )
        do {
            try manifestWriter(descriptor.manifest, packageURL)
        } catch {
            try? fileManager.removeItem(at: newDrawing.url)
            throw error
        }

        removeObsoleteResources(oldPage: oldPage, oldDrawingURL: oldDrawingURL, packageURL: packageURL)
        return descriptor
    }

    private func requireWritableSchema(_ schemaVersion: PromptNoteSchemaVersion) throws {
        guard schemaVersion.minor <= PromptNoteSchemaVersion.current.minor else {
            throw PromptNotePackageError.readOnlyFutureMinor(
                found: schemaVersion.minor,
                supported: PromptNoteSchemaVersion.current.minor
            )
        }
    }

    private func writeNewRevision(_ data: Data,
                                  pageID: UUID,
                                  packageURL: URL) throws -> DrawingRevision {
        let revision = UUID()
        let relativePath = PromptNoteManifest.drawingRelativePath(pageID: pageID, revision: revision)
        let url = try PromptNotePackageReader.containedURL(
            for: relativePath,
            in: packageURL,
            fileManager: fileManager
        )
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try drawingWriter(data, url)
        return DrawingRevision(revision: revision, relativePath: relativePath, url: url)
    }

    private func update(_ manifest: inout PromptNoteManifest,
                        pageIndex: Int,
                        revision: UUID,
                        relativePath: String,
                        updatedDate: Date) {
        manifest.pages[pageIndex].drawingRevision = revision
        manifest.pages[pageIndex].drawingRelativePath = relativePath
        manifest.pages[pageIndex].previewRelativePath = nil
        manifest.pages[pageIndex].previewDrawingRevision = nil
        manifest.updatedDate = updatedDate
    }

    private func removeObsoleteResources(oldPage: PromptNotePage,
                                         oldDrawingURL: URL,
                                         packageURL: URL) {
        try? fileManager.removeItem(at: oldDrawingURL)
        guard let oldPreviewPath = oldPage.previewRelativePath,
              let oldPreviewURL = try? PromptNotePackageReader.containedURL(
                  for: oldPreviewPath,
                  in: packageURL,
                  fileManager: fileManager
              ) else {
            return
        }
        try? fileManager.removeItem(at: oldPreviewURL)
    }

    private struct DrawingRevision {
        let revision: UUID
        let relativePath: String
        let url: URL
    }
}
