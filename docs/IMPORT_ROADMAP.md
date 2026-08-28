# PromptNote Common File Import Roadmap

## Status

- Decision: accepted for implementation
- Foundation: Pieces of Paper imported into the PromptNote repository
- Current document format: one property-list encoded `PKDrawing` per `.pop` file
- Target platforms: iPadOS first, with iPhone and macOS behavior defined where practical
- Minimum deployment target: iPadOS 18 for the initial implementation
- Phase 0 identity selected and committed: Team `Y4FV6WUU4V`, app bundle ID `com.promptnote.app`, and iCloud container `iCloud.com.promptnote.app`
- Remaining Phase 0 external gate: register the three explicit App IDs and iCloud container after the team account is added to Xcode, then repeat the signed physical-device build
- Phase 1 package core implemented: versioned manifest, lazy per-page drawings, bounded validation, copy-on-write saves, and shared Quick Look reader

## Goal

PromptNote should accept the document types people commonly bring into a note-taking app without pretending that every format can be edited with perfect fidelity.

The first complete experience is PDF annotation. Image import follows the same page and attachment architecture. Word and other Office formats initially preserve the original file, offer a system preview, and expose extractable text to search and AI. Full Word-compatible layout editing is not part of the first release.

## Capability Matrix

| Format | Import | Native viewing | Handwriting | Text extraction | Export |
| --- | --- | --- | --- | --- | --- |
| PDF | Yes | Vertically scrolling pages | Per-page PencilKit overlay | Embedded PDF text in Phase 3, OCR later | Flattened annotated PDF and untouched original |
| PNG, JPEG, HEIC | Files and Photos | Native image | Page-background annotation first | Vision OCR later | Annotated image or PDF |
| DOCX | Yes | Quick Look initially | After conversion to PDF in a later phase | Native conversion spike, then DOCX XML fallback if needed | Original file initially |
| RTF, RTFD, TXT, Markdown | Yes | Native text surface when available | Separate drawing page or overlay later | Yes | Original and normalized text |
| PPTX, XLSX, Pages, Keynote, Numbers | Attachment import | Quick Look | Not in the first release | Metadata only initially | Original file |

“Import supported” means the original file is copied into PromptNote storage and remains recoverable. It does not imply pixel-perfect editing of the source format.

## Product Principles

1. Preserve the original file. Derived previews, thumbnails, OCR text, and embeddings must be reproducible.
2. Never rasterize an entire PDF at import time. Render visible pages lazily.
3. Store handwriting independently from source content so annotations remain editable.
4. Make offline behavior the default. Any future cloud conversion must be explicit and opt-in.
5. Keep legacy `.pop` notes readable throughout the migration.
6. Autosave only changed metadata or page drawings; do not rewrite a large attachment for every stroke.

## Document Format v2

The current `NoteEntity` contains a single `PKDrawing`, and `NoteDocument` encodes the whole entity as one property list. That model cannot safely hold a large PDF, multiple pages, or reusable attachments.

The proposed v2 format is a document package with a new `.promptnote` extension:

```text
Example.promptnote/
  manifest.plist
  pages/
    <page-id>/
      drawings/
        <drawing-revision-id>.data
      preview.png
  attachments/
    <attachment-id>/
      <original-filename>
  thumbnails/
    document.png
```

The manifest is versioned and contains:

- Stable document, page, and attachment UUIDs
- Document title and tag IDs
- Creation and modification dates
- Schema, drawing-format, and coordinate-transform versions
- Page order, dimensions, and layout mode (`freeform` or `paged`)
- A page background reference: blank, image, or PDF page index, crop box, and rotation
- Drawing revision, preview revision, and attachment relative paths
- Original filename, Uniform Type Identifier, byte count, checksum, and PDF page count
- Optional extracted-text status and provenance

PDF pages should reference one preserved PDF attachment plus a page index. They should not duplicate the original PDF page into every page directory.

Drawing files use `PKDrawing.dataRepresentation()` and are required source data. Saving creates a new drawing revision and atomically switches the manifest reference, making a failed manifest write recoverable without rewriting attachments. Missing previews and thumbnails are regenerated. Extracted text, OCR output, and embeddings live in a per-device rebuildable index keyed by attachment checksum rather than in the synced document package. Readers reject an unsupported future major manifest version, tolerate unknown optional fields from a compatible minor version, open future minor versions read-only, and never silently replace a missing drawing.

### Legacy migration

