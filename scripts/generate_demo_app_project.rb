#!/usr/bin/env ruby

require "fileutils"
require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "AssistantRuntimeDemoApp.xcodeproj")
DEFAULT_BUNDLE_ID = "ai.assistantruntime.demoapp"
bundle_id = ENV.fetch("ASSISTANT_RUNTIME_DEMO_BUNDLE_ID", DEFAULT_BUNDLE_ID)
bundle_id = bundle_id.gsub(/[^A-Za-z0-9.]/, "").downcase

FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2600"
project.root_object.attributes["LastUpgradeCheck"] = "2600"

deployment_target = "17.0"

app_target = project.new_target(:application, "AssistantRuntimeDemoApp", :ios, deployment_target)
kit_target = project.new_target(:framework, "AssistantRuntimeKit", :ios, deployment_target)
demo_target = project.new_target(:framework, "AssistantRuntimeDemo", :ios, deployment_target)

sources_group = project.main_group.find_subpath("Sources", true)
demo_app_group = project.main_group.find_subpath("DemoApp", true)
scripts_group = project.main_group.find_subpath("scripts", true)
project.main_group.set_source_tree("<group>")

[
  [kit_target, "Sources/AssistantRuntimeKit", sources_group.find_subpath("AssistantRuntimeKit", true)],
  [demo_target, "Sources/AssistantRuntimeDemo", sources_group.find_subpath("AssistantRuntimeDemo", true)],
  [app_target, "DemoApp/AssistantRuntimeDemoApp", demo_app_group.find_subpath("AssistantRuntimeDemoApp", true)],
].each do |target, relative_root, group|
  Dir.glob(File.join(ROOT, relative_root, "**/*.swift")).sort.each do |path|
    rel = path.delete_prefix("#{ROOT}/")
    file_ref = group.new_file(rel)
    target.add_file_references([file_ref])
  end
end

info_plist_ref = demo_app_group.find_subpath("AssistantRuntimeDemoApp", true).new_file(
  "DemoApp/AssistantRuntimeDemoApp/Info.plist"
)
script_ref = scripts_group.new_file("scripts/generate_demo_app_project.rb")
script_ref.include_in_index = "0"

[kit_target, demo_target, app_target].each do |target|
  target.build_configurations.each do |config|
    config.build_settings["SWIFT_VERSION"] = "6.0"
    config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = deployment_target
    config.build_settings["SDKROOT"] = "iphoneos"
    config.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
    config.build_settings["CLANG_ENABLE_MODULES"] = "YES"
    config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
    config.build_settings["DEVELOPMENT_TEAM"] = ""
  end
end

[kit_target, demo_target].each do |target|
  target.build_configurations.each do |config|
    config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
    config.build_settings["SKIP_INSTALL"] = "NO"
    config.build_settings["DEFINES_MODULE"] = "YES"
    config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "#{bundle_id}.#{target.name.downcase}"
    config.build_settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
    config.build_settings["MACH_O_TYPE"] = "mh_dylib"
  end
end

app_target.build_configurations.each do |config|
  config.build_settings["INFOPLIST_FILE"] = "DemoApp/AssistantRuntimeDemoApp/Info.plist"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id
  config.build_settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  config.build_settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/Frameworks"]
  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = ""
end

demo_target.add_dependency(kit_target)
demo_target.frameworks_build_phase.add_file_reference(kit_target.product_reference)

app_target.add_dependency(demo_target)
app_target.add_dependency(kit_target)
app_target.frameworks_build_phase.add_file_reference(demo_target.product_reference)
app_target.frameworks_build_phase.add_file_reference(kit_target.product_reference)

embed_phase = app_target.copy_files_build_phases.find { |phase| phase.name == "Embed Frameworks" } ||
  app_target.new_copy_files_build_phase("Embed Frameworks")
embed_phase.symbol_dst_subfolder_spec = :frameworks

[demo_target, kit_target].each do |target|
  build_file = embed_phase.add_file_reference(target.product_reference)
  build_file.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }
end

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app_target, nil, launch_target: app_target)
scheme.save_as(PROJECT_PATH, "AssistantRuntimeDemoApp", true)

project.save
