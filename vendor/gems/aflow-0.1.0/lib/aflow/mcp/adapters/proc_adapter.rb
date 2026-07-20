module Aflow
  module MCP
    module Adapters
      class ProcAdapter
        def initialize(block)
          @block = block
        end

        def call(params)
          @block.call(params)
        end
      end
    end
  end
end
