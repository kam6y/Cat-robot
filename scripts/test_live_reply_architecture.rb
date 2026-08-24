#!/usr/bin/env ruby

root = File.expand_path("..", __dir__)

def swift_source(root, relative_roots)
  relative_roots.flat_map do |relative_root|
    Dir.glob(File.join(root, relative_root, "**", "*.swift")).sort
  end.map { |path| [path, File.read(path, encoding: "UTF-8")] }
end

failures = []
backend_free_roots = %w[
  CatRobot/Conversation/Domain
  CatRobot/Conversation/Memory
  CatRobot/Conversation/Tools
  CatRobot/Conversation/Integration
  CatRobot/Conversation/UI
]
backend_tokens = %w[SystemLanguageModel LanguageModelSession Gemma LiteRT LiteRTLM]

swift_source(root, backend_free_roots).each do |path, source|
  backend_tokens.each do |token|
    failures << "#{path}: forbidden backend token #{token}" if source.include?(token)
  end
end

production_sources = swift_source(root, ["CatRobot"])
logging_pattern = /\b(?:print|debugPrint|dump|NSLog)\s*\(|\b(?:Logger|os_log)\b/
production_sources.each do |path, source|
  failures << "#{path}: production logging is forbidden" if source.match?(logging_pattern)
end

ui_integration_sources = swift_source(
  root,
  %w[CatRobot/Conversation/Integration CatRobot/Conversation/UI]
)
private_tokens = %w[
  supportingQuote
  MemoryFact
  MemorySearchResult
  RememberMemoryArguments
  ForgetMemoryArguments
  SearchMemoryArguments
]
ui_integration_sources.each do |path, source|
  private_tokens.each do |token|
    failures << "#{path}: private payload token #{token}" if source.include?(token)
  end
end

notice_path = File.join(
  root,
  "CatRobot/Conversation/UI/MemoryNoticePresentation.swift"
)
notice_source = File.read(notice_path, encoding: "UTF-8")
%w[記憶しました 記憶を削除しました 記憶を更新しました].each do |copy|
  failures << "#{notice_path}: missing generic copy #{copy}" unless notice_source.include?(copy)
end

apple_factory = File.read(
  File.join(
    root,
    "CatRobot/Conversation/Services/AppleSystemReplySessionFactory.swift"
  ),
  encoding: "UTF-8"
)
unless apple_factory.include?("SystemLanguageModel(useCase: .general")
  failures << "Apple reply factory does not own the .general model"
end

general_model_owners = swift_source(
  root,
  ["CatRobot/Conversation/Services"]
).select { |_path, source| source.include?("useCase: .general") }
unless general_model_owners.length == 1 &&
       general_model_owners.first.first.end_with?(
         "AppleSystemReplySessionFactory.swift"
       )
  failures << "the Apple reply factory must be the only .general model owner"
end

old_reply_service = File.join(
  root,
  "CatRobot/Conversation/Services/FoundationModelReplyService.swift"
)
failures << "obsolete FoundationModelReplyService still exists" if File.exist?(
  old_reply_service
)

classifier = File.read(
  File.join(
    root,
    "CatRobot/Conversation/Services/FoundationModelAddressClassifier.swift"
  ),
  encoding: "UTF-8"
)
failures << "content-tagging classifier must remain tool-free" if classifier.include?(
  "tools:"
)

tool_service = File.read(
  File.join(
    root,
    "CatRobot/Conversation/Services/ToolEnabledReplyService.swift"
  ),
  encoding: "UTF-8"
)
unless tool_service.include?("LocalMemoryStore.applicationSupport()")
  failures << "live tool service does not default to Application Support"
end

composition = File.read(
  File.join(
    root,
    "CatRobot/Conversation/Integration/ConversationDependencies.swift"
  ),
  encoding: "UTF-8"
)
unless composition.include?("AppleSystemReplySessionFactory") &&
       composition.include?("ToolEnabledReplyService")
  failures << "live composition does not connect Apple factory to tool service"
end

abort(failures.join("\n")) unless failures.empty?
puts "live reply architecture contract passed"
