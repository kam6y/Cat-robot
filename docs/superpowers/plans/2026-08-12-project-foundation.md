# Project Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish a deterministic, minimal `CatRobot.xcodeproj` that builds and runs a SwiftUI iPhone app on iOS 26, exposes a hosted unit-test target through one shared scheme, and gives later feature branches stable source, resource, signing, and generation conventions.

**Architecture:** A checked-in Ruby generator is the source of truth for project topology and build settings; its generated `.xcodeproj` is also committed so Xcode opens without a generation step. The app begins with one deliberately small SwiftUI composition seam (`AppRootView`) and explicit resources, while later branches add focused files below `CatRobot/` and mirrored tests below `CatRobotTests/`; rerunning the generator discovers every Swift file recursively.

**Tech Stack:** Swift 6.0, SwiftUI app lifecycle, XCTest, iOS 26 SDK, Xcode 26.6, Ruby, `xcodeproj` 1.27.0 as a development-time generator only; no third-party app/runtime dependencies.

## Global Constraints

- Work only on the bounded branch `feature/project-foundation` in its project-local ignored worktree.
- Deployment target is iOS 26.0; app target is iPhone only (`TARGETED_DEVICE_FAMILY = 1`).
- Support `UIInterfaceOrientationLandscapeLeft` and `UIInterfaceOrientationLandscapeRight`; do not enable either portrait orientation.
- Project, app target, product, Swift module, and shared scheme are all named `CatRobot`.
- Hosted XCTest target is `CatRobotTests`.
- App bundle identifier is `com.kamby.CatRobot`; test bundle identifier is `com.kamby.CatRobotTests`.
- Automatic signing uses development team `VUB4VP6453`.
- Use Swift language version `6.0` with `SWIFT_STRICT_CONCURRENCY = complete`.
- Keep the SwiftUI lifecycle (`@main struct CatRobotApp: App`) and do not add an app delegate or storyboard.
- Keep app sources below `CatRobot/`, unit tests below `CatRobotTests/`, and resources below `CatRobot/Resources/`.
- The generator must add all `.swift` files below the two source roots in sorted path order, emit deterministic UUIDs, and create one shared `CatRobot` scheme containing build, launch, and test actions.
- Commit the generated `CatRobot.xcodeproj`; never hand-edit `project.pbxproj` or the shared scheme.
- `xcodeproj` 1.27.0 is allowed only as checked generator tooling. Add no Swift packages, CocoaPods, binary frameworks, network clients, analytics, persistence, or other third-party/runtime dependencies.
- This branch provides only the bootable project shell. Do not implement onboarding, conversation domain logic, Apple speech/model services, cat artwork, or final app composition here.
- Primary simulator validation uses iOS 26.5 destination ID `0D540017-B9D7-4E42-B99F-6D0840FD41DA`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `scripts/generate_project.rb` | Recreate the complete project and shared scheme deterministically from fixed settings plus recursively discovered Swift files. |
| `scripts/test_generate_project.rb` | Fast host-side contract test for generator version, targets, settings, dependency, resources, scheme, and absence of Swift packages. |
| `CatRobot.xcodeproj/project.pbxproj` | Generated, checked-in Xcode project; never edited directly. |
| `CatRobot.xcodeproj/xcshareddata/xcschemes/CatRobot.xcscheme` | Generated, checked-in shared scheme; never edited directly. |
| `CatRobot/App/AppIdentity.swift` | Stable app display-name constant used by the shell and a focused unit test. |
| `CatRobot/App/AppRootView.swift` | Minimal SwiftUI composition seam that later app-integration work replaces with real dependencies and screens. |
| `CatRobot/App/CatRobotApp.swift` | SwiftUI process entry point and only `@main` declaration. |
| `CatRobot/Resources/Info.plist` | Explicit app metadata, Japanese microphone/speech disclosures, scene support, and landscape-only orientations. |
| `CatRobot/Resources/Assets.xcassets/Contents.json` | Asset catalog root metadata. |
| `CatRobot/Resources/Assets.xcassets/AccentColor.colorset/Contents.json` | Concrete baseline accent color, avoiding an unresolved named color. |
| `CatRobot/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` | Empty universal app-icon slot that Xcode can build before final artwork is supplied. |
| `CatRobotTests/App/AppIdentityTests.swift` | Hosted XCTest proving module linkage, app identity, privacy copy, and exact landscape metadata. |
| `README.md` | Exact prerequisites, generator workflow, layout contract, and simulator build/test commands. |

