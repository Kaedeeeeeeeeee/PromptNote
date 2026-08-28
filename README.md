# PromptNote

PromptNote is an iPad-first, Apple-native note-taking app under active development. The project is focused on fluid Apple Pencil handwriting, common document import and annotation, and AI-assisted note workflows.

## Current foundation

PromptNote is based on [Pieces of Paper](https://github.com/0si43/PiecesOfPaper), created by Nakajima Tsuyoshi (`@0si43`). The imported foundation provides:

- A native SwiftUI/UIKit application
- A PencilKit handwriting canvas
- Local and iCloud Drive document storage
- Tags, thumbnails, Quick Look previews, and autosave
- An infinite-canvas writing mode

The complete upstream Git history is preserved. The original repository is tracked locally as the `upstream` remote so fixes can be reviewed and incorporated over time.

## Development direction

The first major PromptNote work will add:

- PDF import, page rendering, PencilKit annotation, and annotated export
- Image import and canvas placement
- Word and common document preview plus text extraction
- A versioned document package for pages and attachments
- AI-assisted search, understanding, and editing workflows

## License and attribution

The Pieces of Paper foundation is available under the MIT License. Its original copyright and license notice are preserved in [LICENSE.md](LICENSE.md).
