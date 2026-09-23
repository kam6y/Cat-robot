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

package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
package.repositoryURL = "https://github.com/google-ai-edge/LiteRT-LM"
package.requirement = { "kind" => "exactVersion", "version" => "0.17.1" }
project.root_object.package_references << package
[app_target, test_target].each do |target|
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = package
  product.product_name = "LiteRTLM"
  target.package_product_dependencies << product
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  target.frameworks_build_phase.files << build_file
end

apply_common_settings(app_target)
apply_common_settings(test_target)

app_target.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME" => "AccentColor",
    "CURRENT_PROJECT_VERSION" => "1",
    "DEVELOPMENT_ASSET_PATHS" => '"CatRobot/Preview Content"',
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
  if configuration.name == "Release"
    configuration.build_settings["EXCLUDED_SOURCE_FILE_NAMES"] = ["$(inherited)", '"Preview Assets.xcassets"']
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

# Device-only experiment; ordinary unit tests never start the model.
device_scheme = Xcodeproj::XCScheme.new
device_scheme.configure_with_targets(app_target, test_target, launch_target: true)
device_scheme.test_action.build_configuration = "Debug"
device_scheme.test_action.should_use_launch_scheme_args_env = false
device_scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([{ key: "GEMMA_DEVICE_TESTS", value: "1" }])
selected_test = Xcodeproj::XCScheme::TestAction::TestableReference::Test.new
selected_test.identifier = "GemmaDeviceTests"
device_scheme.test_action.testables.first.selected_tests = [selected_test]
device_scheme.test_action.testables.first.use_test_selection_whitelist = true
device_scheme.test_action.testables.first.parallelizable = false
device_scheme.save_as(PROJECT_PATH.to_s, "GemmaDeviceTests", true)

app_device_scheme = Xcodeproj::XCScheme.new
app_device_scheme.configure_with_targets(app_target, test_target, launch_target: true)
app_device_scheme.test_action.build_configuration = "Debug"
app_device_scheme.test_action.should_use_launch_scheme_args_env = false
app_device_scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([{ key: "GEMMA_APP_DEVICE_TESTS", value: "1" }])
app_test = Xcodeproj::XCScheme::TestAction::TestableReference::Test.new
app_test.identifier = "GemmaAppDeviceTests"
app_device_scheme.test_action.testables.first.selected_tests = [app_test]
app_device_scheme.test_action.testables.first.use_test_selection_whitelist = true
app_device_scheme.test_action.testables.first.parallelizable = false
app_device_scheme.save_as(PROJECT_PATH.to_s, "GemmaAppDeviceTests", true)

latency_scheme = Xcodeproj::XCScheme.new
latency_scheme.configure_with_targets(app_target, test_target, launch_target: true)
latency_scheme.test_action.build_configuration = "Debug"
latency_scheme.test_action.should_use_launch_scheme_args_env = false
latency_scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([{ key: "CATROBOT_REPLY_LATENCY_TESTS", value: "1" }])
latency_test = Xcodeproj::XCScheme::TestAction::TestableReference::Test.new
latency_test.identifier = "ReplyLatencyDeviceTests"
latency_scheme.test_action.testables.first.selected_tests = [latency_test]
latency_scheme.test_action.testables.first.use_test_selection_whitelist = true
latency_scheme.test_action.testables.first.parallelizable = false
latency_scheme.save_as(PROJECT_PATH.to_s, "ReplyLatencyDeviceTests", true)

if resolved_lock
  FileUtils.mkdir_p(lock_path.dirname)
  lock_path.binwrite(resolved_lock)
end