---

### Task 1: Deterministic Xcode Project Generator

**Files:**
- Create: `scripts/test_generate_project.rb`
- Create: `scripts/generate_project.rb`
- Generate: `CatRobot.xcodeproj/project.pbxproj`
- Generate: `CatRobot.xcodeproj/xcshareddata/xcschemes/CatRobot.xcscheme`

**Interfaces:**
- Consumes: repository-relative source roots `CatRobot/**/*.swift` and `CatRobotTests/**/*.swift`; resource paths `CatRobot/Resources/Info.plist` and `CatRobot/Resources/Assets.xcassets`; installed Ruby gem `xcodeproj` exactly `1.27.0`.
- Produces: `ruby scripts/generate_project.rb` as the sole project update command; app target/module `CatRobot`; hosted unit target `CatRobotTests`; shared scheme `CatRobot`; recursively discovered Swift build phases; an app-to-test target dependency; fixed signing, deployment, orientation-resource, and Swift concurrency settings.

- [ ] **Step 1: Write the failing generator contract test**

Create `scripts/test_generate_project.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "pathname"
require "rbconfig"
require "rexml/document"
require "rexml/xpath"
require "rubygems"
require "xcodeproj"

ROOT = Pathname.new(__dir__).join("..").expand_path
GENERATOR = ROOT.join("scripts/generate_project.rb")
PROJECT_PATH = ROOT.join("CatRobot.xcodeproj")
PBXPROJ_PATH = PROJECT_PATH.join("project.pbxproj")
SCHEME_PATH = PROJECT_PATH.join("xcshareddata/xcschemes/CatRobot.xcscheme")
REQUIRED_XCODEPROJ_VERSION = Gem::Version.new("1.27.0")

def assert(condition, message)
  abort("FAIL: #{message}") unless condition
end

def run_generator!
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby,
    GENERATOR.to_s,
    chdir: ROOT.to_s
  )
  abort("FAIL: generator exited #{status.exitstatus}\n#{stdout}#{stderr}") unless status.success?
end

assert(
  Gem::Version.new(Xcodeproj::VERSION) == REQUIRED_XCODEPROJ_VERSION,
  "expected xcodeproj 1.27.0, found #{Xcodeproj::VERSION}"
)
assert(GENERATOR.file?, "scripts/generate_project.rb is missing")

run_generator!
assert(PBXPROJ_PATH.file?, "generated project.pbxproj is missing")
assert(SCHEME_PATH.file?, "generated shared scheme is missing")

project = Xcodeproj::Project.open(PROJECT_PATH.to_s)
targets = project.targets.to_h { |target| [target.name, target] }
assert(targets.keys.sort == %w[CatRobot CatRobotTests], "expected exactly CatRobot and CatRobotTests targets")

app = targets.fetch("CatRobot")
tests = targets.fetch("CatRobotTests")
assert(app.product_type == "com.apple.product-type.application", "CatRobot is not an app target")
assert(tests.product_type == "com.apple.product-type.bundle.unit-test", "CatRobotTests is not a unit-test target")
assert(tests.dependencies.any? { |dependency| dependency.target == app }, "CatRobotTests does not depend on CatRobot")
assert(
  app.resources_build_phase.files_references.any? { |reference| reference.path == "Assets.xcassets" },
  "Assets.xcassets is not in the app resources phase"
)

common_settings = {
  "CODE_SIGN_STYLE" => "Automatic",
  "DEVELOPMENT_TEAM" => "VUB4VP6453",
  "IPHONEOS_DEPLOYMENT_TARGET" => "26.0",
  "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator",
  "SUPPORTS_MACCATALYST" => "NO",
  "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD" => "NO",
  "SWIFT_STRICT_CONCURRENCY" => "complete",
  "SWIFT_VERSION" => "6.0",
  "TARGETED_DEVICE_FAMILY" => "1"
}

[app, tests].each do |target|
  target.build_configurations.each do |configuration|
    common_settings.each do |key, expected|
      actual = configuration.build_settings[key]
      assert(actual == expected, "#{target.name} #{configuration.name} #{key}: expected #{expected.inspect}, got #{actual.inspect}")
    end
  end
end

app.build_configurations.each do |configuration|
  settings = configuration.build_settings
  assert(settings["PRODUCT_BUNDLE_IDENTIFIER"] == "com.kamby.CatRobot", "wrong app bundle identifier")
  assert(settings["PRODUCT_MODULE_NAME"] == "CatRobot", "wrong Swift module name")
  assert(settings["GENERATE_INFOPLIST_FILE"] == "NO", "app must use the explicit Info.plist")
  assert(settings["INFOPLIST_FILE"] == "CatRobot/Resources/Info.plist", "wrong Info.plist path")
end

tests.build_configurations.each do |configuration|
  settings = configuration.build_settings
  assert(settings["PRODUCT_BUNDLE_IDENTIFIER"] == "com.kamby.CatRobotTests", "wrong test bundle identifier")
  assert(settings["TEST_HOST"] == "$(BUILT_PRODUCTS_DIR)/CatRobot.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/CatRobot", "wrong test host")
end

package_objects = project.objects.select { |object| object.isa == "XCRemoteSwiftPackageReference" }
assert(package_objects.empty?, "project must not contain Swift package dependencies")

scheme = REXML::Document.new(SCHEME_PATH.read)
testable_names = REXML::XPath.match(scheme, "//TestableReference/BuildableReference").map do |node|
  node.attributes["BlueprintName"]
end
launch_names = REXML::XPath.match(scheme, "//LaunchAction//BuildableReference").map do |node|
  node.attributes["BlueprintName"]
end
assert(testable_names == ["CatRobotTests"], "shared scheme does not test CatRobotTests")
assert(launch_names == ["CatRobot"], "shared scheme does not launch CatRobot")

puts "PASS: deterministic CatRobot project contract"
```

