#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "fileutils"
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
APP_PROBE_ROOT = ROOT.join("CatRobot/ProjectGeneratorContractProbe")
TEST_PROBE_ROOT = ROOT.join("CatRobotTests/ProjectGeneratorContractProbe")
APP_PROBE_PATHS = [
  APP_PROBE_ROOT.join("Zebra.swift"),
  APP_PROBE_ROOT.join("Nested/Middle.swift"),
  APP_PROBE_ROOT.join("Aardvark.swift")
].freeze
TEST_PROBE_PATHS = [
  TEST_PROBE_ROOT.join("Zulu.swift"),
  TEST_PROBE_ROOT.join("Nested/Omega.swift"),
  TEST_PROBE_ROOT.join("Alpha.swift")
].freeze

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

def write_probe_sources(paths)
  paths.each do |path|
    FileUtils.mkdir_p(path.dirname)
    path.write("// Project generator contract probe\n")
  end
end

def probe_source_paths(target, probe_root)
  probe_prefix = "#{probe_root.basename}/"

  target.source_build_phase.files_references.map do |reference|
    path = reference.path
    path if path&.start_with?(probe_prefix)
  end.compact
end

def with_probe_sources
  write_probe_sources(APP_PROBE_PATHS)
  write_probe_sources(TEST_PROBE_PATHS)
  yield
ensure
  FileUtils.rm_rf(APP_PROBE_ROOT)
  FileUtils.rm_rf(TEST_PROBE_ROOT)
  run_generator!
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

assert(!APP_PROBE_ROOT.exist?, "app source probe path already exists")
assert(!TEST_PROBE_ROOT.exist?, "test source probe path already exists")

with_probe_sources do
  run_generator!
  probe_project = Xcodeproj::Project.open(PROJECT_PATH.to_s)
  probe_targets = probe_project.targets.to_h { |target| [target.name, target] }
  probe_app = probe_targets.fetch("CatRobot")
  probe_tests = probe_targets.fetch("CatRobotTests")

  assert(
    probe_source_paths(probe_app, APP_PROBE_ROOT) == APP_PROBE_PATHS.map { |path| path.relative_path_from(ROOT.join("CatRobot")).to_s }.sort,
    "app source probe paths are not recursively discovered in sorted order"
  )
  assert(
    probe_source_paths(probe_tests, TEST_PROBE_ROOT) == TEST_PROBE_PATHS.map { |path| path.relative_path_from(ROOT.join("CatRobotTests")).to_s }.sort,
    "test source probe paths are not recursively discovered in sorted order"
  )
end

puts "PASS: deterministic CatRobot project contract"
