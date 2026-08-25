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
end
