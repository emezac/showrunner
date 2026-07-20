require_relative "mcp/registry"
require_relative "mcp/adapters/proc_adapter"
require_relative "mcp/adapters/flow_adapter"
require_relative "mcp/protocol/json_rpc"
require_relative "mcp/server"
require_relative "mcp/transport/stdio"

module Aflow
  module MCP
    def self.server(&block)
      Server.new.tap do |s|
        s.instance_eval(&block) if block_given?
      end
    end
  end
end
