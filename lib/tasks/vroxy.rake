# Rake tasks the vroxy gem adds to the host app.
namespace :vroxy do
  desc "Mine activerecord.models i18n labels and sync them to the vroxy glossary (needs VROXY_SECRET_TOKEN)"
  task sync_glossary: :environment do
    entries = Vroxy::Glossary.entries_from_i18n
    if entries.empty?
      puts "vroxy: no glossary candidates found — activerecord.models labels all match their model names, and no glossary_extra configured."
      next
    end
    puts "vroxy: syncing #{entries.size} glossary entr#{entries.size == 1 ? 'y' : 'ies'}:"
    entries.each { |e| puts "  • #{e['term']} ← #{Array(e['aliases']).join(', ')}" }
    result = Vroxy::Glossary.sync!(entries)
    puts "vroxy: server now has #{Array(result['entries']).size} entries."
  end

  desc "Push config.tool definitions to the vroxy workspace (needs VROXY_SECRET_TOKEN)"
  task sync_tools: :environment do
    tools = Vroxy.configuration.tools.all
    if tools.empty?
      puts "vroxy: no tools declared — add config.tool \"name\" { … } in config/initializers/vroxy.rb"
      next
    end
    puts "vroxy: syncing #{tools.size} tool#{'s' unless tools.size == 1}:"
    tools.each { |t| puts "  • #{t.name} (#{t.resolved_kind}, #{t.access})" }
    result = Vroxy::Tools::Sync.sync!
    puts "vroxy: synced #{result['synced']} tool#{'s' unless result['synced'] == 1}."
  end

  desc "Push config.doc definitions to the vroxy knowledge base (needs VROXY_SECRET_TOKEN)"
  task sync_docs: :environment do
    docs = Vroxy.configuration.docs.all
    if docs.empty?
      puts "vroxy: no docs declared — add config.doc \"Title\" { … } in config/initializers/vroxy.rb"
      next
    end
    puts "vroxy: syncing #{docs.size} doc#{'s' unless docs.size == 1}:"
    docs.each { |d| puts "  • #{d.folder_path.empty? ? d.title : "#{d.folder_path}/#{d.title}"}" }
    result = Vroxy::Docs::Sync.sync!
    puts "vroxy: synced #{result['synced']} doc#{'s' unless result['synced'] == 1}."
  end

  desc "Sync glossary, tools, and docs to the vroxy workspace"
  task sync: :environment do
    Rake::Task["vroxy:sync_glossary"].invoke
    Rake::Task["vroxy:sync_tools"].invoke
    Rake::Task["vroxy:sync_docs"].invoke
  end
end
