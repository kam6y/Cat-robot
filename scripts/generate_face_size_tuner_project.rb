#!/usr/bin/env ruby
# frozen_string_literal: true
require "fileutils"
require "pathname"
require "rubygems"
require "xcodeproj"

abort("Expected xcodeproj 1.27.0") unless Xcodeproj::VERSION == "1.27.0"
root = Pathname.new(__dir__).join("..").expand_path
tool = root.join("tools/face-size-tuner")
path = tool.join("FaceSizeTuner.xcodeproj")
FileUtils.rm_rf(path.to_s)
project = Xcodeproj::Project.new(path.to_s, false, 77)
project.root_object.development_region = "ja"
project.root_object.known_regions = %w[ja en Base]
app = project.new_target(:application, "FaceSizeTuner", :ios, "27.0", nil, :swift)
tests = project.new_target(:unit_test_bundle, "FaceSizeTunerTests", :ios, "27.0", nil, :swift)
sources = project.main_group.new_group("Sources", "Sources")
shared = project.main_group.new_group("Shared Face", "../../CatRobot/Conversation/UI")
app.add_file_references(Dir[tool.join("Sources/*.swift")].sort.map { |file| sources.new_file(File.basename(file)) })
app.add_file_references(%w[CatFaceView.swift CatFaceAppearance.swift CatFaceShapes.swift CatFaceRenderer.swift].map { |file| shared.new_file(file) })
app.add_file_references([project.main_group.new_file("../../scripts/face-render/Stubs.swift")])
app.add_resources([project.main_group.new_file("../../CatRobot/Resources/Assets.xcassets")])
project.main_group.new_file("Resources/Info.plist")
test_group = project.main_group.new_group("Tests", "Tests")
tests.add_file_references(Dir[tool.join("Tests/*.swift")].sort.map { |file| test_group.new_file(File.basename(file)) })
tests.add_dependency(app)
tests.add_system_framework("XCTest")
tests.add_file_references([project.main_group.new_file("../../CatRobotTests/App/AccessibilityActivationSupport.swift")])
[app, tests].each do |target|
  target.build_configurations.each do |config|
    config.build_settings.merge!(
      "CODE_SIGN_STYLE" => "Automatic", "DEVELOPMENT_TEAM" => "VUB4VP6453",
      "IPHONEOS_DEPLOYMENT_TARGET" => "27.0", "SDKROOT" => "iphoneos",
      "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator", "TARGETED_DEVICE_FAMILY" => "1",
      "SWIFT_VERSION" => "6.0", "SWIFT_STRICT_CONCURRENCY" => "complete",
      "SUPPORTS_MACCATALYST" => "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD" => "NO",
      "MARKETING_VERSION" => "1.0", "CURRENT_PROJECT_VERSION" => "1"
    )
  end
end
app.build_configurations.each do |config|
  config.build_settings.merge!(
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.kamby.CatFaceSizeTuner",
    "INFOPLIST_FILE" => "Resources/Info.plist", "GENERATE_INFOPLIST_FILE" => "NO",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME" => "AccentColor",
    "CATROBOT_SOURCE_REVISION" => "unversioned",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/Frameworks"
  )
  config.build_settings["ENABLE_TESTABILITY"] = "YES" if config.name == "Debug"
end
tests.build_configurations.each do |config|
  config.build_settings.merge!(
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.kamby.CatFaceSizeTunerTests",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "BUNDLE_LOADER" => "$(TEST_HOST)",
    "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/FaceSizeTuner.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/FaceSizeTuner",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @loader_path/Frameworks @executable_path/Frameworks"
  )
end
2.times { project.sort; project.predictabilize_uuids }
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, tests, launch_target: true)
scheme.test_action.build_configuration = "Debug"
scheme.launch_action.build_configuration = "Debug"
scheme.save_as(path.to_s, "FaceSizeTuner", true)
puts "Generated #{path}"
