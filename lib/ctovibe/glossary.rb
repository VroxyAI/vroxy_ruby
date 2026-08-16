# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Ctovibe
  # Builds the tenant's model glossary from the HOST APP's i18n and
  # pushes it to ctovibe, so the support bot learns the app's
  # vocabulary ("property"/"listing" → what the admin calls a
  # "product") without anyone hand-typing mappings.
  #
  # Where the words come from: `activerecord.models.*` — the same
  # translations Rails admins already maintain, and (as on apps that
  # whitelabel per environment) exactly where per-deployment nounage
  # lives.  A model whose display label differs from its key becomes
  # an entry: `{ term: "product", aliases: ["Listing"] }`.
  #
  # Run via `bin/rails ctovibe:sync_glossary`.  Needs
  # `config.secret_token` (a tenant-owned ctovibe API token with
  # tenant:write — NOT the public api_key) because glossary writes go
  # through the server-to-server API.
  module Glossary
    module_function

    # Extract candidate entries from I18n.  Pure — no network.
    def entries_from_i18n
      models = I18n.t("activerecord.models", default: {})
      return [] unless models.is_a?(Hash)

      entries = models.filter_map do |key, label|
        # Nested one/other plural hashes → take both forms.
        labels = label.is_a?(Hash) ? label.values : [ label ]
        labels = labels.grep(String).map(&:strip).reject(&:empty?)
        next nil if labels.empty?

        term    = key.to_s
        # Only interesting when the display noun DIFFERS from the
        # model name — "Product" shown as "Product" teaches nothing.
        aliases = labels.reject { |l| l.downcase == term.tr("_", " ") }
        next nil if aliases.empty?

        entry = { "term" => term, "aliases" => aliases.uniq }
        if (builder = Ctovibe.configuration.glossary_admin_url)
          url = builder.call(term) rescue nil
          entry["admin_url_template"] = url if url
        end
        entry
      end

      entries + Array(Ctovibe.configuration.glossary_extra)
    end

    # PUT the entries to ctovibe.  Returns the parsed response hash.
    def sync!(entries = entries_from_i18n)
      secret = Ctovibe.configuration.secret_token
      raise "Ctovibe.configuration.secret_token (or ENV CTOVIBE_SECRET_TOKEN) is required — a tenant API token with tenant:write" if secret.to_s.strip.empty?

      endpoint = Ctovibe.configuration.endpoint.to_s
      endpoint = "https://ctovibe.ai" if endpoint.strip.empty?
      uri = URI.parse("#{endpoint.chomp('/')}/api/v1/glossary")

      req = Net::HTTP::Put.new(uri)
      req["Authorization"] = "Bearer #{secret}"
      req["Content-Type"]  = "application/json"
      req.body = JSON.generate({ entries: entries })

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: 10, read_timeout: 10) { |http| http.request(req) }
      raise "ctovibe glossary sync failed: HTTP #{res.code} #{res.body.to_s[0, 300]}" unless res.code.to_i.between?(200, 299)
      JSON.parse(res.body)
    end
  end
end
