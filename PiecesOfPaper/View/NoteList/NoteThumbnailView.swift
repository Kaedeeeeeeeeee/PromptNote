import SwiftUI
import PDFKit
import PencilKit
import UniformTypeIdentifiers

struct NoteThumbnailView: View {
    let entry: NoteIndexEntry
    let tags: [TagEntity]
    @Environment(NoteStore.self) private var noteStore
    @Environment(NoteListPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    @State private var thumbnail: UIImage?
    @State private var isOpening = false
    @State private var packageTitle: String?
    @State private var packagePageCount: Int?

    // colorScheme is the effective one, i.e. after the appearance preference's
    // override, so the thumbnail matches the tile it sits on
    private var interfaceStyle: UIUserInterfaceStyle {
        colorScheme == .dark ? .dark : .light
    }

    private var thumbnailKey: String {
        ThumbnailCache.key(for: entry, style: interfaceStyle)
    }

    var body: some View {
        Button(action: openDocument, label: {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    Color.clear
                }
            }
            .frame(width: 250, height: 190)
            .background(Color(UIColor.secondarySystemBackground))
            .shadow(radius: 5)
            .overlay(alignment: .bottomLeading) {
                if NoteFileFormat.detect(from: entry.fileURL) == .package {
                    Label(packageTitle ?? "PDF", systemImage: "doc.richtext")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
            }
            .overlay {
                if isOpening {
                    ProgressView()
                }
            }
        })
        .accessibilityLabel(accessibilityLabel)
        .task(id: thumbnailKey) {
            let key = thumbnailKey
            if NoteFileFormat.detect(from: entry.fileURL) == .package {
                await loadPackageThumbnail(key: key)
                return
            }
            if let cached = ThumbnailCache.shared.cached(key: key),
               noteStore.validMetadata(for: entry) != nil {
                thumbnail = cached
                return
            }
            // Open the one document, render, and let the drawing go out of
            // scope; a failed open leaves the placeholder and the next
            // appearance retries.
            guard let note = await noteStore.loadNote(entry) else { return }
            guard !Task.isCancelled else { return }
            thumbnail = await ThumbnailCache.shared.thumbnail(for: note.entity.drawing,
                                                              key: key,
                                                              style: interfaceStyle)
        }
    }

    private func loadPackageThumbnail(key: String) async {
        switch await noteStore.loadPackageResult(entry) {
        case .success(let descriptor):
            packageTitle = descriptor.manifest.title
            packagePageCount = descriptor.manifest.pages.count
            if let cached = ThumbnailCache.shared.cached(key: key) {
                thumbnail = cached
                return
            }
            guard !Task.isCancelled,
                  let attachment = descriptor.manifest.attachments.first(where: {
                      UTType($0.contentTypeIdentifier)?.conforms(to: .pdf) == true
                  }),
                  let attachmentURL = try? PromptNotePackageReader.attachmentURL(
                      attachmentID: attachment.id,
                      in: descriptor
                  ),
                  let page = PDFDocument(url: attachmentURL)?.page(at: 0) else { return }
            let image = page.thumbnail(of: CGSize(width: 500, height: 380), for: .cropBox)
            thumbnail = image
            ThumbnailCache.shared.insert(image, key: key)
        case .failure:
            return
        }
    }

    private var accessibilityLabel: String {
        if NoteFileFormat.detect(from: entry.fileURL) == .package,
           let packageTitle,
           let packagePageCount {
            return "PDF, \(packageTitle), \(packagePageCount) pages"
        }
        return Self.accessibilityLabel(
            updatedDate: entry.updatedDate,
            tagNames: tags.map(\.name)
        )
    }

    // Notes have no title, so the update date (and tag names, once the
    // metadata cache knows them) is what distinguishes them under VoiceOver
    static func accessibilityLabel(updatedDate: Date, tagNames: [String],
                                   locale: Locale = .current) -> String {
        let date = updatedDate.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        )
        guard !tagNames.isEmpty else { return "Note, \(date)" }
        return "Note, \(date), tags: \(tagNames.joined(separator: ", "))"
    }

    // Open-then-present: CanvasView reads the drawing synchronously in
    // onAppear, so the document must be loaded before the cover shows
    private func openDocument() {
        guard !isOpening else { return }
        isOpening = true
        Task {
            if NoteFileFormat.detect(from: entry.fileURL) == .package {
                let result = await noteStore.loadPackageResult(entry)
                isOpening = false
                switch result {
                case .success(let descriptor):
                    noteStore.openPackage(descriptor)
                case .failure(let error):
                    presentation.alert = .error(error)
                }
                return
            }
            let result = await noteStore.loadNoteResult(entry)
            isOpening = false
            switch result {
            case .success(let note):
                noteStore.openedNote = note
            case .failure(let error):
                presentation.presentOpenFailure(error)
            }
        }
    }
}

#Preview {
    NoteThumbnailView(entry: NoteIndexEntry(fileURL: URL(fileURLWithPath: "/preview/2026-01-01-00-00-000000.pop"),
                                            creationDate: nil,
                                            contentModificationDate: nil),
                      tags: [])
        .environment(NoteStore())
        .environment(NoteListPresentation())
}
