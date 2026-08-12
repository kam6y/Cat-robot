# Cat Robot

Cat Robot is a native SwiftUI iPhone app for a foreground, on-device conversation with an AI cat. This repository currently establishes the deterministic iOS project foundation; conversation behavior and the final cat interface arrive on separate feature branches.

## Requirements

- Xcode 26.6 (build 17F113)
- iOS 26.0 SDK or later
- Ruby with `xcodeproj` exactly 1.27.0 (`ruby -e 'require "xcodeproj"; puts Xcodeproj::VERSION'`)
- Primary simulator: iOS 26.5, ID `0D540017-B9D7-4E42-B99F-6D0840FD41DA`

The app itself has no third-party or network dependencies. The `xcodeproj` gem is a development-time generator only and is not linked into the app.

## Project generation

Never edit `CatRobot.xcodeproj/project.pbxproj` or `CatRobot.xcodeproj/xcshareddata/xcschemes/CatRobot.xcscheme` by hand. Add app Swift files anywhere below `CatRobot/`, add unit tests anywhere below `CatRobotTests/`, then regenerate:

```bash
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
git diff -- CatRobot.xcodeproj
```

Commit source changes and the regenerated project together. A second generation must produce no project diff.

## Build and test

```bash
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -derivedDataPath /tmp/CatRobotDerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -derivedDataPath /tmp/CatRobotDerivedData CODE_SIGNING_ALLOWED=NO test
```

The shared `CatRobot` scheme builds and launches the `CatRobot` app and runs the hosted `CatRobotTests` target. Simulator signing is disabled only on the command line; project signing remains Automatic with team `VUB4VP6453` for physical-device work.

## Layout

- `CatRobot/App/`: SwiftUI entry point and composition root
- `CatRobot/Resources/`: explicit Info.plist and asset catalogs
- `CatRobot/`: all later production Swift features, grouped by responsibility
- `CatRobotTests/`: unit tests mirroring production feature paths
- `scripts/`: deterministic project generation and its host-side contract test
- `docs/superpowers/specs/`: approved product and engineering design

The deployment target is iOS 26.0. The MVP is iPhone-only, supports both landscape directions, uses Swift 6 strict concurrency, and keeps conversation data on device.
