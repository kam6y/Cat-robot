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

info = Xcodeproj::Plist.read_from_path(ROOT.join("CatRobot/Resources/Info.plist").to_s)
reason = info["NSBluetoothAlwaysUsageDescription"]
assert(reason.is_a?(String) && !reason.strip.empty?, "Bluetooth usage description is missing")
assert(!info.key?("UIBackgroundModes"), "the robot link must remain foreground-only")

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
  "IPHONEOS_DEPLOYMENT_TARGET" => "27.0",
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
assert(package_objects.length == 2, "expected exactly two runtime dependencies")
assert(app.package_product_dependencies.map(&:product_name).sort == ["ClaudeForFoundationModels", "onnxruntime"], "app must link Claude and ONNX Runtime")
assert(tests.package_product_dependencies.map(&:product_name) == ["ClaudeForFoundationModels"], "tests must link Claude for error-type tests")
claude = project.root_object.package_references.find { |p| p.repositoryURL.end_with?("ClaudeForFoundationModels.git") }
assert(claude && claude.requirement == { "kind" => "exactVersion", "version" => "0.2.3" }, "pinned ClaudeForFoundationModels missing")
app.build_configurations.each do |configuration|
  settings = configuration.build_settings
  assert(settings["CODE_SIGN_ENTITLEMENTS"] == "CatRobot/Resources/CatRobot.entitlements", "entitlements missing")
  expected_env = configuration.name == "Release" ? "production" : "development"
  assert(settings["CATROBOT_APP_ATTEST_ENVIRONMENT"] == expected_env, "App Attest environment for #{configuration.name}")
  assert(settings.key?("CATROBOT_CLAUDE_CLIENT_ID"), "client id build setting missing")
end
dev_key = app.resources_build_phase.files.find { |f| f.file_ref&.path == "LocalAssets/claude-api-key.txt" }
assert(dev_key, "development key must be a bundled resource reference")
release = app.build_configurations.find { |c| c.name == "Release" }
debug = app.build_configurations.find { |c| c.name == "Debug" }
assert(Array(release.build_settings["EXCLUDED_SOURCE_FILE_NAMES"]).include?('"claude-api-key.txt"'), "Release must exclude the development key")
assert(!Array(debug.build_settings["EXCLUDED_SOURCE_FILE_NAMES"]).include?('"claude-api-key.txt"'), "Debug must bundle the development key")
assert(project.build_configurations.all? { |c| c.build_settings["ENABLE_USER_SCRIPT_SANDBOXING"] == "YES" }, "script sandboxing must stay on")
%w[GemmaDeviceTests GemmaAppDeviceTests ReplyLatencyDeviceTests].each do |name|
  assert(!PROJECT_PATH.join("xcshareddata/xcschemes/#{name}.xcscheme").file?, "#{name} scheme must be gone")
end

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

native = app.frameworks_build_phase.files_references.find { |r| r&.path == "LocalAssets/JPreprocess/CJPPronunciation.xcframework" }
assert(native, "native Japanese pronunciation library must be linked")
assert(app.resources_build_phase.files_references.any? { |r| r.path == "LocalAssets/JPreprocess/dictionary" }, "Japanese pronunciation dictionary must be bundled")
assert(app.resources_build_phase.files_references.any? { |r| r.path == "Vendor/JPreprocess" }, "jpreprocess notices must be bundled")
pronunciation_validation = app.shell_script_build_phases.find { |p| p.name == "Validate jpreprocess assets" }
assert(pronunciation_validation && app.build_phases.index(pronunciation_validation) < app.build_phases.index(app.source_build_phase), "jpreprocess must be validated before compilation")
[app, tests].each do |target|
  assert(target.build_configurations.all? { |c| Array(c.build_settings["SWIFT_INCLUDE_PATHS"]).flat_map { |v| v.split }.include?("$(SRCROOT)/native/japanese-pronunciation/include") }, "native C module must be importable by #{target.name}")
end
assert(app.copy_files_build_phases.none? { |p| p.files_references.include?(native) }, "static jpreprocess library must not be embedded")

