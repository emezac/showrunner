# frozen_string_literal: true

module AgentSketch
  module Memory
    # Base class for all memory strategies.
    class Base
      def initialize(opts = {})
        @opts     = opts
        @agent_id = opts[:agent_id]
      end

      # @return [String] context to inject into the system prompt
      def build_context(_current_input)
        ""
      end

      # Persist an interaction to memory.
      def save(_input, _output)
        # no-op by default
      end
    end

    # Stateless — no history is kept or injected.
    class None < Base; end
  end
end
