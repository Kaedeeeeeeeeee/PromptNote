import Foundation
import PencilKit

struct PromptNotePackageRepository {
    typealias DataWriter = (Data, URL) throws -> Void

    private let fileManager: FileManager
    private let limits: PromptNotePackageLimits
    private let manifestWriter: DataWriter
    private let drawingWriter: DataWriter

    init(fileManager: FileManager = .default,
         limits: PromptNotePackageLimits = .standard,
         manifestWriter: @escaping DataWriter = { data, url in
             try data.write(to: url, options: .atomic)
         },
         drawingWriter: @escaping DataWriter = { data, url in
             try data.write(to: url, options: .atomic)
         }) {
        self.fileManager = fileManager
        self.limits = limits
        self.manifestWriter = manifestWriter
        self.drawingWriter = drawingWriter
    }

    func createBlank(at packageURL: URL,
                     documentID: UUID = UUID(),
                     pageID: UUID = UUID(),
                     title: String = "",
                     tagIDs: [UUID] = [],
                     createdDate: Date = Date(),
                     updatedDate: Date? = nil,
                     pageSize: PromptNotePageSize = .defaultFreeform,
                     drawing: PKDrawing = PKDrawing()) async throws -> PromptNotePackageDescriptor {
        guard NoteFileFormat.detect(from: packageURL) == .package else {
            throw PromptNotePackageError.invalidPackageExtension(packageURL.path)
        }
        let revision = UUID()
        let page = PromptNotePage(
            id: pageID,
            size: pageSize,
            coordinateSpace: .rotatedPagePointsTopLeft,
            background: .blank,
            drawingRevision: revision,
            drawingRelativePath: PromptNoteManifest.drawingRelativePath(
                pageID: pageID,
                revision: revision
            )
        )
        let manifest = PromptNoteManifest(
            schemaVersion: .current,
            drawingFormatVersion: PromptNoteManifest.drawingFormatVersion,
            coordinateTransformVersion: PromptNoteManifest.coordinateTransformVersion,
            documentID: documentID,
            title: title,
            tagIDs: tagIDs,
            createdDate: createdDate,
            updatedDate: updatedDate ?? createdDate,
            layoutMode: .freeform,
            pages: [page],
            attachments: []
        )
        return try await create(
            manifest: manifest,
            drawings: [pageID: drawing],
            at: packageURL
        )
    }

    func loadManifest(from packageURL: URL) async throws -> PromptNotePackageDescriptor {
        try await CoordinatedFileAccess.read(at: packageURL) { coordinatedURL in
            try PromptNotePackageReader.loadManifest(
                from: coordinatedURL,
                fileManager: fileManager,
                limits: limits
            )
        }
    }

    func loadDrawing(pageID: UUID, from packageURL: URL) async throws -> PKDrawing {
        try await CoordinatedFileAccess.read(at: packageURL) { coordinatedURL in
            let descriptor = try PromptNotePackageReader.loadManifest(
                from: coordinatedURL,
                fileManager: fileManager,
                limits: limits
            )
            return try PromptNoteDrawingStore.loadDrawing(
                pageID: pageID,
                from: descriptor,
                fileManager: fileManager,
                limits: limits
            )
        }
    }

    /// Used before promotion during import/migration. Normal opening remains
    /// lazy and does not hash a large PDF or decode every page drawing.
    func validateDeep(at packageURL: URL,
                      requiresPackageExtension: Bool = true) async throws -> PromptNotePackageDescriptor {
        try await CoordinatedFileAccess.read(at: packageURL) { coordinatedURL in
            let descriptor = try PromptNotePackageReader.loadManifest(
                from: coordinatedURL,
                fileManager: fileManager,
                limits: limits,
                requiresPackageExtension: requiresPackageExtension
            )
            try validateDeep(descriptor)
            return descriptor
        }
    }

