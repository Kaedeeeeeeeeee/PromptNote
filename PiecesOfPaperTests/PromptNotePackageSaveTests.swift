import Foundation
import PencilKit
import Testing
@testable import Pieces_of_Paper

struct PromptNotePackageSaveTests {
    @Test func saveDrawing_commitsNewRevisionWithoutTouchingAttachment() async throws {
        let fixture = try await PromptNotePackageTestSupport.makePackageWithAttachment(name: "Attachment")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let descriptor = try await fixture.repository.loadManifest(from: fixture.packageURL)
        let oldPage = try #require(descriptor.manifest.pages.first)
        let oldDrawingURL = try PromptNotePackageReader.drawingURL(
            pageID: oldPage.id,
            in: descriptor
        )
        let before = try fixture.attachmentURL.resourceValues(
            forKeys: [.contentModificationDateKey, .fileResourceIdentifierKey]
        )
        let beforeDate = try #require(before.contentModificationDate)
        let beforeIdentifier = try #require(before.fileResourceIdentifier)
        let updatedDate = Date(timeIntervalSince1970: 3_000)
        let updatedDrawing = PKDrawing.stub(points: 9)

        let saved = try await fixture.repository.saveDrawing(
            updatedDrawing,
            pageID: oldPage.id,
            in: fixture.packageURL,
            updatedDate: updatedDate
        )
        let newPage = try #require(saved.manifest.pages.first)
        let after = try fixture.attachmentURL.resourceValues(
            forKeys: [.contentModificationDateKey, .fileResourceIdentifierKey]
        )
        let afterIdentifier = try #require(after.fileResourceIdentifier)

        #expect(newPage.drawingRevision != oldPage.drawingRevision)
        #expect(saved.manifest.updatedDate == updatedDate)
        #expect(try await fixture.repository.loadDrawing(
            pageID: oldPage.id,
            from: fixture.packageURL
        ) == updatedDrawing)
        #expect(!FileManager.default.fileExists(atPath: oldDrawingURL.path))
        #expect(try Data(contentsOf: fixture.attachmentURL) == fixture.attachmentData)
        #expect(after.contentModificationDate == beforeDate)
        #expect(String(describing: afterIdentifier) == String(describing: beforeIdentifier))
        _ = try await fixture.repository.validateDeep(at: fixture.packageURL)
    }

    @Test func saveDrawing_manifestFailureLeavesOldLogicalVersionReadable() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("Transaction.promptnote")
        let repository = PromptNotePackageRepository()
        let descriptor = try await repository.createBlank(
            at: packageURL,
            drawing: PKDrawing.stub(points: 4)
        )
        let page = try #require(descriptor.manifest.pages.first)
        let manifestURL = packageURL.appendingPathComponent(PromptNotePackageReader.manifestFileName)
        let oldManifestData = try Data(contentsOf: manifestURL)
        let oldDrawing = try await repository.loadDrawing(pageID: page.id, from: packageURL)
        let failingRepository = PromptNotePackageRepository(manifestWriter: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })

        await #expect(throws: CocoaError.self) {
            _ = try await failingRepository.saveDrawing(
                PKDrawing.stub(points: 10),
                pageID: page.id,
                in: packageURL
            )
        }

        let reopened = try await repository.loadManifest(from: packageURL)
        #expect(reopened.manifest.pages[0].drawingRevision == page.drawingRevision)
        #expect(try await repository.loadDrawing(pageID: page.id, from: packageURL) == oldDrawing)
        #expect(try Data(contentsOf: manifestURL) == oldManifestData)
        let drawingDirectory = try PromptNotePackageReader.drawingURL(pageID: page.id, in: reopened)
            .deletingLastPathComponent()
        let drawingFiles = try FileManager.default.contentsOfDirectory(atPath: drawingDirectory.path)
        #expect(drawingFiles.count == 1)
    }

    @Test func saveDrawing_invalidatesPreviewFromPriorDrawingRevision() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("Preview.promptnote")
        let repository = PromptNotePackageRepository()
        var descriptor = try await repository.createBlank(at: packageURL)
        let pageID = descriptor.manifest.pages[0].id
        let relativePath = "pages/\(PromptNoteManifest.pathComponent(for: pageID))/preview.png"
        let previewURL = try PromptNotePackageReader.containedURL(for: relativePath, in: packageURL)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: previewURL)
        descriptor.manifest.pages[0].previewRelativePath = relativePath
        descriptor.manifest.pages[0].previewDrawingRevision = descriptor.manifest.pages[0].drawingRevision
        try PromptNotePackageTestSupport.write(descriptor.manifest, to: packageURL)

        let saved = try await repository.saveDrawing(
            PKDrawing.stub(points: 6),
            pageID: pageID,
            in: packageURL
        )

        #expect(saved.manifest.pages[0].previewRelativePath == nil)
        #expect(saved.manifest.pages[0].previewDrawingRevision == nil)
        #expect(!FileManager.default.fileExists(atPath: previewURL.path))
    }

    @Test func saveDrawing_rejectsUnknownPagePrecisely() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("UnknownPage.promptnote")
        let repository = PromptNotePackageRepository()
        _ = try await repository.createBlank(at: packageURL)
        let missingPageID = UUID()

        do {
            _ = try await repository.saveDrawing(
                PKDrawing(),
                pageID: missingPageID,
                in: packageURL
            )
            Issue.record("expected missing page")
        } catch PromptNotePackageError.pageNotFound(let pageID) {
            #expect(pageID == missingPageID)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
