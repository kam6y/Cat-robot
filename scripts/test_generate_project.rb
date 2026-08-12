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
