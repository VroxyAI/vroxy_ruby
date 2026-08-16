# Rake tasks the ctovibe gem adds to the host app.
namespace :ctovibe do
  desc "Mine activerecord.models i18n labels and sync them to the ctovibe glossary (needs CTOVIBE_SECRET_TOKEN)"
  task sync_glossary: :environment do
    entries = Ctovibe::Glossary.entries_from_i18n
    if entries.empty?
      puts "ctovibe: no glossary candidates found — activerecord.models labels all match their model names, and no glossary_extra configured."
      next
    end
    puts "ctovibe: syncing #{entries.size} glossary entr#{entries.size == 1 ? 'y' : 'ies'}:"
    entries.each { |e| puts "  • #{e['term']} ← #{Array(e['aliases']).join(', ')}" }
    result = Ctovibe::Glossary.sync!(entries)
    puts "ctovibe: server now has #{Array(result['entries']).size} entries."
  end
end