- Continue discovering and opening `.pop` files.
- Represent a legacy `.pop` as one freeform page in memory.
- Convert only when the user chooses **Upgrade Document** or requests a v2-only operation: adding a page, importing an attachment, or changing from freeform to paged layout.
- Build the new package in an invisible sibling staging directory and promote it atomically.
- Validate it by reopening it through the production loader, checking the supported manifest version, unique IDs, required paths, decoded `PKDrawing`, tags and dates, and attachment sizes/checksums.
- After validation, switch the note list to the new package and move the original `.pop` into an app-managed `LegacyBackups` directory excluded from normal listings. The first release never deletes this backup automatically.
- Key conversion by the legacy document UUID so retries are idempotent. A valid existing destination resumes; an invalid one is quarantined and reported rather than overwritten.
- Add a new PromptNote UTI while retaining the old Pieces of Paper UTI as an import-compatible legacy type.

## Unified Import Pipeline

All entry points should call the same import service:

1. Files picker, Photos picker, Open In, share extension, or drag and drop supplies a URL or transferable item.
2. Acquire and hold security-scoped access for the duration of the copy.
3. Detect the real type, validate the file, and reject unsupported or malformed content with a useful error.
4. Copy the original into an invisible sibling staging package that is not visible to the note list.
5. Extract metadata without loading the entire file into memory.
6. Build page records and lightweight thumbnails.
7. Atomically promote the staged package and update the note list.
8. Schedule optional text extraction, OCR, and search indexing after the document is usable.

Imports must be cancellable and report progress. Interrupted imports must leave no visible half-document. File size and page-count limits should be configurable and verified with real-device tests rather than embedded throughout the UI.

## PDF Architecture

- Use PDFKit for document parsing, page metadata, and lazy rendering.
- Present a continuous vertical page surface with an optional thumbnail navigator rather than the current unbounded blank canvas.
- Keep one `PKDrawing` per PDF page and create live `PKCanvasView` instances only for visible or nearby pages.
- Define one tested coordinate transform between PDF crop-box coordinates, displayed page coordinates, PencilKit coordinates, and export coordinates.
- Cache thumbnails and rendered backgrounds by page and scale; release them under memory pressure.
- Preserve original page boxes, rotation, and aspect ratio.
- Export a new PDF by drawing each original page followed by its transformed PencilKit strokes. Phase 3 exports a flattened visual result only; editable PDF annotations are not promised.

The first PDF release may reject encrypted or damaged PDFs with a clear message. Password entry and preservation of interactive PDF forms are later work.

## Image Architecture

The first image workflow imports one image as a page background that can be annotated. It must:

- Preserve the original image and orientation
- Downsample only the display copy, never the source
- Support PNG, JPEG, and HEIC from Files and Photos
- Produce a page-sized background using fit or fill chosen by the user
- Export the annotated result as an image or PDF

Movable, resizable, rotatable image elements inside a page are a second increment because they require selection, hit testing, z-order, transforms, and undo integration beyond PencilKit.

## Word and Office Strategy

iPadOS does not provide a complete editable Microsoft Word layout engine. PromptNote therefore uses graded support:

1. Preserve every imported Office file as an attachment.
2. Use Quick Look for the first viewing experience.
3. Prototype native attributed-string conversion for DOCX, RTF, and RTFD and measure fidelity.
4. If native DOCX extraction is insufficient, parse the document package for searchable text while retaining the original file.
5. Add optional conversion to PDF only after deciding whether conversion is on-device or an explicit privacy-reviewed server feature.

The initial DOCX milestone is successful import, preview, deterministic text extraction for the supported fixture set, and safe export of the untouched original. The fixture set includes paragraphs, headings, lists, tables, images with captions, Chinese/Japanese text, and a deliberately unsupported complex-layout document. Supported fixtures must match checked-in normalized-text expectations; unsupported layouts must produce a non-destructive warning. It is not Word-compatible editing.

## Delivery Phases and Acceptance Criteria

### Phase 0 — Repository and product foundation

- PromptNote is the only active working repository.
- `origin` points to the PromptNote repository and `upstream` is fetch-only.
- The imported foundation builds, launches, and passes its existing test suite.
- Bundle IDs, signing team, display name, and iCloud container are migrated in isolated commits.

### Phase 1 — Versioned document package

- A new blank `.promptnote` package can be created, saved, closed, reopened, moved, and duplicated.
- A legacy `.pop` note opens without mutation and converts without losing strokes, tags, or dates.
- Conversion is idempotent, hides the migrated legacy file from normal listings, and retains a recoverable backup.
- Quick Look preview and thumbnail extensions understand both formats.
- Autosave updates a page drawing without rewriting attachment bytes.
- Migration and round-trip tests cover missing, malformed, and future-version manifests.

### Phase 2 — Import service

- A shared importer handles security-scoped URLs, staging, cancellation, progress, type validation, and cleanup.
- Files-based import works from the app and Open In.
- Failed or cancelled imports leave no visible note and no orphaned staging directory.
- Duplicate filenames do not overwrite existing documents.

### Phase 3 — PDF vertical slice

