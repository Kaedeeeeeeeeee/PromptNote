import PDFKit
import PencilKit
import SwiftUI

struct PDFKitEditableView: UIViewRepresentable {
    let document: PDFDocument
    let pages: [PromptNotePage]
    let editor: PromptNotePDFEditor
    let toolPicker: PKToolPicker
    let isAutoSaveEnabled: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            document: document,
            pages: pages,
            editor: editor,
            toolPicker: toolPicker,
            isAutoSaveEnabled: isAutoSaveEnabled
        )
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.pageOverlayViewProvider = context.coordinator
        pdfView.isInMarkupMode = true
        pdfView.document = document
        pdfView.autoScales = true
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        pdfView.isInMarkupMode = true
        guard pdfView.document !== document else { return }
        pdfView.document = document
        pdfView.autoScales = true
    }

    static func dismantleUIView(_ pdfView: PDFView, coordinator: Coordinator) {
        pdfView.pageOverlayViewProvider = nil
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate {
        private let document: PDFDocument
        private let pages: [PromptNotePage]
        private let editor: PromptNotePDFEditor
        private let toolPicker: PKToolPicker
        private let isAutoSaveEnabled: () -> Bool
        private var canvasByPage = [PDFPage: PKCanvasView]()
        private var pageIDByCanvas = [ObjectIdentifier: UUID]()
        private var loadTaskByPageID = [UUID: Task<Void, Never>]()
        private var loadedPageIDs = Set<UUID>()
        private var pagesReceivingProgrammaticDrawing = Set<UUID>()
        private weak var activeCanvas: PKCanvasView?

        init(document: PDFDocument,
             pages: [PromptNotePage],
             editor: PromptNotePDFEditor,
             toolPicker: PKToolPicker,
             isAutoSaveEnabled: @escaping () -> Bool) {
            self.document = document
            self.pages = pages
            self.editor = editor
            self.toolPicker = toolPicker
            self.isAutoSaveEnabled = isAutoSaveEnabled
            super.init()
            if let pen = toolPicker.toolItems.first(where: {
                ($0 as? PKToolPickerInkingItem)?.inkingTool.inkType == .pen
            }) {
                toolPicker.selectedToolItem = pen
            }
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            if let canvas = canvasByPage[page] {
                return canvas
            }
            guard let pageID = pageID(for: page) else { return nil }
            let canvas = makeCanvas(pageID: pageID)
            canvasByPage[page] = canvas
            pageIDByCanvas[ObjectIdentifier(canvas)] = pageID
            return canvas
        }

        func pdfView(_ pdfView: PDFView,
                     willDisplayOverlayView overlayView: UIView,
                     for page: PDFPage) {
            guard let canvas = overlayView as? PKCanvasView,
                  let pageID = pageID(for: page) else { return }
            loadDrawingIfNeeded(pageID: pageID, into: canvas)
        }

        func pdfView(_ pdfView: PDFView,
                     willEndDisplayingOverlayView overlayView: UIView,
                     for page: PDFPage) {
            guard let canvas = overlayView as? PKCanvasView,
                  let pageID = pageID(for: page) else { return }
            loadTaskByPageID[pageID]?.cancel()
            loadTaskByPageID[pageID] = nil
            if loadedPageIDs.contains(pageID) {
                editor.record(
                    canvas.drawing,
                    for: pageID,
                    autoSave: isAutoSaveEnabled()
                )
            }
            loadedPageIDs.remove(pageID)
            pagesReceivingProgrammaticDrawing.remove(pageID)
            pageIDByCanvas[ObjectIdentifier(canvas)] = nil
            canvas.delegate = nil
            toolPicker.removeObserver(canvas)
            canvasByPage[page] = nil
            if activeCanvas === canvas {
                activeCanvas = nil
                activateFirstVisibleCanvas()
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let pageID = pageIDByCanvas[ObjectIdentifier(canvasView)],
                  loadedPageIDs.contains(pageID),
                  !pagesReceivingProgrammaticDrawing.contains(pageID) else { return }
            editor.record(
                canvasView.drawing,
                for: pageID,
                autoSave: isAutoSaveEnabled()
            )
        }

        func tearDown() {
            loadTaskByPageID.values.forEach { $0.cancel() }
            loadTaskByPageID.removeAll()
            for canvas in canvasByPage.values {
                canvas.delegate = nil
                toolPicker.removeObserver(canvas)
            }
            if let activeCanvas {
                toolPicker.setVisible(false, forFirstResponder: activeCanvas)
                activeCanvas.resignFirstResponder()
            }
            canvasByPage.removeAll()
            pageIDByCanvas.removeAll()
        }

        private func makeCanvas(pageID: UUID) -> PKCanvasView {
            let canvas = PKCanvasView(frame: .zero)
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isScrollEnabled = false
            canvas.minimumZoomScale = 1
            canvas.maximumZoomScale = 1
            #if targetEnvironment(simulator)
            canvas.drawingPolicy = .anyInput
            #else
            canvas.drawingPolicy = .default
            #endif
            canvas.isUserInteractionEnabled = false
            canvas.isAccessibilityElement = true
            canvas.accessibilityLabel = "PDF annotation canvas"
            canvas.accessibilityIdentifier = "pdf-annotation-canvas-\(pageID.uuidString)"
            canvas.delegate = self
            toolPicker.addObserver(canvas)
            let tap = UITapGestureRecognizer(target: self, action: #selector(activateTappedCanvas(_:)))
            tap.cancelsTouchesInView = false
            canvas.addGestureRecognizer(tap)
            return canvas
        }

        private func loadDrawingIfNeeded(pageID: UUID, into canvas: PKCanvasView) {
            guard !loadedPageIDs.contains(pageID), loadTaskByPageID[pageID] == nil else {
                if loadedPageIDs.contains(pageID) {
                    activate(canvas)
                }
                return
            }
            loadTaskByPageID[pageID] = Task { [weak self, weak canvas] in
                guard let self else { return }
                do {
                    let drawing = try await editor.drawing(for: pageID)
                    guard !Task.isCancelled,
                          let canvas,
                          pageIDByCanvas[ObjectIdentifier(canvas)] == pageID else { return }
                    pagesReceivingProgrammaticDrawing.insert(pageID)
                    canvas.drawing = drawing
                    pagesReceivingProgrammaticDrawing.remove(pageID)
                    loadedPageIDs.insert(pageID)
                    canvas.isUserInteractionEnabled = true
                    activate(canvas)
                } catch is CancellationError {
                    return
                } catch {
                    editor.report(error)
                }
                loadTaskByPageID[pageID] = nil
            }
        }

        private func pageID(for pdfPage: PDFPage) -> UUID? {
            let index = document.index(for: pdfPage)
            guard pages.indices.contains(index) else { return nil }
            return pages[index].id
        }

        @objc private func activateTappedCanvas(_ recognizer: UITapGestureRecognizer) {
            guard let canvas = recognizer.view as? PKCanvasView,
                  canvas.isUserInteractionEnabled else { return }
            activate(canvas)
        }

        private func activate(_ canvas: PKCanvasView) {
            activeCanvas = canvas
            toolPicker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        }

        private func activateFirstVisibleCanvas() {
            guard let canvas = canvasByPage.values.first(where: \.isUserInteractionEnabled) else { return }
            activate(canvas)
        }
    }
}
