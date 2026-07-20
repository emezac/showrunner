# frozen_string_literal: true

module AgentSketch
  # Wraps the result of a workflow run.
  # Provides access to the final output, full trace, cost summary and errors.
  RunResult = Data.define(:output, :trace, :cost, :success, :errors) do
    # @return [Boolean]
    def success?
      success
    end

    # @return [Boolean]
    def failure?
      !success
    end

    # Shorthand to check if there were any errors
    def errors?
      !errors.empty?
    end

    # Serialize the trace to a hash for persistence (DB / JSONL)
    # @return [Hash, nil]
    def trace_hash
      trace&.to_h
    end

    # Pretty-print a cost summary
    # @return [String]
    def cost_summary
      t = cost[:tokens]
      "$#{"%.6f" % cost[:usd]} | #{t[:total]} tokens " \
        "(#{t[:prompt]} prompt + #{t[:completion]} completion)"
    end

    def to_s
      output.to_s
    end
  end
end