- A multi-page PDF imports and becomes usable before all thumbnails finish.
- Users can scroll pages, zoom, write, erase, close, reopen, and retain page-aligned strokes.
- Rotation and mixed page sizes remain aligned.
- Embedded PDF text is indexed when present; OCR is not required in this phase.
- Users can export both the untouched original and one flattened annotated PDF.
- Annotated export preserves page count and page boxes, and stroke alignment is within one PDF user-space point at tested page corners and center.
- On the minimum supported physical iPad, the 100-page/50 MB performance fixture shows its first page within two seconds after the copy finishes, peaks below 500 MB resident memory while scrolling, and returns within 100 MB of its pre-scroll baseline after cache purge.

### Phase 4 — Images

- PNG, JPEG, and HEIC import from Files and Photos.
- Images can become annotated page backgrounds without changing the original attachment.
- Orientation, transparency, wide-gamut color, and large-image downsampling are tested.
- Annotated image and PDF export are available.

### Phase 5 — Text and Office files

- TXT, Markdown, RTF, and RTFD import into a readable text surface.
- DOCX imports, previews through Quick Look, and retains the original for export.
- Supported DOCX fixtures produce the checked-in normalized text; extraction failures for unsupported layouts are shown as non-destructive warnings.
- An integration test indexes extracted DOCX text, finds the document through search, and returns the matched attachment text and source identifier through the AI context provider.
- PPTX, XLSX, and iWork files import as previewable attachments.

### Phase 6 — Additional entry points and hardening

- Share extension and drag-and-drop use the same importer as the Files picker.
- An unmergeable iCloud conflict creates a clearly named conflict copy rather than silently discarding either original attachment or page drawing.
- Offline imports remain usable locally and begin syncing after connectivity returns without creating a duplicate document.
- Low-storage failure leaves the source untouched, promotes no destination package, removes staging data, and displays a recoverable error.
- Background interruption either completes the atomic promotion or resumes/cleans the staging package on next launch; no half-document appears in the note list.
- App upgrades open current and legacy documents, preserve migration backups, and never auto-delete user source files.
- Accessibility labels, keyboard navigation, localization, and VoiceOver cover the import and page workflows.
- On a 7th-generation iPad running iPadOS 18, the PDF surface adds no more than 8 ms to blank-canvas p95 Pencil-to-ink latency under the same 240 fps camera protocol, and absolute p95 remains at or below 50 ms.

Phase 3 is the internal PDF alpha. Phase 6, including iCloud, interruption, accessibility, and real-device gates, is required before a public release containing the import feature.

### Phase 7 — Post-release Office conversion

- Decide through a privacy and fidelity review whether DOCX-to-PDF conversion is on-device or explicitly opt-in and server-backed.
- If approved, converted Office documents reuse the Phase 3 PDF annotation path while always retaining the untouched original.

## Test Strategy

- Unit tests: manifests, migrations, type detection, coordinate transforms, filenames, and cleanup.
- Fixture tests: representative PDFs, rotated pages, mixed dimensions, damaged files, transparent images, HEIC, DOCX, and legacy `.pop` notes.
- Rendering tests: PDF-plus-drawing export compared at stable page coordinates.
- Integration tests: security-scoped copy, autosave, relaunch, Open In, Quick Look, and iCloud Drive moves.
- UI tests: progress, cancellation, errors, page navigation, annotation persistence, and export.
- Performance tests: large PDF first-page latency, thumbnail backpressure, memory during rapid scrolling, and repeated autosave.

Performance is measured on a 7th-generation iPad running the latest iPadOS 18 release; simulator numbers are diagnostic only. The test report records device model, OS version, fixture checksum, cold/warm state, peak resident memory, and first-page latency. After each of three full scroll passes, the test navigates to an empty note, invokes the app's explicit render-cache purge hook, waits five seconds, and samples resident memory; retained memory must not grow monotonically by more than 20 MB across the three samples. Autosave must occur off the input-critical path and must not modify the original attachment bytes.

No imported user content is sent to an external service in Phases 0–6. Any Phase 7 server conversion requires explicit per-document consent, a separate privacy review, encrypted transport, a documented deletion window, and an on-device-only fallback.

## Known Risks

- The existing infinite-canvas assumptions are embedded in view state and storage code; PDF pagination should be introduced as a separate layout mode rather than patched into one large canvas.
- `PKCanvasView` reuse can corrupt page association unless drawings are bound by stable page IDs and saved before reuse.
- PDF coordinate systems use a different origin and may include rotation and crop boxes; export alignment needs dedicated tests.
- iCloud document packages and concurrent edits require coordinated file access and atomic manifest updates.
- Quick Look can preview Office files but does not provide an editable document model.
- Renaming the Swift module and Xcode targets too early will create avoidable upstream merge and test-host churn.

## Open Decisions

1. Whether any server-side Office-to-PDF conversion is acceptable under the product privacy model.
