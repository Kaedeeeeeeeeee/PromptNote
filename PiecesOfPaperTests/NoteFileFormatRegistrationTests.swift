import Foundation
import Testing
@testable import Pieces_of_Paper

struct NoteFileFormatRegistrationTests {
    @Test func appBundleRegistersPromptNoteAsDocumentPackage() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let declarations = try #require(
            info["UTExportedTypeDeclarations"] as? [[String: Any]]
        )
        let declaration = try #require(declarations.first {
            $0["UTTypeIdentifier"] as? String == NoteFileFormat.packageTypeIdentifier
        })
        let conformances = try #require(declaration["UTTypeConformsTo"] as? [String])
        let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
        let extensions = try #require(tags["public.filename-extension"] as? [String])
        let documentTypes = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let registeredContentTypes = documentTypes.flatMap { documentType in
            documentType["LSItemContentTypes"] as? [String] ?? []
        }

        #expect(conformances.contains("com.apple.package"))
        #expect(extensions == [NoteFileFormat.package.rawValue])
        #expect(registeredContentTypes.contains(NoteFileFormat.packageTypeIdentifier))
        #expect(registeredContentTypes.contains(NoteFileFormat.legacyTypeIdentifier))
    }
}
