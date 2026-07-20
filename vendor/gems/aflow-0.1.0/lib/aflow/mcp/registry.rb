module Aflow
  module MCP
    class Registry
      def initialize
        @tools = {}
      end

      def register_tool(name, meta, adapter)
        @tools[name.to_s] = adapter
      end

      def find(name)
        @tools[name.to_s] or raise "Tool not found: #{name}"
      end
    end
  end
end
