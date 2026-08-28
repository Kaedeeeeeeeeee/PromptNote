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

    func importPDF(from sourceURL: URL) async throws -> PromptNotePackageDescriptor {
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
        let scopedURL = sourceURL.startAccessingSecurityScopedResource() ? sourceURL : nil
        defer { scopedURL?.stopAccessingSecurityScopedResource() }
        let descriptor = try await packageRepository.createPDF(
            from: sourceURL,
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
