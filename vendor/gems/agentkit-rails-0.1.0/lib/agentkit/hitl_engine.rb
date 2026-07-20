# frozen_string_literal: true

module Agentkit
  # Manages the Human-in-the-Loop lifecycle for agent suggestions.
  #
  # Agents call suggest! to create a pending AgentSuggestion.
  # Humans then approve, reject, or snooze via the UI.
  # In :silent mode, suggestions are logged only.
  # In :advisory mode, suggestions auto-apply after a configurable delay.
  # In :strict mode, no action is taken without explicit human approval.
  #
  # Usage:
  #   Agentkit::HITLEngine.suggest!(
  #     type:         "scope_creep",
  #     title:        "Posible scope creep detectado",
  #     description:  "El brief ha cambiado un 40% respecto al original.",
  #     priority:     "high",
  #     source_agent: "ScopeCreepDetectionAgent",
  #     user:         current_user,
  #     suggestable:  proyecto
  #   )
  class HITLEngine
    # ─── Create ───────────────────────────────────────────────────────────────

    def self.suggest!(type:, title:, description:, source_agent:, user:,
                      priority: "medium", payload: {}, suggestable: nil)
      level = Agentkit.config.hitl_level

      suggestion = Agentkit::AgentSuggestion.create!(
        suggestion_type: type,
        title:           title,
        description:     description,
        priority:        priority,
        source_agent:    source_agent,
        user:            user,
        suggestable:     suggestable,
        payload:         payload,
        status:          level == :silent ? "silenced" : "pending"
      )

      # In advisory mode, schedule auto-apply after configured delay
      if level == :advisory
        auto_apply_delay = Agentkit.config.respond_to?(:advisory_auto_apply_delay) ?
          Agentkit.config.advisory_auto_apply_delay : 24.hours
        Agentkit::AutoApplySuggestionJob.perform_in(auto_apply_delay, suggestion.id)
      end

      suggestion
    end

    # ─── Resolve ──────────────────────────────────────────────────────────────

    def self.approve(suggestion_id, user:)
      suggestion = find_suggestion!(suggestion_id, user)
      suggestion.update!(status: "accepted", resolved_at: Time.current)
      yield(suggestion) if block_given?
      suggestion
    end

    def self.reject(suggestion_id, user:, reason: nil)
      suggestion = find_suggestion!(suggestion_id, user)
      payload = suggestion.payload.merge("rejection_reason" => reason).compact
      suggestion.update!(status: "rejected", resolved_at: Time.current, payload: payload)
      suggestion
    end

    def self.snooze(suggestion_id, user:, until_time: 24.hours.from_now)
      suggestion = find_suggestion!(suggestion_id, user)
      suggestion.update!(
        status:      "snoozed",
        payload:     suggestion.payload.merge("snoozed_until" => until_time.iso8601)
      )
      suggestion
    end

    # ─── Query ────────────────────────────────────────────────────────────────

    def self.pending_for(user:, priority: nil)
      scope = Agentkit::AgentSuggestion.where(user: user, status: "pending")
      scope = scope.where(priority: priority) if priority
      scope.order(created_at: :desc)
    end

    def self.pending_count_for(user)
      Agentkit::AgentSuggestion.where(user: user, status: "pending").count
    end

    # ─── Private ──────────────────────────────────────────────────────────────

    def self.find_suggestion!(id, user)
      Agentkit::AgentSuggestion.find_by!(id: id, user: user, status: "pending")
    rescue ActiveRecord::RecordNotFound
      raise ArgumentError, "Suggestion #{id} not found or already resolved."
    end
    private_class_method :find_suggestion!
  end
end