- [ ] **Step 2: Run the contract test and verify the generator is absent**

Run:

```bash
ruby scripts/test_generate_project.rb
```

Expected: nonzero exit with `FAIL: scripts/generate_project.rb is missing`.

- [ ] **Step 3: Implement the minimal deterministic generator**

Create `scripts/generate_project.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "pathname"
require "rubygems"
require "xcodeproj"

REQUIRED_XCODEPROJ_VERSION = Gem::Version.new("1.27.0")
actual_version = Gem::Version.new(Xcodeproj::VERSION)
abort("Expected xcodeproj 1.27.0, found #{Xcodeproj::VERSION}") unless actual_version == REQUIRED_XCODEPROJ_VERSION

ROOT = Pathname.new(__dir__).join("..").expand_path
PROJECT_PATH = ROOT.join("CatRobot.xcodeproj")
APP_NAME = "CatRobot"
TEST_TARGET_NAME = "CatRobotTests"
DEPLOYMENT_TARGET = "26.0"
DEVELOPMENT_TEAM = "VUB4VP6453"

def swift_references(group, directory)
  return [] unless directory.directory?

  Dir[directory.join("**/*.swift").to_s].sort.map do |absolute_path|
    relative_path = Pathname.new(absolute_path).relative_path_from(directory).to_s
    group.new_file(relative_path)
  end
end

def apply_common_settings(target)
  target.build_configurations.each do |configuration|
    configuration.build_settings.merge!(
      "CODE_SIGN_STYLE" => "Automatic",
      "DEVELOPMENT_TEAM" => DEVELOPMENT_TEAM,
      "IPHONEOS_DEPLOYMENT_TARGET" => DEPLOYMENT_TARGET,
      "SDKROOT" => "iphoneos",
      "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator",
      "SUPPORTS_MACCATALYST" => "NO",
      "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD" => "NO",
      "SWIFT_STRICT_CONCURRENCY" => "complete",
      "SWIFT_VERSION" => "6.0",
      "TARGETED_DEVICE_FAMILY" => "1"
    )
  end
end

FileUtils.rm_rf(PROJECT_PATH.to_s)
project = Xcodeproj::Project.new(PROJECT_PATH.to_s, false, 77)
project.root_object.attributes["LastUpgradeCheck"] = "2660"
project.root_object.development_region = "ja"
project.root_object.known_regions = %w[ja en Base]

project.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
    "IPHONEOS_DEPLOYMENT_TARGET" => DEPLOYMENT_TARGET,
    "SWIFT_STRICT_CONCURRENCY" => "complete",
    "SWIFT_VERSION" => "6.0"
  )
end

app_group = project.main_group.new_group("CatRobot", "CatRobot")
test_group = project.main_group.new_group("CatRobotTests", "CatRobotTests")
resources_group = app_group.new_group("Resources", "Resources")
resources_group.new_file("Info.plist")
assets_reference = resources_group.new_file("Assets.xcassets")

app_target = project.new_target(:application, APP_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)
test_target = project.new_target(:unit_test_bundle, TEST_TARGET_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)

app_target.add_file_references(swift_references(app_group, ROOT.join("CatRobot")))
test_target.add_file_references(swift_references(test_group, ROOT.join("CatRobotTests")))
app_target.add_resources([assets_reference])
test_target.add_dependency(app_target)
test_target.add_system_framework("XCTest")

apply_common_settings(app_target)
apply_common_settings(test_target)

app_target.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME" => "AccentColor",
    "CURRENT_PROJECT_VERSION" => "1",
    "ENABLE_PREVIEWS" => "YES",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "INFOPLIST_FILE" => "CatRobot/Resources/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/Frameworks",
    "MARKETING_VERSION" => "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.kamby.CatRobot",
    "PRODUCT_MODULE_NAME" => "CatRobot",
    "PRODUCT_NAME" => "$(TARGET_NAME)"
  )
  configuration.build_settings["ENABLE_TESTABILITY"] = "YES" if configuration.name == "Debug"
end

test_target.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "BUNDLE_LOADER" => "$(TEST_HOST)",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @loader_path/Frameworks @executable_path/Frameworks",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.kamby.CatRobotTests",
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/CatRobot.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/CatRobot"
  )
end

project.sort
project.predictabilize_uuids
project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app_target, test_target, launch_target: true)
scheme.test_action.build_configuration = "Debug"
scheme.launch_action.build_configuration = "Debug"
scheme.profile_action.build_configuration = "Release"
scheme.analyze_action.build_configuration = "Debug"
scheme.archive_action.build_configuration = "Release"
scheme.save_as(PROJECT_PATH.to_s, APP_NAME, true)

puts "Generated #{PROJECT_PATH.relative_path_from(ROOT)} with xcodeproj #{Xcodeproj::VERSION}"
```

