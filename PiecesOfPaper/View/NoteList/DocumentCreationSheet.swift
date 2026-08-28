import SwiftUI
import UniformTypeIdentifiers

struct DocumentCreationSheet: View {
    @Environment(NoteStore.self) private var noteStore
    @Environment(\.dismiss) private var dismiss
    @State private var isFileImporterPresented = false
    @State private var isImporting = false
    @State private var importFailure: ImportFailure?

    private struct ImportFailure: Identifiable {
        let id = UUID()
        let message: String
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                creationButton(
                    title: "Blank note",
                    description: "Start with an empty PencilKit canvas.",
                    systemImage: "square.and.pencil"
                ) {
                    noteStore.openNewNote()
                    dismiss()
                }
                creationButton(
                    title: "Import from Files",
                    description: "Choose a PDF and preserve the original inside PromptNote.",
                    systemImage: "doc.badge.plus"
                ) {
                    isFileImporterPresented = true
                }
                Text("PDF is supported in this first import step. Images and Word documents come next.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                Spacer(minLength: 0)
            }
            .padding(24)
            .disabled(isImporting)
            .overlay {
                if isImporting {
                    ProgressView("Importing PDF…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .navigationTitle("New document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isImporting)
                }
            }
        }
        .presentationDetents([.medium])
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            onCompletion: handleImportResult
        )
        .alert(item: $importFailure) { failure in
            Alert(
                title: Text("Couldn’t import the PDF"),
                message: Text(failure.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func creationButton(title: String,
                                description: String,
                                systemImage: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 52, height: 52)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.separator.opacity(0.45), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let sourceURL = urls.first else { return }
            isImporting = true
            Task {
                do {
                    let descriptor = try await noteStore.importPDF(from: sourceURL)
                    noteStore.openPackage(descriptor)
                    dismiss()
                } catch {
                    importFailure = ImportFailure(message: error.localizedDescription)
                    isImporting = false
                }
            }
        case .failure(let error):
            importFailure = ImportFailure(message: error.localizedDescription)
        }
    }
}
