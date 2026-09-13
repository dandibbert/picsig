# PicSig Astra — canvas-first repair

Branch: `astra/picsig-ios-privacy-studio`  
Bundle identifier: `com.dandibbert.picsig.astra`  
Minimum platform: iOS 17

Do not push to, merge into, reset, or delete `main` or another agent's branch.

## Status of this source snapshot

This snapshot contains a revision of the native iOS app, not an installable IPA.
The repair is based on remote commit `ce540ec9e513ede2cd3b942bae41cf6eb50e1e60`.
The working-container version has 41 passing portable core tests. Application and
iOS test sources pass Swift syntax parsing. **The repaired iOS app has not yet
been compiled against the iOS SDK or run on a simulator or a physical iPhone.**
Earlier green Actions runs and older IPAs do not validate this repair.

Remote submission was attempted through the GitHub connector. `create_tree`,
`update_file`, and `create_blob` returned `Resource not found`; no remote commit
from this repair has been confirmed. The container's Git client cannot resolve
github.com. These are observed tool failures, not a diagnosis of the user's
permissions. The current source and patch are preserved independently.

## What changed

- Screenshot overlap: texture-anchor voting and dense translation verification,
  rejecting ambiguous/blank matches rather than relying on whitespace averages.
  Original viewport matching is retained as a fallback after fixed-bar removal.
  Fixed bars are cropped on both outer images as well as internal seams.
- On-image text redaction: the user taps the actual image text; tap again to undo
  that redaction. Vision is only a local positioning mechanism. There is no
  separate recognized-text list. Recognized plaintext is transient, not saved.
- Editable annotations: existing text, arrows, pen marks, rectangles and masks
  can be selected on the image, moved and resized. Text content, font size,
  colors and stroke widths remain editable; gestures support undo/redo.
- Layout edits: masks and marks are remapped to their original source content
  instead of all being erased when a seam, source crop or source order changes.
- Addresses: geometry-aware multiline address blocks, label/value adjacency,
  Chinese numeral units and common Chinese/Traditional Chinese/Japanese/Latin
  address components supplement the existing sensitive-information detector.
- Flow: direct import to image editing, no mandatory review/acknowledgement,
  horizontally scrolling fixed-label tools and a native editable text sheet.
  Export selects the destination directly and produces flattened image pixels.

## Verification

```sh
swift test
python3 scripts/generate_project.py
```

The package tests include a generated **real-glyph** grayscale paragraph fixture,
with six exact overlap lengths from 89 to 1027 pixels, as well as sparse text,
short overlap, changing chrome, address-block and edit-remapping regressions.
No font file or personal screenshot is included in that fixture.

The iOS regression suite additionally checks UIKit-rendered paragraphs,
Vision detection of a wrapped address block, rendering/metadata behavior and
actual spatial canvas taps, annotation dragging, re-editing text and direct
export entry. These iOS tests are written but **not yet run for this repair**.
The branch-scoped workflow generates the Xcode project and builds an unsigned IPA
only after the iOS tests pass; signing is not performed by this source snapshot.

## Boundaries

Automatic alignment and sensitive-information detection can still miss content.
The new tests use generated samples, not the user's original failing screenshots.
Dynamic webpage reflow, non-linear scrolling, major scale changes or weakly
textured overlaps still require manual seam adjustment. Addresses without usable
text recognition or sufficient contextual cues may require tapping or drawing
on the image. This revision is not represented as release-ready or fully verified.