- [ ] **Step 4: Generate and verify the complete host-side contract passes**

Run:

```bash
ruby scripts/test_generate_project.rb
```

Expected: exit 0 and `PASS: deterministic CatRobot project contract`. The command also leaves both generated project files on disk.

- [ ] **Step 5: Inspect the shared scheme and exact target list through Xcode tooling**

Run:

```bash
xcodebuild -project CatRobot.xcodeproj -list
```

Expected: targets are exactly `CatRobot` and `CatRobotTests`, and `Schemes` contains `CatRobot`. This command does not need the simulator service.

- [ ] **Step 6: Commit the generator, contract test, and generated project**

```bash
git add scripts/generate_project.rb scripts/test_generate_project.rb CatRobot.xcodeproj/project.pbxproj CatRobot.xcodeproj/xcshareddata/xcschemes/CatRobot.xcscheme
git commit -m "build: add deterministic iOS project generator"
```

---

### Task 2: Bootable Landscape SwiftUI Shell and Hosted Test

**Files:**
- Create: `CatRobot/App/AppIdentity.swift`
- Create: `CatRobot/App/AppRootView.swift`
- Create: `CatRobot/App/CatRobotApp.swift`
- Create: `CatRobot/Resources/Info.plist`
- Create: `CatRobot/Resources/Assets.xcassets/Contents.json`
- Create: `CatRobot/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`
- Create: `CatRobot/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `CatRobotTests/App/AppIdentityTests.swift`
- Regenerate: `CatRobot.xcodeproj/project.pbxproj`
- Regenerate: `CatRobot.xcodeproj/xcshareddata/xcschemes/CatRobot.xcscheme`

**Interfaces:**
- Consumes: generated app module `CatRobot`, hosted target `CatRobotTests`, explicit `Info.plist` path, and recursively discovered Swift source convention from Task 1.
- Produces: `enum AppIdentity { static let displayName: String }`; `struct AppRootView: View` with the synthesized `init()` and `var body: some View`; `@main struct CatRobotApp: App`; exact bundle metadata and landscape orientations available through `Bundle.main` in hosted tests.

- [ ] **Step 1: Add the explicit landscape and privacy metadata**

Create `CatRobot/Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleDisplayName</key>
	<string>Cat Robot</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>LSRequiresIPhoneOS</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Cat Robotは、この会話画面を開いている間、AIの猫と話すためにマイクを使用します。音声は端末上で処理されます。</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Cat Robotは、AIの猫との会話を文字にするため、端末上の音声認識を使用します。</string>
	<key>UIApplicationSceneManifest</key>
	<dict>
		<key>UIApplicationSupportsMultipleScenes</key>
		<false/>
	</dict>
	<key>UIApplicationSupportsIndirectInputEvents</key>
	<true/>
	<key>UILaunchScreen</key>
	<dict/>
	<key>UIRequiresFullScreen</key>
	<true/>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: Add a concrete, buildable asset catalog**

