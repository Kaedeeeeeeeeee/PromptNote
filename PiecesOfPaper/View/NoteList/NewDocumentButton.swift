import SwiftUI

struct NewDocumentButton: View {
    enum Style {
        case emptyState
        case gridTile
    }

    let style: Style
    @Environment(NoteListPresentation.self) private var presentation

    var body: some View {
        Button {
            presentation.requestDocumentCreation()
        } label: {
            VStack(spacing: style == .emptyState ? 18 : 12) {
                Image(systemName: "plus")
                    .font(.system(size: style == .emptyState ? 34 : 26, weight: .medium))
                    .frame(
                        width: style == .emptyState ? 78 : 60,
                        height: style == .emptyState ? 78 : 60
                    )
                    .background(.tint.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(.tint.opacity(0.22), lineWidth: 1))
                VStack(spacing: 5) {
                    Text("New document")
                        .font(style == .emptyState ? .title3.weight(.semibold) : .headline)
                    Text("Create a blank note or import a PDF")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(
                width: style == .emptyState ? nil : 250,
                height: style == .emptyState ? nil : 190
            )
            .padding(style == .emptyState ? 28 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if style == .gridTile {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.secondary.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                .secondary.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])
                            )
                    }
            }
        }
        .accessibilityLabel("New document")
        .accessibilityHint("Create a blank note or import a PDF from Files")
    }
}
