# frozen_string_literal: true

module Agentkit
  # JSON API for managing HITL suggestions.
  # Mounted at /agentkit/suggestions.
  # Domain apps authenticate via their own auth system (before_action in ApplicationController).
  class SuggestionsController < ActionController::API
    before_action :authenticate_user!
    before_action :set_suggestion, only: %i[approve reject snooze]

    # GET /agentkit/suggestions
    def index
      suggestions = Agentkit::HITLEngine.pending_for(
        user:     current_user,
        priority: params[:priority]
      )
      render json: serialize_many(suggestions)
    end

    # POST /agentkit/suggestions/:id/approve
    def approve
      suggestion = Agentkit::HITLEngine.approve(@suggestion.id, user: current_user)
      render json: serialize(suggestion)
    end

    # POST /agentkit/suggestions/:id/reject
    def reject
      suggestion = Agentkit::HITLEngine.reject(
        @suggestion.id,
        user:   current_user,
        reason: params[:reason]
      )
      render json: serialize(suggestion)
    end

    # POST /agentkit/suggestions/:id/snooze
    def snooze
      until_time = params[:until] ? Time.parse(params[:until]) : 24.hours.from_now
      suggestion = Agentkit::HITLEngine.snooze(
        @suggestion.id,
        user:       current_user,
        until_time: until_time
      )
      render json: serialize(suggestion)
    end

    private

    def set_suggestion
      @suggestion = Agentkit::AgentSuggestion.find_by!(
        id:   params[:id],
        user: current_user
      )
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Suggestion not found" }, status: :not_found
    end

    def serialize(suggestion)
      {
        id:              suggestion.id,
        type:            suggestion.suggestion_type,
        title:           suggestion.title,
        description:     suggestion.description,
        status:          suggestion.status,
        priority:        suggestion.priority,
        source_agent:    suggestion.source_agent,
        suggestable_id:  suggestion.suggestable_id,
        suggestable_type: suggestion.suggestable_type,
        payload:         suggestion.payload,
        created_at:      suggestion.created_at,
        resolved_at:     suggestion.resolved_at
      }
    end

    def serialize_many(suggestions)
      suggestions.map { |s| serialize(s) }
    end

    # ─── Auth ─────────────────────────────────────────────────────────────────
    # Domain apps override this by reopening the controller or mounting it
    # inside their authenticated namespace.
    def authenticate_user!
      # Stub — domain apps implement their own authentication.
      # Example in domain ApplicationController:
      #   before_action :require_login
    end

    def current_user
      raise NotImplementedError, "Domain must implement current_user helper"
    end
  end
end
