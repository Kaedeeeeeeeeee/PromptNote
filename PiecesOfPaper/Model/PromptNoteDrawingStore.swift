import Foundation
import PencilKit

enum PromptNoteDrawingStore {
    static func loadDrawing(pageID: UUID,
                            from descriptor: PromptNotePackageDescriptor,
                            fileManager: FileManager = .default,
                            limits: PromptNotePackageLimits = .standard) throws -> PKDrawing {
        let drawingURL = try PromptNotePackageReader.drawingURL(
            pageID: pageID,
            in: descriptor,
            fileManager: fileManager,
            limits: limits
        )
        do {
            return try PKDrawing(data: Data(contentsOf: drawingURL, options: .mappedIfSafe))
        } catch {
            throw PromptNotePackageError.drawingUnreadable(pageID)
        }
    }
}