Create `CatRobot/Resources/Assets.xcassets/Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Create `CatRobot/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`:

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0.780",
          "green" : "0.610",
          "red" : "0.330"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Create `CatRobot/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images" : [
    {
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 3: Write the failing hosted unit test and regenerate its build-file entry**

Create `CatRobotTests/App/AppIdentityTests.swift`:

```swift
import Foundation
import XCTest
@testable import CatRobot

final class AppIdentityTests: XCTestCase {
    func testIdentityPrivacyCopyAndLandscapeOnlyMetadata() {
        XCTAssertEqual(AppIdentity.displayName, "Cat Robot")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.kamby.CatRobot")
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
            "Cat Robotは、この会話画面を開いている間、AIの猫と話すためにマイクを使用します。音声は端末上で処理されます。"
        )

        let orientations = Bundle.main.object(
            forInfoDictionaryKey: "UISupportedInterfaceOrientations"
        ) as? [String]

        XCTAssertEqual(
            Set(orientations ?? []),
            Set([
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ])
        )
    }
}
```

Run:

```bash
ruby scripts/generate_project.rb
```

Expected: `Generated CatRobot.xcodeproj with xcodeproj 1.27.0` and the test source appears in the test target's Sources phase.

- [ ] **Step 4: Run the focused test and verify the app implementation is still missing**

Run:

```bash
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -derivedDataPath /tmp/CatRobotDerivedData CODE_SIGNING_ALLOWED=NO -only-testing:CatRobotTests/AppIdentityTests/testIdentityPrivacyCopyAndLandscapeOnlyMetadata test
```

Expected: nonzero exit before the test runs because the app has no Swift entry point/module yet; the diagnostic includes `no such module 'CatRobot'` or a missing `_main` entry point. If the restricted sandbox reports a CoreSimulatorService permission/connection error instead, rerun this exact command with simulator-service permission before evaluating the expected compilation failure.

- [ ] **Step 5: Add the minimal app identity and composition seam**

Create `CatRobot/App/AppIdentity.swift`:

```swift
enum AppIdentity {
    static let displayName = "Cat Robot"
}
```

Create `CatRobot/App/AppRootView.swift`:

```swift
import SwiftUI

struct AppRootView: View {
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            Text(AppIdentity.displayName)
                .font(.largeTitle)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
```

Create `CatRobot/App/CatRobotApp.swift`:

```swift
import SwiftUI

@main
struct CatRobotApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}
```

- [ ] **Step 6: Regenerate and recheck the deterministic project contract**

Run:

```bash
ruby scripts/test_generate_project.rb
```

Expected: exit 0 and `PASS: deterministic CatRobot project contract`; all four new Swift files are now generated into their corresponding Sources phases.

- [ ] **Step 7: Run the focused hosted test and verify it passes**

Run:

```bash
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -derivedDataPath /tmp/CatRobotDerivedData CODE_SIGNING_ALLOWED=NO -only-testing:CatRobotTests/AppIdentityTests/testIdentityPrivacyCopyAndLandscapeOnlyMetadata test
```

Expected: `Test Case '-[CatRobotTests.AppIdentityTests testIdentityPrivacyCopyAndLandscapeOnlyMetadata]' passed` and `** TEST SUCCEEDED **`. If sandboxing blocks CoreSimulatorService, rerun the identical command with simulator-service permission; do not substitute a generic or different-OS destination.

- [ ] **Step 8: Commit the bootable shell, resources, test, and regenerated project**

```bash
git add CatRobot/App CatRobot/Resources CatRobotTests/App CatRobot.xcodeproj/project.pbxproj CatRobot.xcodeproj/xcshareddata/xcschemes/CatRobot.xcscheme
git commit -m "feat: add landscape SwiftUI app shell"
```

---

### Task 3: Contributor Baseline and Full Simulator Verification

**Files:**
- Create: `README.md`
- Verify only: `scripts/generate_project.rb`
- Verify only: `scripts/test_generate_project.rb`
- Verify only: `CatRobot.xcodeproj/project.pbxproj`
- Verify only: `CatRobot.xcodeproj/xcshareddata/xcschemes/CatRobot.xcscheme`

**Interfaces:**
- Consumes: exact generator and scheme commands from Tasks 1–2; simulator destination `0D540017-B9D7-4E42-B99F-6D0840FD41DA`.
- Produces: a zero-context contributor workflow for adding recursively discovered files, checking generated-project drift, building, and running all unit tests; fresh final evidence that the complete foundation is green.

- [ ] **Step 1: Write the contributor baseline**

Create `README.md`:

```markdown
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
```

- [ ] **Step 2: Prove regeneration leaves no project drift**

Run:

```bash
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
git diff --exit-code -- CatRobot.xcodeproj
```

Expected: the contract prints `PASS: deterministic CatRobot project contract`; `git diff --exit-code` returns 0 with no output.

- [ ] **Step 3: Verify exact resolved build settings**

Run:

```bash
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -target CatRobot -configuration Debug -showBuildSettings | rg 'CODE_SIGN_STYLE|DEVELOPMENT_TEAM|IPHONEOS_DEPLOYMENT_TARGET|PRODUCT_BUNDLE_IDENTIFIER|SUPPORTED_PLATFORMS|SWIFT_STRICT_CONCURRENCY|SWIFT_VERSION|TARGETED_DEVICE_FAMILY'
```

Expected output contains all of:

```text
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = VUB4VP6453
IPHONEOS_DEPLOYMENT_TARGET = 26.0
PRODUCT_BUNDLE_IDENTIFIER = com.kamby.CatRobot
SUPPORTED_PLATFORMS = iphoneos iphonesimulator
SWIFT_STRICT_CONCURRENCY = complete
SWIFT_VERSION = 6.0
TARGETED_DEVICE_FAMILY = 1
```

- [ ] **Step 4: Perform a fresh full simulator build**

Run:

```bash
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -derivedDataPath /tmp/CatRobotDerivedData CODE_SIGNING_ALLOWED=NO clean build
```

Expected: destination resolves to the iOS 26.5 simulator and the log ends with `** BUILD SUCCEEDED **`. If CoreSimulatorService is inaccessible in the restricted sandbox, rerun the same command with simulator-service permission.

- [ ] **Step 5: Run the entire shared-scheme unit-test suite from the fresh build**

Run:

```bash
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -derivedDataPath /tmp/CatRobotDerivedData CODE_SIGNING_ALLOWED=NO test
```

Expected: exactly one test executes, it passes, and the log ends with `** TEST SUCCEEDED **`.

- [ ] **Step 6: Confirm scope and commit the README**

Run:

```bash
git status --short
```

Expected: before staging, only `README.md` is untracked or modified; the project has no regeneration drift and no unrelated files changed.

```bash
git add README.md
git commit -m "docs: document project foundation workflow"
```

---

## Final Review and Integration

- [ ] Review `git log --oneline main..feature/project-foundation`; expect three focused commits in generator, shell, and documentation order.
- [ ] Review `git diff --stat main...feature/project-foundation`; scope must contain only the files listed in this plan and generated Xcode project contents.
- [ ] From a clean `feature/project-foundation` worktree, rerun `ruby scripts/test_generate_project.rb`, the Task 3 full build, and the Task 3 full test; require all three fresh results to pass.
- [ ] Have the branch reviewed before integration. Do not add domain, service, cat UI, or app-integration fixes to this branch.
- [ ] Integrate from the main worktree with a squash commit:

```bash
git switch main
git status --short
git merge --squash feature/project-foundation
git commit -m "feat: establish Cat Robot project foundation"
```

Expected: `main` receives one integration commit containing the reviewed foundation.

- [ ] Keep `feature/project-foundation` after the squash merge. Push it if the repository uses a remote, and do **not** run `git branch -d`, `git branch -D`, or any remote branch deletion command. The local project worktree may be removed separately only after confirming the branch is retained.
