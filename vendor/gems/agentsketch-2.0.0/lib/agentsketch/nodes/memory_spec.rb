# frozen_string_literal: true

module AgentSketch
  module Nodes
    # Describes the memory strategy for an agent.
    MemorySpec = Data.define(
      :strategy, # Symbol :none | :sliding_window | :full | :summarize | :episodic
      :options   # Hash   — size:, every:, model:, store:, top_k:, ttl:
    )
  end
end
