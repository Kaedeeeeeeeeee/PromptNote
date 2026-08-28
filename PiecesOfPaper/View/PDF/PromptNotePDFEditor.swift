import Foundation
import PencilKit

@Observable
@MainActor
final class PromptNotePDFEditor {
    private(set) var descriptor: PromptNotePackageDescriptor
    private(set) var isSaving = false
    private(set) var failureMessage: String?
    var hasPendingChanges: Bool { !pendingDrawings.isEmpty || isSaving }

    @ObservationIgnored private let repository: PromptNotePackageRepository
    @ObservationIgnored private let didSave: (PromptNotePackageDescriptor) -> Void
    @ObservationIgnored private var workingDrawings = [UUID: PKDrawing]()
    @ObservationIgnored private var savedDrawings = [UUID: PKDrawing]()
    @ObservationIgnored private var pendingDrawings = [UUID: PKDrawing]()
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(descriptor: PromptNotePackageDescriptor,
         repository: PromptNotePackageRepository,
         didSave: @escaping (PromptNotePackageDescriptor) -> Void = { _ in }) {
        self.descriptor = descriptor
        self.repository = repository
        self.didSave = didSave
    }

    func drawing(for pageID: UUID) async throws -> PKDrawing {
        if let drawing = workingDrawings[pageID] {
            return drawing
        }
        let drawing = try await repository.loadDrawing(
            pageID: pageID,
            from: descriptor.fileURL
        )
        workingDrawings[pageID] = drawing
        savedDrawings[pageID] = drawing
        return drawing
    }

    func record(_ drawing: PKDrawing, for pageID: UUID, autoSave: Bool) {
        guard workingDrawings[pageID] != drawing else { return }
        workingDrawings[pageID] = drawing
        if savedDrawings[pageID] == drawing {
            pendingDrawings[pageID] = nil
        } else {
            pendingDrawings[pageID] = drawing
        }
        guard autoSave else { return }
        scheduleSave()
    }

    func report(_ error: Error) {
        failureMessage = error.localizedDescription
    }

    func clearFailure() {
        failureMessage = nil
    }

    func flush() async -> Bool {
        debounceTask?.cancel()
        debounceTask = nil
        failureMessage = nil

        while !pendingDrawings.isEmpty || saveTask != nil {
            beginSaveLoopIfNeeded()
            guard let currentSaveTask = saveTask else { break }
            await currentSaveTask.value
            guard failureMessage == nil else { return false }
        }
        return pendingDrawings.isEmpty && !isSaving
    }

    private func scheduleSave() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.beginSaveLoopIfNeeded()
        }
    }

    private func beginSaveLoopIfNeeded() {
        guard saveTask == nil, !pendingDrawings.isEmpty else { return }
        failureMessage = nil
        isSaving = true
        saveTask = Task { [weak self] in
            await self?.drainPendingDrawings()
        }
    }

    private func drainPendingDrawings() async {
        while !Task.isCancelled, let next = pendingDrawings.first {
            let pageID = next.key
            let drawing = next.value
            pendingDrawings[pageID] = nil
            do {
                descriptor = try await repository.saveDrawing(
                    drawing,
                    pageID: pageID,
                    in: descriptor.fileURL
                )
                savedDrawings[pageID] = drawing
                didSave(descriptor)
            } catch {
                pendingDrawings[pageID] = drawing
                failureMessage = error.localizedDescription
                break
            }
        }
        isSaving = false
        saveTask = nil
    }
}
