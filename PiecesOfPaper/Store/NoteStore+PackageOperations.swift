import Foundation

extension NoteStore {
    func loadPackageResult(_ entry: NoteIndexEntry) async -> Result<PromptNotePackageDescriptor, Error> {
        do {
            let descriptor = try await packageRepository.loadManifest(from: entry.fileURL)
            recordPackageMetadata(descriptor, entry: entry)
            return .success(descriptor)
        } catch {
            return .failure(error)
        }
    }

    func importPDF(from sourceURL: URL,
                   securityScopeIsActive: Bool = false) async throws -> PromptNotePackageDescriptor {
        guard let directoryURL = NoteDirectory.inbox.url else {
            throw NoteRepositoryError.directoryNotAvailable
        }
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        let destinationURL = directoryURL.appendingPathComponent(
            FilePath.packageFileName,
            isDirectory: true
        )
        let ownsSecurityScope = !securityScopeIsActive
            && sourceURL.startAccessingSecurityScopedResource()
        defer {
            if ownsSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        // Work from an app-owned copy. Files providers are allowed to vend
        // coordinated, short-lived URLs, and PDFKit performs several reads
        // while inspecting the document and building its package.
        let stagingDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptNoteImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectoryURL) }
        let stagedURL = stagingDirectoryURL.appendingPathComponent(
            sourceURL.lastPathComponent,
            isDirectory: false
        )
        try await CoordinatedFileAccess.read(at: sourceURL) { coordinatedURL in
            try FileManager.default.copyItem(at: coordinatedURL, to: stagedURL)
        }

        let descriptor = try await packageRepository.createPDF(
            from: stagedURL,
            at: destinationURL
        )
        let attributes = noteRepository.fileAttributes(at: destinationURL)
        let entry = NoteIndexEntry(
            fileURL: destinationURL,
            creationDate: attributes?.creationDate ?? descriptor.manifest.createdDate,
            contentModificationDate: attributes?.contentModificationDate ?? descriptor.manifest.updatedDate
        )
        upsertEntry(entry, in: .inbox)
        recordPackageMetadata(descriptor, entry: entry)
        return descriptor
    }

    func openPackage(_ descriptor: PromptNotePackageDescriptor) {
        openedNote = nil
        openedPackage = descriptor
    }

    private func recordPackageMetadata(_ descriptor: PromptNotePackageDescriptor,
                                       entry: NoteIndexEntry) {
        metadataByFileName[entry.fileName] = NoteMetadata(
            id: descriptor.manifest.documentID,
            tagIds: descriptor.manifest.tagIDs,
            updatedDate: entry.updatedDate
        )
        schedulePersist()
    }
}
