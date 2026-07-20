# frozen_string_literal: true

module AgentSketch
  module Nodes
    # Immutable value object representing a fully-declared agent.
    # Built by Builder, consumed by Planner and AgentStep.
    AgentDefinition = Data.define(
      :name,          # Symbol
      :model,         # String  e.g. "gpt-4o"
      :provider,      # Symbol | nil  — inferred by ruby_llm when nil
      :role,          # String
      :goal,          # String | nil
      :persona,       # String | nil
      :temperature,   # Float
      :max_tokens,    # Integer | nil
      :tools,         # Array<ToolSpec>
      :memory,        # MemorySpec
      :retry_policy,  # RetryPolicy
      :timeout,       # Integer seconds | nil
      :fallback,      # Symbol (agent_id) | nil
      :output_format, # Symbol :text | :markdown | :json | :structured
      :output_schema  # Hash | nil  — only for :structured
    ) do
      def vision_capable_models
        %w[gpt-4o gpt-4-vision claude-opus-4-5 claude-sonnet-4-6
           claude-haiku-4-5 gemini-1.5-pro gemini-1.5-flash]
      end

      def supports_vision?
        vision_capable_models.any? { |m| model.start_with?(m) }
      end
    end
  end
end
