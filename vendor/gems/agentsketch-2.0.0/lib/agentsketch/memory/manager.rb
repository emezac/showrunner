# frozen_string_literal: true

module AgentSketch
  module Memory
    # Factory that instantiates the right memory strategy from a MemorySpec.
    module Manager
      STRATEGIES = {
        none:           -> (opts, **kw) { None.new(opts.merge(kw)) },
        sliding_window: -> (opts, **kw) { SlidingWindow.new(opts.merge(kw)) },
        full:           -> (opts, **kw) { Full.new(opts.merge(kw)) },
        summarize:      -> (opts, **kw) { Summarize.new(opts.merge(kw)) },
        episodic:       -> (opts, **kw) { Episodic.new(opts.merge(kw)) },
      }.freeze

      # @param spec     [Nodes::MemorySpec]
      # @param agent_id [Symbol]
      # @return [Memory::Base]
      def self.for_spec(spec, agent_id:)
        factory = STRATEGIES[spec.strategy] || STRATEGIES[:none]
        factory.call(spec.options, agent_id: agent_id)
      end
    end
  end
end
