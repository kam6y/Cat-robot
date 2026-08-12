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
preview_group = app_group.new_group("Preview Content", "Preview Content")
preview_assets_reference = preview_group.new_file("Preview Assets.xcassets")

app_target = project.new_target(:application, APP_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)
test_target = project.new_target(:unit_test_bundle, TEST_TARGET_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)

app_target.add_file_references(swift_references(app_group, ROOT.join("CatRobot")))
test_target.add_file_references(swift_references(test_group, ROOT.join("CatRobotTests")))
app_target.add_resources([assets_reference, preview_assets_reference])
test_target.add_dependency(app_target)
test_target.add_system_framework("XCTest")

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
