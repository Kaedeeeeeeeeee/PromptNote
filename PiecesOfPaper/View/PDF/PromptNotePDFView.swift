import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PromptNotePDFView: View {
    let descriptor: PromptNotePackageDescriptor
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var loadFailure: String?

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
                .ignoresSafeArea()
            if let document {
                PDFKitView(document: document)
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
    }

    private var loadFailureBinding: Binding<Bool> {
        Binding(
            get: { loadFailure != nil },
            set: { if !$0 { loadFailure = nil } }
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
        Button("Done") { dismiss() }
            .fontWeight(.semibold)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(20)
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
            document = pdfDocument
        } catch {
            loadFailure = error.localizedDescription
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.autoScales = true
        pdfView.document = document
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        guard pdfView.document !== document else { return }
        pdfView.document = document
        pdfView.autoScales = true
    }
}