    /// Copy-on-write drawing revisions make the manifest replacement the only
    /// logical commit point. A failed manifest write leaves the old revision
    /// readable and the uncommitted drawing is removed best-effort.
    func saveDrawing(_ drawing: PKDrawing,
                     pageID: UUID,
                     in packageURL: URL,
                     updatedDate: Date = Date()) async throws -> PromptNotePackageDescriptor {
        let drawingData = drawing.dataRepresentation()
        guard Int64(drawingData.count) <= limits.maximumDrawingByteCount else {
            throw PromptNotePackageError.resourceLimitExceeded("a drawing is too large")
        }
        let committer = PromptNoteDrawingCommitter(
            fileManager: fileManager,
            limits: limits,
            manifestWriter: { manifest, url in try write(manifest, to: url) },
            drawingWriter: drawingWriter
        )
        return try await CoordinatedFileAccess.write(at: packageURL, options: .forMerging) { coordinatedURL in
            try committer.save(
                drawingData,
                pageID: pageID,
                in: coordinatedURL,
                updatedDate: updatedDate
            )
        }
    }

    private func create(manifest: PromptNoteManifest,
                        drawings: [UUID: PKDrawing],
                        at packageURL: URL) async throws -> PromptNotePackageDescriptor {
        try manifest.validate()
        guard !fileManager.fileExists(atPath: packageURL.path) else {
            throw PromptNotePackageError.destinationAlreadyExists(packageURL.path)
        }
        let parentURL = packageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let stagingURL = parentURL.appendingPathComponent(
            ".promptnote-staging-\(UUID().uuidString).staging",
            isDirectory: true
        )
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        try writePackageContents(manifest: manifest, drawings: drawings, to: stagingURL)
        let stagedDescriptor = try PromptNotePackageReader.loadManifest(
            from: stagingURL,
            fileManager: fileManager,
            limits: limits,
            requiresPackageExtension: false
        )
        try validateDeep(stagedDescriptor)
        _ = try await CoordinatedFileAccess.move(from: stagingURL, to: packageURL)
        shouldRemoveStaging = false
        return try PromptNotePackageReader.loadManifest(
            from: packageURL,
            fileManager: fileManager,
            limits: limits
        )
    }

    private func writePackageContents(manifest: PromptNoteManifest,
                                      drawings: [UUID: PKDrawing],
                                      to packageURL: URL) throws {
        for page in manifest.pages {
            guard let drawing = drawings[page.id] else {
                throw PromptNotePackageError.requiredFileMissing(page.drawingRelativePath)
            }
            let drawingData = drawing.dataRepresentation()
            guard Int64(drawingData.count) <= limits.maximumDrawingByteCount else {
                throw PromptNotePackageError.resourceLimitExceeded("a drawing is too large")
            }
            let drawingURL = try PromptNotePackageReader.containedURL(
                for: page.drawingRelativePath,
                in: packageURL,
                fileManager: fileManager
            )
            try fileManager.createDirectory(
                at: drawingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try drawingWriter(drawingData, drawingURL)
        }
        try write(manifest, to: packageURL)
    }

    private func write(_ manifest: PromptNoteManifest, to packageURL: URL) throws {
        try manifest.validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let manifestURL = try PromptNotePackageReader.containedURL(
            for: PromptNotePackageReader.manifestFileName,
            in: packageURL,
            fileManager: fileManager
        )
        try manifestWriter(encoder.encode(manifest), manifestURL)
    }

    private func validateDeep(_ descriptor: PromptNotePackageDescriptor) throws {
        try PromptNotePackageReader.validateStructure(
            descriptor,
            fileManager: fileManager,
            limits: limits
        )
        try PromptNotePackageReader.validateAttachmentChecksums(
            descriptor,
            fileManager: fileManager
        )
        for page in descriptor.manifest.pages {
            _ = try PromptNoteDrawingStore.loadDrawing(
                pageID: page.id,
                from: descriptor,
                fileManager: fileManager,
                limits: limits
            )
        }
    }
}
