# frozen_string_literal: true

module Agentkit
  # Analyzes agent logs, consolidated memories, and usage patterns to
  # propose improvements (new fields, agents, DSLs, refactors) as EvolutionItem records.
  #
  # Called by EvolutionReportJob on a configured schedule.
  class EvolutionSuggesterAgent < ApplicationAgent
    MAX_SUGGESTIONS_PER_RUN = 3

    def call
      context_data  = gather_context
      suggestions   = generate_suggestions(context_data)
      create_evolution_items(suggestions)
    end

    private

    def gather_context
      recent_failures = Agentkit::AgentLog
        .failed
        .where(created_at: 7.days.ago..)
        .group(:agent_name)
        .count

      pending_suggestions = Agentkit::AgentSuggestion
        .where(user: current_user, status: "pending")
        .count

      insights = Agentkit::Memory
        .where(user: current_user, memory_type: "insight", status: "consolidated")
        .order(created_at: :desc)
        .limit(10)
        .pluck(:content)

      {
        domain:              Agentkit.config.domain_name,
        primary_entity:      Agentkit.config.primary_entity,
        recent_failures:     recent_failures,
        pending_suggestions: pending_suggestions,
        recent_insights:     insights
      }
    end

    def generate_suggestions(ctx)
      prompt = <<~PROMPT
        You are an expert Rails architect analyzing a domain application to propose improvements.

        Domain: #{ctx[:domain]}
        Primary entity: #{ctx[:primary_entity]}
        Agent failures (last 7 days): #{ctx[:recent_failures].to_json}
        Pending HITL suggestions: #{ctx[:pending_suggestions]}

        Recent synthesized insights:
        #{ctx[:recent_insights].map.with_index(1) { |i, n| "#{n}. #{i}" }.join("\n")}

        Propose up to #{MAX_SUGGESTIONS_PER_RUN} specific improvements. For each, output JSON with:
        - item_type: "new_field" | "new_agent" | "new_dsl" | "refactor" | "new_skill"
        - title: short descriptive title
        - description: what to build and why
        - rationale: evidence from the data above
        - priority: "low" | "medium" | "high"

        Output a JSON array only, no markdown, no preamble.
      PROMPT

      raw = chat(prompt, model: :complex)
      JSON.parse(raw)
    rescue JSON::ParserError => e
      Rails.logger.warn("[AgentKit::EvolutionSuggesterAgent] JSON parse failed: #{e.message}")
      []
    end

    def create_evolution_items(suggestions)
      suggestions.first(MAX_SUGGESTIONS_PER_RUN).each do |s|
        Agentkit::EvolutionItem.create!(
          item_type:   s["item_type"],
          title:       s["title"],
          description: s["description"],
          rationale:   s["rationale"],
          priority:    s["priority"] || "medium",
          status:      "pending",
          user:        current_user
        )
        agent_log(event: "suggested", payload: { title: s["title"], type: s["item_type"] })
      end
    end
  end
end
