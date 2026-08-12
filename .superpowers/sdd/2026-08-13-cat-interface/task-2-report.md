# Task 2 Report — Animated Vector Cat

## Outcome

Implemented `CatFaceView(state:mouthPose:reduceMotion:)` as original SwiftUI vector artwork on the full normalized 1672×941 canvas. The raster reference exists only in the Preview Assets catalog, and the verified Release product contains no `CatReference` rendition or filename.

## TDD Evidence

### RED

Added only `CatFaceGeometryTests.swift`, regenerated the Xcode project, and ran:

```text
xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot \
  -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' \
  -only-testing:CatRobotTests/CatFaceGeometryTests \
  -derivedDataPath .build/CatInterfaceDerivedData CODE_SIGNING_ALLOWED=NO
```

The run exited 65 with the expected missing-contract failure: `Cannot find 'CatFaceGeometry' in scope`. The failure occurred before any production geometry existed.

### GREEN

After adding the normalized geometry and view implementation, the final focused run passed 4/4 tests with 0 failures and 0 skips on iPhone 17 Pro, iOS 26.5. The xcresult is:

```text
.build/CatInterfaceDerivedData/Logs/Test/Test-CatRobot-2026.08.13_04-35-20-+0900.xcresult
```

The tests cover normalized bounds, the canonical raster aspect ratio, mirrored pairs, and monotonic speaking-mouth openings.

## Build and Asset Evidence

- Debug simulator build: exit 0.
- Fresh Release simulator build: exit 0 using `.build/CatInterfaceRelease`.
- Fresh Release log: `.build/CatInterfaceRelease.log`, ending in `** BUILD SUCCEEDED **`.
- Release `actool` inputs contained only `CatRobot/Resources/Assets.xcassets`; `Preview Assets.xcassets` was absent.
- Release app filename search for `cat-reference` and `CatReference`: no matches.
- `/usr/bin/assetutil --info CatRobot.app/Assets.car` search for the `CatReference` rendition name: no match.
- Generator inspection: one Preview Assets resource reference; both Debug and Release have `DEVELOPMENT_ASSET_PATHS`; only Release has `EXCLUDED_SOURCE_FILE_NAMES`.
- `ruby scripts/test_generate_project.rb`: `PASS: deterministic CatRobot project contract`.
- Full simulator suite: 30/30 passed, 0 failed, 0 skipped on iPhone 17 Pro, iOS 26.5. Final xcresult: `.build/CatInterfaceDerivedData/Logs/Test/Test-CatRobot-2026.08.13_04-37-07-+0900.xcresult`.

The first fresh Release attempt revealed that an unescaped space made Xcode resolve `EXCLUDED_SOURCE_FILE_NAMES` as two tokens and feed the preview catalog to `actool`. The generator now emits the list item with literal quoting. A second fresh-derived-data build both succeeded and excluded the catalog from the complete build log.

## Design Decisions

- Used one normalized path model for anchors and Bézier controls; the view maps it into any fitted 1.7768-aspect-ratio rectangle.
- Defined canonical left-side ears, eyes, muzzle, markings, fangs, smile, and whiskers once and mirrored them with `x -> 1 - x`. The outer contour generates its right half from the left path.
- Kept the palette to solid charcoal, warm cream, amber, teal, muted salmon, and near-black outlines.
- Listening shifts pupils and inner ears by 0.005 normalized units. Thinking performs a sparse eyelid closure. Speaking changes mouth layers only.
- Reduce Motion disables attention/blink animation and uses a 0.11-second crossfade among fixed mouth-pose layers.
- Increase Contrast strengthens line width, and the entire decorative artwork is hidden from accessibility.
- Kept the trace overlay and its sole Swift source reference to `CatReference` inside a `#if DEBUG` preview.

## Files

- `CatRobot/Conversation/UI/CatFaceShapes.swift`
- `CatRobot/Conversation/UI/CatFaceView.swift`
- `CatRobotTests/Conversation/UI/CatFaceGeometryTests.swift`
- `CatRobot/Preview Content/Preview Assets.xcassets/Contents.json`
- `CatRobot/Preview Content/Preview Assets.xcassets/CatReference.imageset/Contents.json`
- `CatRobot/Preview Content/Preview Assets.xcassets/CatReference.imageset/cat-reference.png`
- `scripts/generate_project.rb`
- Generated `CatRobot.xcodeproj` files

## Residual Risk

Geometry, compilation, animation-state logic, accessibility modifiers, and Release asset absence are automated or build-verified. Pixel-level appearance is intentionally reviewed through the DEBUG trace preview rather than a snapshot dependency; future visual tuning can adjust normalized landmarks without changing the public interface or shipping the raster.
