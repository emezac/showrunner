module Aflow
  module MCP
    class Server
      def initialize
        @registry = Registry.new
      end

      def tool(name, **meta, &block)
        @registry.register_tool(name, meta, Adapters::ProcAdapter.new(block))
      end

      def flow(name, with:)
        @registry.register_tool(
          name,
          { type: :flow },
          Adapters::FlowAdapter.new(with)
        )
      end

      def resource(name, **meta, &block)
        @registry.register_tool(
          name,
          meta.merge(type: :resource),
          Adapters::ProcAdapter.new(block)
        )
      end

      def call(json)
        request = Protocol::JSONRPC.parse(json)
        handler = @registry.find(request.method)
        result = handler.call(request.params)

        Protocol::JSONRPC.response(
          id: request.id,
          result: result
        )
      rescue => e
        Protocol::JSONRPC.error(
          id: request&.id,
          code: -32603,
          message: e.message
        )
      end
    end
  end
end
