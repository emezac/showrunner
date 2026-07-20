# frozen_string_literal: true

module AgentSketch
  module Nodes
    # Describes the retry policy for an agent step.
    RetryPolicy = Data.define(
      :max,     # Integer — maximum extra attempts (0 = no retry)
      :backoff, # Symbol :linear | :exponential | :constant
      :on       # Array<Symbol> — error types to retry on (empty = all)
    ) do
      def to_aflow_config
        # Aflow uses a single integer for retry count
        max
      end
    end

    # Default — no retries
    DEFAULT_RETRY = RetryPolicy.new(max: 0, backoff: :linear, on: [])
  end
end
