# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Vroxy
  # Builds the tenant's model glossary from the HOST APP's i18n and
  # pushes it to vroxy, so the support bot learns the app's
  # vocabulary ("property"/"listing" → what the admin calls a
  # "product") without anyone hand-typing mappings.
  #
  # Where the words come from: `activerecord.models.*` — the same
  # translations Rails admins already maintain, and (as on apps that
  # whitelabel per environment) exactly where per-deployment nounage
  # lives.  A model whose display label differs from its key becomes
  # an entry: `{ term: "product", aliases: ["Listing"] }`.
  #
  # Run via `bin/rails vroxy:sync_glossary`.  Needs
  # `config.secret_token` (a tenant-owned vroxy API token with
  # tenant:write — NOT the public api_key) because glossary writes go
  # through the server-to-server API.
  module Glossary
    module_function

    # I18n pluralization keys.  Any OTHER hash under
    # `activerecord.models.<key>` is a NAMESPACE (`admin: { user:
    # "…" }`), not plural forms — reading its values as labels used
    # to publish `admin` as a term aliased to the User label.
    PLURAL_KEYS = %w[zero one two few many other].freeze

    # Mirrors the server's term rule.  One unusable term would
    # otherwise 422 the entire PUT and sync nothing at all.
    TERM_RE = /\A[a-z0-9_ -]{2,40}\z/i

    # Extract candidate entries from I18n.  Pure — no network.
    def entries_from_i18n
      models = I18n.t("activerecord.models", default: {})
      return [] unless models.is_a?(Hash)

      entries = models.filter_map do |key, label|
        labels =
          if label.is_a?(Hash)
            next nil unless label.keys.all? { |k| PLURAL_KEYS.include?(k.to_s) }
            label.values
          else
            [ label ]
          end
        labels = labels.grep(String).map(&:strip).reject(&:empty?)
        next nil if labels.empty?

        term = key.to_s
        next nil unless term.match?(TERM_RE)
        # Only interesting when the display noun DIFFERS from the
        # model name — "Product" shown as "Product" teaches nothing.
        aliases = labels.reject { |l| l.downcase == term.tr("_", " ") }
        next nil if aliases.empty?

        entry = { "term" => term, "aliases" => aliases.uniq }
        if (builder = Vroxy.configuration.glossary_admin_url)
          url = builder.call(term) rescue nil
          entry["admin_url_template"] = url if url
        end
        entry
      end

      entries + Array(Vroxy.configuration.glossary_extra)
    end

    # PUT the entries to vroxy.  Returns the parsed response hash.
    def sync!(entries = entries_from_i18n)
      secret = Vroxy.configuration.secret_token
      raise "Vroxy.configuration.secret_token (or ENV VROXY_SECRET_TOKEN) is required — a tenant API token with tenant:write" if secret.to_s.strip.empty?

      endpoint = Vroxy.configuration.endpoint.to_s
      endpoint = "https://vroxy.ai" if endpoint.strip.empty?
      uri = URI.parse("#{endpoint.chomp('/')}/api/v1/glossary")

      req = Net::HTTP::Put.new(uri)
      req["Authorization"] = "Bearer #{secret}"
      req["Content-Type"]  = "application/json"
      req.body = JSON.generate({ entries: entries })

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: 10, read_timeout: 10) { |http| http.request(req) }
      raise "vroxy glossary sync failed: HTTP #{res.code} #{res.body.to_s[0, 300]}" unless res.code.to_i.between?(200, 299)
      JSON.parse(res.body)
    end
  end
end
