import PDFKit
import PencilKit
import SwiftUI
import UniformTypeIdentifiers

struct PromptNotePDFView: View {
    let descriptor: PromptNotePackageDescriptor
    @Environment(NoteStore.self) private var noteStore
    @Environment(PreferenceStore.self) private var preferenceStore
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var editor: PromptNotePDFEditor?
    @State private var toolPicker = PKToolPicker()
    @State private var loadFailure: String?
    @State private var isClosing = false

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
                .ignoresSafeArea()
            if let document, let editor {
                PDFKitEditableView(
                    document: document,
                    pages: descriptor.manifest.pages,
                    editor: editor,
                    toolPicker: toolPicker,
                    isAutoSaveEnabled: { [preferenceStore] in
                        preferenceStore.enabledAutoSave
                    }
                )
                .ignoresSafeArea()
            } else if loadFailure == nil {
                ProgressView("Opening PDF…")
            }
        }
        .overlay(alignment: .topLeading) {
            documentBadge
        }
        .overlay(alignment: .topTrailing) {
            doneButton
        }
        .statusBar(hidden: true)
        .toolbar(.hidden, for: .navigationBar)
        .task { loadPDF() }
        .alert("Couldn’t open the PDF", isPresented: loadFailureBinding) {
            Button("Done") { dismiss() }
        } message: {
            Text(loadFailure ?? "The PDF could not be read.")
        }
        .alert("PDF annotation error", isPresented: editorFailureBinding) {
            if editor?.hasPendingChanges == true {
                Button("Retry") {
                    Task { _ = await editor?.flush() }
                }
            }
            Button("OK", role: .cancel) {
                editor?.clearFailure()
            }
        } message: {
            Text(editor?.failureMessage ?? "The annotations could not be loaded or saved.")
        }
    }

    private var loadFailureBinding: Binding<Bool> {
        Binding(
            get: { loadFailure != nil },
            set: { if !$0 { loadFailure = nil } }
        )
    }

    private var editorFailureBinding: Binding<Bool> {
        Binding(
            get: { editor?.failureMessage != nil },
            set: { if !$0 { editor?.clearFailure() } }
        )
    }

    private var documentBadge: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(descriptor.manifest.title.isEmpty ? "Imported PDF" : descriptor.manifest.title)
                .font(.headline)
                .lineLimit(1)
            Text("\(descriptor.manifest.pages.count) pages")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(20)
    }

    private var doneButton: some View {
        Button(action: closePDF) {
            if isClosing {
                ProgressView()
                    .frame(minWidth: 40)
            } else {
                Text("Done")
            }
        }
        .fontWeight(.semibold)
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(20)
        .disabled(isClosing)
        .accessibilityLabel("Close PDF")
    }

    private func loadPDF() {
        do {
            guard let attachment = descriptor.manifest.attachments.first(where: {
                UTType($0.contentTypeIdentifier)?.conforms(to: .pdf) == true
            }) else {
                throw PromptNotePackageError.invalidPDF("The package contains no PDF attachment.")
            }
            let url = try PromptNotePackageReader.attachmentURL(
                attachmentID: attachment.id,
                in: descriptor
            )
            guard let pdfDocument = PDFDocument(url: url) else {
                throw PromptNotePackageError.invalidPDF("The preserved PDF cannot be read.")
            }
            editor = PromptNotePDFEditor(
                descriptor: descriptor,
                repository: noteStore.packageRepository,
                didSave: { [noteStore] savedDescriptor in
                    noteStore.recordSavedPackage(savedDescriptor)
                }
            )
            document = pdfDocument
        } catch {
            loadFailure = error.localizedDescription
        }
    }

    private func closePDF() {
        guard let editor else {
            dismiss()
            return
        }
        isClosing = true
        Task {
            let didSave = await editor.flush()
            isClosing = false
            if didSave {
                dismiss()
            }
        }
    }
}
