# frozen_string_literal: true

module Agentkit
  # Base class for all agents in AgentKit Rails.
  #
  # Every domain agent inherits from this class (via the domain's own
  # ApplicationAgent which inherits Agentkit::ApplicationAgent).
  #
  # Public interface available to all agents:
  #   chat(prompt, model: nil, system: nil)
  #   memorize!(content, tags:, type: "observation", confidence: 0.7)
  #   recall!(query, k: 5, threshold: 0.3, types: nil)
  #   suggest!(type:, title:, description:, priority: "medium", payload: {})
  #   build_context(query: nil)
  #   domain_context  → override in domain ApplicationAgent
  #   agent_log(event:, payload: {})
  #
  # Usage:
  #   class CasoIntakeAgent < ApplicationAgent
  #     def call(caso)
  #       memories = recall!("intake de caso #{caso.practice_area}")
  #       ctx      = build_context(query: caso.brief)
  #       result   = chat("Analiza este caso: #{caso.brief}", system: ctx)
  #       memorize!(result, tags: ["intake", caso.practice_area], type: "observation")
  #       suggest!(type: "case_review", title: "Revisión inicial", description: result)
  #     end
  #   end
  class ApplicationAgent
    attr_accessor :current_user, :current_account

    def initialize(user: nil, account: nil)
      @current_user    = user
      @current_account = account
    end

    # ─── LLM call ─────────────────────────────────────────────────────────────

    # Send a prompt to the LLM and return the text response.
    # @param prompt  [String]          The user-facing prompt.
    # @param model   [Symbol, String]  Profile symbol or explicit model string.
    #                                  Nil → uses default model.
    # @param system  [String, nil]     System prompt override.
    def chat(prompt, model: nil, system: nil)
      model_str = Agentkit::ModelRouter.resolve(model)
      system_prompt = system || build_context

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      response = RubyLLM.chat(
        model:    model_str,
        messages: [{ role: "user", content: prompt }],
        system:   system_prompt
      )

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

      agent_log(
        event:   "completed",
        payload: {
          model:        model_str,
          tokens:       response.usage&.total_tokens,
          duration_ms:  duration_ms,
          prompt_preview: prompt.to_s.first(500)
        }
      )

      response.content
    rescue StandardError => e
      agent_log(event: "failed", payload: { error: e.message, model: model_str })
      raise
    end

    # ─── Memory ───────────────────────────────────────────────────────────────

    # Store a memory and schedule async embedding.
    # @return [Agentkit::Memory]
    def memorize!(content, tags: [], type: "observation", confidence: 0.7)
      Agentkit::MemoryEngine.store(
        content:      content,
        user:         current_user,
        account:      current_account,
        source_agent: self.class.name,
        tags:         Array(tags),
        memory_type:  type,
        confidence:   confidence
      )
    end

    # Semantic search over stored memories.
    # @return [Array<Agentkit::Memory>]
    def recall!(query, k: 5, threshold: 0.3, types: nil)
      Agentkit::MemoryEngine.search(
        query:    query,
        user:     current_user,
        account:  current_account,
        k:        k,
        threshold: threshold,
        types:    types
      )
    end

    # ─── HITL ─────────────────────────────────────────────────────────────────

    # Create a Human-in-the-Loop suggestion.
    # @param suggestable [ActiveRecord::Base, nil] the domain object this relates to
    # @return [Agentkit::AgentSuggestion]
    def suggest!(type:, title:, description:, priority: "medium", payload: {}, suggestable: nil)
      Agentkit::HITLEngine.suggest!(
        type:         type,
        title:        title,
        description:  description,
        priority:     priority,
        source_agent: self.class.name,
        user:         current_user,
        payload:      payload,
        suggestable:  suggestable
      )
    end

    # ─── Context ──────────────────────────────────────────────────────────────

    # Assembles the full system context string for this agent.
    # @param query [String, nil] Semantic query for memory injection
    # @return [String]
    def build_context(query: nil)
      memories = query ? recall!(query) : []
      Agentkit::ContextEngineer.build(agent: self, query: query, memories: memories)
    end

    # Hook — override in domain ApplicationAgent to inject domain-specific context.
    # Return a string that will be appended to the system prompt.
    #
    # Example (in domain app/agents/application_agent.rb):
    #   def domain_context
    #     "Current firm: #{Current.account&.name}. " \
    #     "Active cases: #{Caso.active.count}."
    #   end
    def domain_context
      ""
    end

    # ─── Logging ──────────────────────────────────────────────────────────────

    def agent_log(event:, payload: {})
      Agentkit::AgentLog.create!(
        agent_name:    self.class.name,
        event_type:    event.to_s,
        prompt_preview: payload[:prompt_preview]&.first(500),
        tokens_used:   payload[:tokens],
        cost_usd:      payload[:cost_usd],
        duration_ms:   payload[:duration_ms],
        status:        event.to_s,
        payload:       payload.except(:prompt_preview, :tokens, :cost_usd, :duration_ms),
        user:          current_user
      )
    rescue StandardError => e
      # Never let logging failures crash the agent
      Rails.logger.warn("[AgentKit] agent_log failed: #{e.message}")
    end
  end
end
