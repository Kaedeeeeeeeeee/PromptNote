import Foundation

enum NoteFileFormat: String, Codable, CaseIterable {
    case legacyPropertyList = "plist"
    case legacyPop = "pop"
    case package = "promptnote"

    static let legacyTypeIdentifier = "Individual.LikeAPaper.note"
    static let packageTypeIdentifier = "com.promptnote.note"

    static func detect(from url: URL) -> NoteFileFormat? {
        NoteFileFormat(rawValue: url.pathExtension.lowercased())
    }
}
