# frozen_string_literal: true

require "vroxy/api_client"

module Vroxy
  module Docs
    module Sync
      module_function

      def sync!(registry = Vroxy.configuration.docs)
        client = ApiClient.new
        existing = index_by_marker(client)
        results = registry.all.map do |doc|
          payload = doc.sync_payload
          if (id = existing[doc.marker])
            client.update_doc(id, payload.except("notes"))
            client.publish_doc(id) if doc.status == "published"
            { "slug" => doc.slug, "id" => id, "action" => "updated" }
          else
            created = client.create_doc(payload)
            id = created.dig("doc", "id")
            client.publish_doc(id) if doc.status == "published" && created.dig("doc", "status") != "published"
            { "slug" => doc.slug, "id" => id, "action" => "created" }
          end
        end
        { "synced" => results.size, "docs" => results }
      end

      def index_by_marker(client)
        page = client.list_docs
        rows = Array(page["docs"] || page["data"] || [])
        rows.each_with_object({}) do |row, out|
          notes = row["notes"].to_s
          next unless notes.start_with?("seeded:gem:")
          out[notes] = row["id"]
        end
      end
      private_class_method :index_by_marker
    end
  end
end
