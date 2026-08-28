import CryptoKit
import Foundation
import Testing
@testable import Pieces_of_Paper

enum PromptNotePackageTestSupport {
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptNotePackageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func addFutureMinorAndUnknownField(to manifestURL: URL) throws {
        let data = try Data(contentsOf: manifestURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        var propertyList = try #require(
            PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any]
        )
        var schema = try #require(propertyList["schemaVersion"] as? [String: Any])
        schema["minor"] = 42
        propertyList["schemaVersion"] = schema
        propertyList["futureOptionalField"] = ["enabled": true]
        try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        ).write(to: manifestURL, options: .atomic)
    }

    static func makePackageWithAttachment(name: String) async throws -> PromptNoteAttachmentFixture {
        let directory = try makeTemporaryDirectory()
        let packageURL = directory.appendingPathComponent("\(name).promptnote")
        let repository = PromptNotePackageRepository()
        var descriptor = try await repository.createBlank(at: packageURL)
        let attachmentID = UUID()
        let attachmentData = Data(repeating: 0x5a, count: 8_192)
        let relativePath = attachmentPath(id: attachmentID, filename: "original.bin")
        let attachmentURL = try PromptNotePackageReader.containedURL(for: relativePath, in: packageURL)
        try FileManager.default.createDirectory(
            at: attachmentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try attachmentData.write(to: attachmentURL)
        descriptor.manifest.attachments.append(
            makeAttachment(
                id: attachmentID,
                filename: "original.bin",
                contentType: "public.data",
                relativePath: relativePath,
                data: attachmentData
            )
        )
        try write(descriptor.manifest, to: packageURL)
        return PromptNoteAttachmentFixture(
            directory: directory,
            packageURL: packageURL,
            repository: repository,
            attachmentURL: attachmentURL,
            relativePath: relativePath,
            attachmentData: attachmentData
        )
    }

    static func makeAttachment(id: UUID,
                               filename: String,
                               contentType: String,
                               relativePath: String,
                               data: Data) -> PromptNoteAttachment {
        PromptNoteAttachment(
            id: id,
            originalFilename: filename,
            contentTypeIdentifier: contentType,
            originalRelativePath: relativePath,
            byteCount: Int64(data.count),
            sha256Hex: sha256Hex(data),
            pageCount: nil
        )
    }

    static func attachmentPath(id: UUID, filename: String) -> String {
        "attachments/\(PromptNoteManifest.pathComponent(for: id))/\(filename)"
    }

    static func write(_ manifest: PromptNoteManifest, to packageURL: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(manifest).write(
            to: packageURL.appendingPathComponent(PromptNotePackageReader.manifestFileName),
            options: .atomic
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct PromptNoteAttachmentFixture {
    let directory: URL
    let packageURL: URL
    let repository: PromptNotePackageRepository
    let attachmentURL: URL
    let relativePath: String
    let attachmentData: Data
}