ort = project.root_object.package_references.find { |p| p.repositoryURL.end_with?("onnxruntime-swift-package-manager") }
assert(ort && ort.requirement == { "kind" => "exactVersion", "version" => "1.24.2" }, "pinned ONNX runtime missing")
assert(app.resources_build_phase.files_references.any? { |r| r.path == "LocalAssets/Supertonic" }, "Supertonic bundle missing")
assert(app.shell_script_build_phases.any? { |p| p.name == "Validate Supertonic assets" }, "asset validation missing")
cleanup = app.shell_script_build_phases.find { |p| p.name == "Remove codeless onnxruntime framework" }
assert(cleanup && cleanup.shell_script.include?("onnxruntime.framework"), "codeless framework cleanup missing")
assert(app.build_phases.last.equal?(cleanup), "codeless framework cleanup must be the last build phase")
assert(cleanup.output_paths.empty? && cleanup.input_paths.empty?,
       "codeless framework cleanup must not declare the framework or Frameworks directory as an output: both collide with the embed and MkDir steps (Multiple commands produce)")
assert(app.build_configurations.all? { |c| c.build_settings["ENABLE_USER_SCRIPT_SANDBOXING"] == "NO" },
       "the app target must run its script phases unsandboxed so the cleanup can inspect and delete the stub under SYMROOT / DSTROOT")
assert(targets.fetch("CatRobotTests").build_configurations.none? { |c| c.build_settings.key?("ENABLE_USER_SCRIPT_SANDBOXING") },
       "the test target must keep the project-level script sandboxing")

# スタブ除去スクリプトの振る舞い: 記号を公開しないスタブだけを消し、検査や削除の失敗は非 0 で止める。
require "tmpdir"
require "open3"
def run_cleanup(script, products, framework: true, with_binary: nil, mode: nil)
  app_dir = File.join(products, "CatRobot.app")
  fw = File.join(app_dir, "Frameworks", "onnxruntime.framework")
  FileUtils.mkdir_p(framework ? fw : File.join(app_dir, "Frameworks"))
  FileUtils.cp(with_binary, File.join(fw, "onnxruntime")) if with_binary
  File.chmod(mode, File.join(app_dir, "Frameworks")) if mode
  out, status = Open3.capture2e({ "TARGET_BUILD_DIR" => products, "FRAMEWORKS_FOLDER_PATH" => "CatRobot.app/Frameworks" }, "/bin/sh", "-c", script)
  [out, status.exitstatus, File.exist?(fw)]
ensure
  File.chmod(0o755, File.join(app_dir, "Frameworks")) if mode && File.directory?(File.join(app_dir, "Frameworks"))
end

Dir.mktmpdir("cat-onnx-cleanup") do |dir|
  stub = File.join(dir, "stub.dylib")
  real = File.join(dir, "real.dylib")
  src = File.join(dir, "real.c")
  File.write(src, "int OrtGetApiBase(void) { return 0; }\n")
  system("xcrun", "clang", "-dynamiclib", "-x", "c", "/dev/null", "-o", stub, exception: true)
  system("xcrun", "clang", "-dynamiclib", src, "-o", real, exception: true)
  script = cleanup.shell_script

  out, code, remains = run_cleanup(script, File.join(dir, "stub"), with_binary: stub)
  assert(code == 0 && !remains && out.include?("Removed codeless"), "stub must be removed: #{out}")

  out, code, remains = run_cleanup(script, File.join(dir, "real"), with_binary: real)
  assert(code == 0 && remains && out.include?("not a codeless stub"), "a real dylib must be kept: #{out}")

  out, code, remains = run_cleanup(script, File.join(dir, "absent"), framework: false)
  assert(code == 0 && !remains && out.include?("nothing to remove"), "missing framework must be a no-op: #{out}")

  unreadable = File.join(dir, "unreadable")
  FileUtils.mkdir_p(File.join(unreadable, "CatRobot.app", "Frameworks", "onnxruntime.framework"))
  FileUtils.cp(stub, File.join(unreadable, "CatRobot.app", "Frameworks", "onnxruntime.framework", "onnxruntime"))
  File.chmod(0o000, File.join(unreadable, "CatRobot.app", "Frameworks", "onnxruntime.framework", "onnxruntime"))
  out, code, remains = run_cleanup(script, unreadable)
  assert(code == 1 && remains && out.include?("could not inspect"), "unreadable binary must fail loudly: #{out}")

  out, code, remains = run_cleanup(script, File.join(dir, "locked"), with_binary: stub, mode: 0o555)
  assert(code == 1 && remains && out.include?("could not remove"), "removal failure must fail loudly: #{out}")
end

assert(PROJECT_PATH.join("xcshareddata/xcschemes/SupertonicIntegrationDeviceTests.xcscheme").file?, "integration device scheme missing")
