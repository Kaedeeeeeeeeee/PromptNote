import Foundation
import PencilKit
import Testing
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
