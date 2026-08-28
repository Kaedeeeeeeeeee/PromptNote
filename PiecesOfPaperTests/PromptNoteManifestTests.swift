import Foundation
import Testing
@testable import Pieces_of_Paper

struct PromptNoteManifestTests {
    @Test func validate_acceptsCompatibleFutureMinorVersion() throws {
        var manifest = makeManifest()
        manifest.schemaVersion.minor = 99

        try manifest.validate()
    }

    @Test func validate_rejectsUnsupportedMajorVersion() {
        var manifest = makeManifest()
        manifest.schemaVersion.major = 3

        do {
            try manifest.validate()
            Issue.record("expected unsupported schema version")
        } catch let PromptNotePackageError.unsupportedSchemaMajor(found, supported) {
            #expect(found == 3)
            #expect(supported == 2)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validate_rejectsDuplicatePageIDs() {
        var manifest = makeManifest()
        manifest.pages.append(manifest.pages[0])

        do {
            try manifest.validate()
            Issue.record("expected duplicate page rejection")
        } catch PromptNotePackageError.invalidManifest(let reason) {
            #expect(reason == "Page IDs must be unique.")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validate_rejectsPathTraversal() {
        var manifest = makeManifest()
        manifest.pages[0].drawingRelativePath = "../outside.data"

        do {
            try manifest.validate()
            Issue.record("expected unsafe path rejection")
        } catch PromptNotePackageError.invalidRelativePath(let path) {
            #expect(path == "../outside.data")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validate_rejectsMissingBackgroundAttachment() {
        var manifest = makeManifest()
        let geometry = PromptNotePDFPageGeometry(
            sourceCropBox: PromptNoteRect(x: 0, y: 0, width: 612, height: 792),
            rotationDegrees: 0
        )
        manifest.pages[0].size = geometry.rotatedSize
        manifest.pages[0].background = .pdf(
            attachmentID: UUID(),
            pageIndex: 0,
            geometry: geometry
        )

        do {
            try manifest.validate()
            Issue.record("expected invalid background rejection")
        } catch PromptNotePackageError.invalidBackground(let pageID) {
            #expect(pageID == manifest.pages[0].id)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validate_acceptsRotatedPDFGeometry() throws {
        var manifest = makeManifest()
        let attachmentID = UUID()
        manifest.attachments = [makePDFAttachment(id: attachmentID, pageCount: 3)]
        let geometry = PromptNotePDFPageGeometry(
            sourceCropBox: PromptNoteRect(x: 12, y: 24, width: 612, height: 792),
            rotationDegrees: 90
        )
        manifest.pages[0].size = PromptNotePageSize(width: 792, height: 612)
        manifest.pages[0].background = .pdf(
            attachmentID: attachmentID,
            pageIndex: 2,
            geometry: geometry
        )

        try manifest.validate()
    }

    @Test func validate_rejectsPDFGeometryThatDoesNotMatchPageSize() {
        var manifest = makeManifest()
        let attachmentID = UUID()
        manifest.attachments = [makePDFAttachment(id: attachmentID, pageCount: 1)]
        let geometry = PromptNotePDFPageGeometry(
            sourceCropBox: PromptNoteRect(x: 0, y: 0, width: 612, height: 792),
            rotationDegrees: 90
        )
        manifest.pages[0].background = .pdf(
            attachmentID: attachmentID,
            pageIndex: 0,
            geometry: geometry
        )

        do {
            try manifest.validate()
            Issue.record("expected PDF geometry mismatch")
        } catch PromptNotePackageError.invalidBackground(let pageID) {
            #expect(pageID == manifest.pages[0].id)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func decode_fixedV2Fixture_withoutOptionalPreviewFields() throws {
        let fixtureURL = try #require(
            Bundle(for: PromptNoteManifestBundleToken.self)
                .url(forResource: "PromptNoteManifest-v2.0", withExtension: "plist")
        )

        let manifest = try PropertyListDecoder().decode(
            PromptNoteManifest.self,
            from: Data(contentsOf: fixtureURL)
        )
        try manifest.validate()

        #expect(manifest.documentID.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(manifest.title == "Golden Note")
        #expect(manifest.pages[0].previewRelativePath == nil)
        #expect(manifest.pages[0].previewDrawingRevision == nil)
    }

    private func makeManifest() -> PromptNoteManifest {
        let pageID = UUID()
        let revision = UUID()
        return PromptNoteManifest(
            schemaVersion: .current,
            drawingFormatVersion: PromptNoteManifest.drawingFormatVersion,
            coordinateTransformVersion: PromptNoteManifest.coordinateTransformVersion,
            documentID: UUID(),
            title: "Test",
            tagIDs: [],
            createdDate: Date(timeIntervalSince1970: 1_000),
            updatedDate: Date(timeIntervalSince1970: 2_000),
            layoutMode: .freeform,
            pages: [
                PromptNotePage(
                    id: pageID,
                    size: .defaultFreeform,
                    coordinateSpace: .rotatedPagePointsTopLeft,
                    background: .blank,
                    drawingRevision: revision,
                    drawingRelativePath: PromptNoteManifest.drawingRelativePath(
                        pageID: pageID,
                        revision: revision
                    )
                )
            ],
            attachments: []
        )
    }

    private func makePDFAttachment(id: UUID, pageCount: Int) -> PromptNoteAttachment {
        PromptNoteAttachment(
            id: id,
            originalFilename: "source.pdf",
            contentTypeIdentifier: "com.adobe.pdf",
            originalRelativePath: "attachments/\(PromptNoteManifest.pathComponent(for: id))/original.pdf",
            byteCount: 10,
            sha256Hex: String(repeating: "0", count: 64),
            pageCount: pageCount
        )
    }
}

private final class PromptNoteManifestBundleToken {}
