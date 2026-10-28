#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
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
DEPLOYMENT_TARGET = "27.0"
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
      "SWIFT_INCLUDE_PATHS" => ["$(inherited)", "$(SRCROOT)/native/japanese-pronunciation/include"],
      "TARGETED_DEVICE_FAMILY" => "1"
    )
  end
end

# Preserve the resolved dependency lock across deterministic project regeneration.
lock_path = PROJECT_PATH.join("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
resolved_lock = lock_path.binread if lock_path.file?
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
preview_group = app_group.new_group("Preview Content", "Preview Content")
preview_assets_reference = preview_group.new_file("Preview Assets.xcassets")

app_target = project.new_target(:application, APP_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)
test_target = project.new_target(:unit_test_bundle, TEST_TARGET_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)

app_target.add_file_references(swift_references(app_group, ROOT.join("CatRobot")))
test_target.add_file_references(swift_references(test_group, ROOT.join("CatRobotTests")))
app_target.add_resources([assets_reference, preview_assets_reference])
test_target.add_dependency(app_target)
test_target.add_system_framework("XCTest")

ort_package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
ort_package.repositoryURL = "https://github.com/microsoft/onnxruntime-swift-package-manager"
ort_package.requirement = { "kind" => "exactVersion", "version" => "1.24.2" }
project.root_object.package_references << ort_package
[app_target].each do |target|
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = ort_package
  product.product_name = "onnxruntime"
  target.package_product_dependencies << product
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  target.frameworks_build_phase.files << build_file
end

claude_package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
claude_package.repositoryURL = "https://github.com/anthropics/ClaudeForFoundationModels.git"
claude_package.requirement = { "kind" => "exactVersion", "version" => "0.2.3" }
project.root_object.package_references << claude_package
[app_target, test_target].each do |target|
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = claude_package
  product.product_name = "ClaudeForFoundationModels"
  target.package_product_dependencies << product
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  target.frameworks_build_phase.files << build_file
end

# 開発用キーは Debug に同梱し、Release では下記の設定で除外する。
dev_key_path = ROOT.join("CatRobot/LocalAssets/claude-api-key.txt")
FileUtils.mkdir_p(dev_key_path.dirname)
FileUtils.touch(dev_key_path) unless dev_key_path.file?
app_target.add_resources([app_group.new_file("LocalAssets/claude-api-key.txt")])
claude_client_id = JSON.parse(ROOT.join("CatRobot/Resources/claude-integration.json").read).fetch("clientID", "")

app_target.add_resources([resources_group.new_file("supertonic-manifest.json")])
asset = app_group.new_file("LocalAssets/Supertonic")
asset.last_known_file_type = "folder"
app_target.add_resources([asset])
license = app_group.new_file("Vendor/Supertonic/LICENSE")
app_target.add_resources([license])
validation = app_target.new_shell_script_build_phase("Validate Supertonic assets")
validation.shell_script = 'PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "$SRCROOT/scripts/validate_supertonic_assets.py" --root "$SRCROOT/CatRobot/LocalAssets/Supertonic" --manifest "$SRCROOT/CatRobot/Resources/supertonic-manifest.json"'
validation.input_paths = ["$(SRCROOT)/scripts/validate_supertonic_assets.py", "$(SRCROOT)/scripts/prepare_supertonic_assets.py", "$(SRCROOT)/CatRobot/Resources/supertonic-manifest.json", "$(SRCROOT)/CatRobot/LocalAssets/Supertonic"]
JSON.parse(ROOT.join("CatRobot/Resources/supertonic-manifest.json").read).fetch("files").each do |entry|
  validation.input_paths << "$(SRCROOT)/CatRobot/LocalAssets/Supertonic/#{entry.fetch('path')}"
end
validation.always_out_of_date = "1"
app_target.build_phases.delete(validation)
app_target.build_phases.insert(0, validation)

native_reference = app_group.new_file("LocalAssets/JPreprocess/CJPPronunciation.xcframework")
native_reference.last_known_file_type = "wrapper.xcframework"
app_target.frameworks_build_phase.add_file_reference(native_reference, true)
pronunciation_dictionary = app_group.new_file("LocalAssets/JPreprocess/dictionary")
pronunciation_dictionary.last_known_file_type = "folder"
pronunciation_notices = app_group.new_file("Vendor/JPreprocess")
pronunciation_notices.last_known_file_type = "folder"
app_target.add_resources([pronunciation_dictionary, pronunciation_notices])
pronunciation_validation = app_target.new_shell_script_build_phase("Validate jpreprocess assets")
pronunciation_validation.shell_script = 'PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "$SRCROOT/scripts/validate_jpreprocess_assets.py" --root "$SRCROOT/CatRobot/LocalAssets/JPreprocess" --manifest "$SRCROOT/CatRobot/Resources/jpreprocess-manifest.json"'
pronunciation_validation.input_paths = ["$(SRCROOT)/scripts/validate_jpreprocess_assets.py", "$(SRCROOT)/CatRobot/Resources/jpreprocess-manifest.json", "$(SRCROOT)/CatRobot/LocalAssets/JPreprocess"]
pronunciation_validation.always_out_of_date = "1"
app_target.build_phases.delete(pronunciation_validation)
app_target.build_phases.insert(0, pronunciation_validation)

# Xcode 15.3 以降は、静的リンクする onnxruntime.framework の「中身のないスタブ」を Frameworks に埋め込む
# （ビルドログの "Injecting stub binary into codeless framework"）。スタブはアプリの deployment target で
# 作られる一方、Info.plist の MinimumOSVersion は 15.1 のままなので、App Store Connect が ITMS-90208 で
# 却下する。コードはアプリ本体に静的リンク済みなので、最後の段階でスタブを取り除く。
# ENABLE_USER_SCRIPT_SANDBOXING の sandbox は SYMROOT / DSTROOT 以下を deny し、宣言した出力しか読み書きを許さない。
# framework や Frameworks ディレクトリを出力に宣言すると、埋め込み段階や MkDir と "Multiple commands produce" で
# 衝突するため、アプリターゲットだけ sandbox を切る（下の build settings）。スタブ以外（記号を公開する本物の dylib）は
# 残し、検査や削除の失敗は非 0 で止める。
cleanup = app_target.new_shell_script_build_phase("Remove codeless onnxruntime framework")
cleanup.shell_script = <<~'SH'
  set -u
  fw="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/onnxruntime.framework"
  bin="${fw}/onnxruntime"
  if [ ! -d "$fw" ]; then
    echo "note: onnxruntime.framework is not embedded; nothing to remove"
    exit 0
  fi
  if [ -f "$bin" ]; then
    if ! exported="$(xcrun nm -gUj "$bin" 2>&1)"; then
      echo "error: could not inspect ${bin}: ${exported}"
      exit 1
    fi
    # nm prints "<file>: no symbols" instead of an empty list for a stub
    exported="$(printf '%s\n' "$exported" | grep -v -e ': no symbols$' -e '^$' || true)"
    if [ -n "$exported" ]; then
      echo "warning: onnxruntime.framework exports symbols, so it is not a codeless stub; leaving it in place"
      exit 0
    fi
  fi
  if ! rm -rf "$fw" || [ -e "$fw" ]; then
    echo "error: could not remove ${fw}"
    exit 1
  fi
  echo "Removed codeless onnxruntime.framework stub"
SH
cleanup.always_out_of_date = "1"

apply_common_settings(app_target)
apply_common_settings(test_target)

app_target.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME" => "AccentColor",
    "CURRENT_PROJECT_VERSION" => "1",
    "CATROBOT_SOURCE_REVISION" => "unversioned",
    "CATROBOT_CLAUDE_CLIENT_ID" => claude_client_id,
    "CODE_SIGN_ENTITLEMENTS" => "CatRobot/Resources/CatRobot.entitlements",
    "CATROBOT_APP_ATTEST_ENVIRONMENT" => (configuration.name == "Release" ? "production" : "development"),
    "DEVELOPMENT_ASSET_PATHS" => '"CatRobot/Preview Content"',
    "ENABLE_PREVIEWS" => "YES",
    # 「Remove codeless onnxruntime framework」が成果物を検査・削除できるよう、アプリターゲットだけ切る。
    # プロジェクト既定とテストターゲットは YES のまま。
    "ENABLE_USER_SCRIPT_SANDBOXING" => "NO",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "INFOPLIST_FILE" => "CatRobot/Resources/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/Frameworks",
    "MARKETING_VERSION" => "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.kamby.CatRobot",
    "PRODUCT_MODULE_NAME" => "CatRobot",
    "PRODUCT_NAME" => "$(TARGET_NAME)"
  )
  configuration.build_settings["ENABLE_TESTABILITY"] = "YES" if configuration.name == "Debug"
  if configuration.name == "Release"
    configuration.build_settings["EXCLUDED_SOURCE_FILE_NAMES"] = ["$(inherited)", '"Preview Assets.xcassets"', '"claude-api-key.txt"']
  end
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

# Device-only experiments; ordinary unit tests never start the models.
[
  ["SupertonicIntegrationDeviceTests", "SUPER_INTEGRATION_TESTS"]
].each do |identifier, environment_key|
  device_scheme = Xcodeproj::XCScheme.new
  device_scheme.configure_with_targets(app_target, test_target, launch_target: true)
  device_scheme.test_action.build_configuration = "Debug"
  device_scheme.test_action.should_use_launch_scheme_args_env = false
  device_scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
    { key: environment_key, value: "1" }
  ])
  selected_test = Xcodeproj::XCScheme::TestAction::TestableReference::Test.new
  selected_test.identifier = identifier
  device_scheme.test_action.testables.first.selected_tests = [selected_test]
  device_scheme.test_action.testables.first.use_test_selection_whitelist = true
  device_scheme.test_action.testables.first.parallelizable = false
  device_scheme.save_as(PROJECT_PATH.to_s, identifier, true)
end

if resolved_lock
  FileUtils.mkdir_p(lock_path.dirname)
  lock_path.binwrite(resolved_lock)
end
