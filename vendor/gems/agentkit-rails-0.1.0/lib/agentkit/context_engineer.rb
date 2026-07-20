# frozen_string_literal: true

module Agentkit
  # Assembles the full context string passed to the LLM.
  # Combines kernel-level context (agent identity, HITL mode, domain config)
  # with domain-injected context (via ApplicationAgent#domain_context hook).
  #
  # The domain_context hook is intentionally empty in the kernel and meant
  # to be overridden by domain ApplicationAgent subclasses.
  #
  # Built context order (appended to system prompt):
  #   1. Kernel identity block  — who the agent is, domain, entity
  #   2. HITL rules block       — how the agent should handle actions
  #   3. Memory block           — relevant past memories (from recall!)
  #   4. Domain context block   — injected by domain_context hook
  class ContextEngineer
    # Build the full system context for an agent.
    #
    # @param agent       [Agentkit::ApplicationAgent] the calling agent instance
    # @param query       [String, nil] optional semantic query for memory recall
    # @param memories    [Array<Agentkit::Memory>] pre-fetched memories (optional)
    # @param extra       [String, nil] arbitrary extra context string
    # @return [String] assembled context
    def self.build(agent:, query: nil, memories: [], extra: nil)
      cfg = Agentkit.config
      parts = []

      # ── 1. Kernel identity ─────────────────────────────────────────────────
      parts << <<~IDENTITY
        ## Agent Identity
        You are #{agent.class.name}, an AI agent running inside #{cfg.domain_name}.
        Primary domain entity: #{cfg.primary_entity}.
        Current time: #{Time.current.strftime("%Y-%m-%d %H:%M %Z")}.
      IDENTITY

      # ── 2. HITL rules ─────────────────────────────────────────────────────
      hitl_description = case cfg.hitl_level
      when :strict
        "STRICT: Never take irreversible actions autonomously. " \
        "Always create a suggestion and wait for human approval."
      when :advisory
        "ADVISORY: You may provide recommendations proactively. " \
        "High-impact actions still require human confirmation."
      when :silent
        "SILENT: Log your reasoning and suggestions internally. " \
        "Do not prompt the user unless explicitly asked."
      end

      parts << <<~HITL
        ## Autonomy Level
        #{hitl_description}
      HITL

      # ── 3. Relevant memories ───────────────────────────────────────────────
      if memories.any?
        memory_text = memories.map.with_index(1) do |m, i|
          "[#{i}] (#{m.memory_type}, confidence: #{m.confidence}) #{m.content}"
        end.join("\n")

        parts << <<~MEMORIES
          ## Relevant Past Knowledge
          #{memory_text}
        MEMORIES
      end

      # ── 4. Domain context (hook) ───────────────────────────────────────────
      domain_ctx = agent.domain_context
      if domain_ctx.present?
        parts << <<~DOMAIN
          ## Domain Context
          #{domain_ctx}
        DOMAIN
      end

      # ── 5. Extra context ───────────────────────────────────────────────────
      parts << extra if extra.present?

      parts.join("\n").strip
    end
  end
end
