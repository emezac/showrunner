# frozen_string_literal: true

module Agentkit
  # Runs in :advisory HITL mode to auto-apply suggestions after a delay.
  # Scheduled by HITLEngine.suggest! when hitl_level == :advisory.
  class AutoApplySuggestionJob < ApplicationJob
    queue_as :agentkit_hitl

    def perform(suggestion_id)
      suggestion = Agentkit::AgentSuggestion.find_by(id: suggestion_id, status: "pending")
      return unless suggestion # Already resolved by human — skip

      suggestion.update!(
        status:      "auto_applied",
        resolved_at: Time.current,
        payload:     suggestion.payload.merge("auto_applied" => true)
      )

      Rails.logger.info(
        "[AgentKit::AutoApplySuggestionJob] Auto-applied suggestion #{suggestion_id}."
      )
    end
  end
end
