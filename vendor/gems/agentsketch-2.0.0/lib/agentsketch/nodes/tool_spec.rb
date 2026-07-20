# frozen_string_literal: true

module AgentSketch
  module Nodes
    # Describes a tool assigned to an agent.
    ToolSpec = Data.define(
      :name,    # Symbol  — built-in name or custom name
      :options, # Hash    — provider, max_results, top_k, etc.
      :block    # Proc | nil — for inline custom tools
    )
  end
end
