# frozen_string_literal: true

require "vroxy/api_client"

module Vroxy
  module Tools
    module Sync
      module_function

      def sync!(registry = Vroxy.configuration.tools)
        client = ApiClient.new
        results = registry.all.map do |tool|
          payload = client.upsert_tool(tool.sync_payload)
          { "name" => tool.name, "id" => payload.dig("tool", "id"), "kind" => tool.resolved_kind }
        end
        { "synced" => results.size, "tools" => results }
      end
    end
  end
end
