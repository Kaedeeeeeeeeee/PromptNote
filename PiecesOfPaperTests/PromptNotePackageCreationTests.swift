import Foundation
import PencilKit
import Testing
import UIKit
@testable import Pieces_of_Paper

struct PromptNotePackageCreationTests {
    @Test func createBlank_roundTripsManifestAndDrawing() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("First.promptnote", isDirectory: true)
        let documentID = UUID()
        let pageID = UUID()
        let tagID = UUID()
        let createdDate = Date(timeIntervalSince1970: 1_000)
        let updatedDate = Date(timeIntervalSince1970: 2_000)
        let drawing = PKDrawing.stub(points: 7)
        let repository = PromptNotePackageRepository()

        let created = try await repository.createBlank(
            at: packageURL,
            documentID: documentID,
            pageID: pageID,
            title: "First",
            tagIDs: [tagID],
            createdDate: createdDate,
            updatedDate: updatedDate,
            drawing: drawing
        )
        let reopened = try await repository.loadManifest(from: packageURL)
        let reopenedDrawing = try await repository.loadDrawing(pageID: pageID, from: packageURL)

        #expect(created == reopened)
        #expect(reopened.manifest.documentID == documentID)
        #expect(reopened.manifest.tagIDs == [tagID])
        #expect(reopened.manifest.createdDate == createdDate)
        #expect(reopened.manifest.updatedDate == updatedDate)
        #expect(reopenedDrawing == drawing)
    }

    @Test func createBlank_doesNotOverwriteExistingDestination() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("Existing.promptnote")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: false)
        let markerURL = packageURL.appendingPathComponent("marker")
        let marker = Data("keep me".utf8)
        try marker.write(to: markerURL)

        do {
            _ = try await PromptNotePackageRepository().createBlank(at: packageURL)
            Issue.record("expected destination collision")
        } catch PromptNotePackageError.destinationAlreadyExists(let path) {
            #expect(path == packageURL.path)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(try Data(contentsOf: markerURL) == marker)
    }

    @Test func createBlank_cleansStagingAfterWriteFailure() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("Failure.promptnote")
        let repository = PromptNotePackageRepository(drawingWriter: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })

        await #expect(throws: CocoaError.self) {
            _ = try await repository.createBlank(at: packageURL)
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.isEmpty)
    }

    @Test func createBlank_concurrentCreatorsDoNotOverwrite() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("Race.promptnote")
        let repository = PromptNotePackageRepository()

        async let first = attemptCreate(repository: repository, at: packageURL, title: "First")
        async let second = attemptCreate(repository: repository, at: packageURL, title: "Second")
        let outcomes = await [first, second]

        #expect(outcomes.filter { $0 }.count == 1)
        let descriptor = try await repository.loadManifest(from: packageURL)
        #expect(["First", "Second"].contains(descriptor.manifest.title))
    }

    @Test func createPDF_preservesOriginalAndBuildsOnePageRecordPerPDFPage() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Meeting Notes.pdf")
        let packageURL = directory.appendingPathComponent("Imported.promptnote")
        let sourceData = makePDFData()
        try sourceData.write(to: sourceURL)
        let repository = PromptNotePackageRepository()

        let descriptor = try await repository.createPDF(from: sourceURL, at: packageURL)

        #expect(descriptor.manifest.title == "Meeting Notes")
        #expect(descriptor.manifest.layoutMode == .paged)
        #expect(descriptor.manifest.pages.count == 2)
        let attachment = try #require(descriptor.manifest.attachments.first)
        #expect(attachment.originalFilename == "Meeting Notes.pdf")
        #expect(attachment.contentTypeIdentifier == "com.adobe.pdf")
        #expect(attachment.pageCount == 2)
        #expect(attachment.byteCount == Int64(sourceData.count))
        let importedURL = try PromptNotePackageReader.attachmentURL(
            attachmentID: attachment.id,
            in: descriptor
        )
        #expect(try Data(contentsOf: importedURL) == sourceData)
        #expect(descriptor.manifest.pages[0].size == PromptNotePageSize(width: 612, height: 792))
        #expect(descriptor.manifest.pages[1].size == PromptNotePageSize(width: 792, height: 612))
        for page in descriptor.manifest.pages {
            #expect(page.background.kind == .pdf)
            #expect(page.background.attachmentID == attachment.id)
            let drawing = try await repository.loadDrawing(pageID: page.id, from: packageURL)
            #expect(drawing.strokes.isEmpty)
        }
    }

    private func makePDFData() -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        return renderer.pdfData { context in
            context.beginPage()
            "First page".draw(at: CGPoint(x: 40, y: 40), withAttributes: nil)
            context.beginPage(
                withBounds: CGRect(x: 0, y: 0, width: 792, height: 612),
                pageInfo: [:]
            )
            "Second page".draw(at: CGPoint(x: 40, y: 40), withAttributes: nil)
        }
    }

    private func attemptCreate(repository: PromptNotePackageRepository,
                               at packageURL: URL,
                               title: String) async -> Bool {
        do {
            _ = try await repository.createBlank(at: packageURL, title: title)
            return true
        } catch {
            return false
        }
    }
}
