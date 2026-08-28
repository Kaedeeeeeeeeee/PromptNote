import Foundation
import PencilKit
import Testing
@testable import Pieces_of_Paper

struct PromptNotePackageSecurityTests {
    @Test func loadManifest_isLazyAboutOtherPageDrawings() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("Lazy.promptnote")
        let repository = PromptNotePackageRepository()
        var descriptor = try await repository.createBlank(at: packageURL)
        let firstPageID = try #require(descriptor.manifest.pages.first?.id)
        let secondPageID = UUID()
        let secondRevision = UUID()
        let secondPath = PromptNoteManifest.drawingRelativePath(
            pageID: secondPageID,
            revision: secondRevision
        )
        descriptor.manifest.pages.append(
            PromptNotePage(
                id: secondPageID,
                size: .defaultFreeform,
                coordinateSpace: .rotatedPagePointsTopLeft,
                background: .blank,
                drawingRevision: secondRevision,
                drawingRelativePath: secondPath
            )
        )
        let secondURL = try PromptNotePackageReader.containedURL(for: secondPath, in: packageURL)
        try FileManager.default.createDirectory(
            at: secondURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a drawing".utf8).write(to: secondURL)
        try PromptNotePackageTestSupport.write(descriptor.manifest, to: packageURL)

        _ = try await repository.loadManifest(from: packageURL)
        _ = try await repository.loadDrawing(pageID: firstPageID, from: packageURL)
        do {
            _ = try await repository.loadDrawing(pageID: secondPageID, from: packageURL)
            Issue.record("expected corrupt second drawing")
        } catch PromptNotePackageError.drawingUnreadable(let pageID) {
            #expect(pageID == secondPageID)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validateDeep_rejectsMissingDrawing() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("Missing.promptnote")
        let repository = PromptNotePackageRepository()
        let descriptor = try await repository.createBlank(at: packageURL)
        let page = try #require(descriptor.manifest.pages.first)
        let drawingURL = try PromptNotePackageReader.drawingURL(pageID: page.id, in: descriptor)
        try FileManager.default.removeItem(at: drawingURL)

        do {
            _ = try await repository.validateDeep(at: packageURL)
            Issue.record("expected missing drawing error")
        } catch PromptNotePackageError.requiredFileMissing(let path) {
            #expect(path == page.drawingRelativePath)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func futureMinor_opensReadOnlyWithoutDroppingUnknownFields() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("FutureMinor.promptnote")
        let repository = PromptNotePackageRepository()
        let descriptor = try await repository.createBlank(at: packageURL)
        let pageID = try #require(descriptor.manifest.pages.first?.id)
        let manifestURL = packageURL.appendingPathComponent(PromptNotePackageReader.manifestFileName)
        try PromptNotePackageTestSupport.addFutureMinorAndUnknownField(to: manifestURL)
        let before = try Data(contentsOf: manifestURL)

        let loaded = try await repository.loadManifest(from: packageURL)
        #expect(loaded.manifest.schemaVersion.minor == 42)
        do {
            _ = try await repository.saveDrawing(PKDrawing.stub(), pageID: pageID, in: packageURL)
            Issue.record("expected future minor to be read-only")
        } catch let PromptNotePackageError.readOnlyFutureMinor(found, supported) {
            #expect(found == 42)
            #expect(supported == 0)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(try Data(contentsOf: manifestURL) == before)
    }

    @Test func loadManifest_rejectsPackageRootSymlink() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("Real.promptnote")
        let aliasURL = directory.appendingPathComponent("Alias.promptnote")
        let repository = PromptNotePackageRepository()
        _ = try await repository.createBlank(at: packageURL)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: packageURL)

        do {
            _ = try await repository.loadManifest(from: aliasURL)
            Issue.record("expected root symlink rejection")
        } catch PromptNotePackageError.symbolicLinkNotAllowed(let path) {
            #expect(path == aliasURL.path)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func loadDrawing_rejectsSamePackageSymlinkAlias() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("Symlink.promptnote")
        let repository = PromptNotePackageRepository()
        let descriptor = try await repository.createBlank(at: packageURL)
        let pageID = try #require(descriptor.manifest.pages.first?.id)
        let drawingURL = try PromptNotePackageReader.drawingURL(pageID: pageID, in: descriptor)
        let aliasTargetURL = drawingURL.deletingLastPathComponent().appendingPathComponent("alias.data")
        try FileManager.default.moveItem(at: drawingURL, to: aliasTargetURL)
        try FileManager.default.createSymbolicLink(at: drawingURL, withDestinationURL: aliasTargetURL)

        do {
            _ = try await repository.loadDrawing(pageID: pageID, from: packageURL)
            Issue.record("expected same-package symlink rejection")
        } catch PromptNotePackageError.symbolicLinkNotAllowed(let path) {
            #expect(path == drawingURL.path)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validateDeep_rejectsHardLinkedPayloadAlias() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("HardLink.promptnote")
        let repository = PromptNotePackageRepository()
        var descriptor = try await repository.createBlank(at: packageURL)
        let pageID = try #require(descriptor.manifest.pages.first?.id)
        let drawingURL = try PromptNotePackageReader.drawingURL(pageID: pageID, in: descriptor)
        let drawingData = try Data(contentsOf: drawingURL)
        let attachmentID = UUID()
        let relativePath = PromptNotePackageTestSupport.attachmentPath(id: attachmentID, filename: "copy.bin")
        let attachmentURL = try PromptNotePackageReader.containedURL(for: relativePath, in: packageURL)
        try FileManager.default.createDirectory(
            at: attachmentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.linkItem(at: drawingURL, to: attachmentURL)
        descriptor.manifest.attachments.append(
            PromptNotePackageTestSupport.makeAttachment(
                id: attachmentID,
                filename: "copy.bin",
                contentType: "public.data",
                relativePath: relativePath,
                data: drawingData
            )
        )
        try PromptNotePackageTestSupport.write(descriptor.manifest, to: packageURL)

        do {
            _ = try await repository.validateDeep(at: packageURL)
            Issue.record("expected hard-link alias rejection")
        } catch PromptNotePackageError.resourceAlias(let path) {
            #expect(path == relativePath)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validateDeep_rejectsSameSizeAttachmentCorruption() async throws {
        let fixture = try await PromptNotePackageTestSupport.makePackageWithAttachment(name: "Checksum")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.repository.validateDeep(at: fixture.packageURL)
        var corrupted = fixture.attachmentData
        corrupted[0] ^= 0xff
        try corrupted.write(to: fixture.attachmentURL, options: .atomic)

        do {
            _ = try await fixture.repository.validateDeep(at: fixture.packageURL)
            Issue.record("expected checksum mismatch")
        } catch PromptNotePackageError.attachmentChecksumMismatch(let path) {
            #expect(path == fixture.relativePath)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func loadManifest_enforcesConfigurablePageLimit() async throws {
        let directory = try PromptNotePackageTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = directory.appendingPathComponent("Limit.promptnote")
        _ = try await PromptNotePackageRepository().createBlank(at: packageURL)
        var limits = PromptNotePackageLimits.standard
        limits.maximumPageCount = 0

        do {
            _ = try await PromptNotePackageRepository(limits: limits).loadManifest(from: packageURL)
            Issue.record("expected page limit rejection")
        } catch PromptNotePackageError.resourceLimitExceeded(let reason) {
            #expect(reason == "too many pages")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
