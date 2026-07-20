# frozen_string_literal: true

module Agentkit
  # A Human-in-the-Loop suggestion created by an agent.
  # The human reviews and approves, rejects, or snoozes it.
  #
  # suggestion_type examples: scope_creep | risk | communication | contract |
  #                            case_strategy | follow_up | optimization
  #
  # status lifecycle: pending → accepted | rejected | snoozed | silenced
  class AgentSuggestion < ApplicationRecord
    self.table_name = "agentkit_agent_suggestions"

    # ─── Associations ─────────────────────────────────────────────────────────
    belongs_to :user
    belongs_to :suggestable, polymorphic: true, optional: true

    # ─── Validations ──────────────────────────────────────────────────────────
    validates :suggestion_type, presence: true
    validates :title,           presence: true
    validates :source_agent,    presence: true
    validates :status,          inclusion: {
      in: %w[pending accepted rejected snoozed silenced auto_applied]
    }
    validates :priority, inclusion: { in: %w[low medium high critical] }

    # ─── Scopes ───────────────────────────────────────────────────────────────
    scope :pending,   -> { where(status: "pending") }
    scope :resolved,  -> { where(status: %w[accepted rejected auto_applied]) }
    scope :critical,  -> { where(priority: "critical") }
    scope :high,      -> { where(priority: %w[high critical]) }
    scope :for_type,  ->(t) { where(suggestion_type: t) }
    scope :recent,    -> { order(created_at: :desc) }

    # ─── Callbacks ────────────────────────────────────────────────────────────
    after_update :broadcast_status_change, if: :saved_change_to_status?

    # ─── Helpers ──────────────────────────────────────────────────────────────
    def resolved?
      %w[accepted rejected auto_applied].include?(status)
    end

    def pending?
      status == "pending"
    end

    def high_priority?
      %w[high critical].include?(priority)
    end

    private

    def broadcast_status_change
      # Hotwire Turbo Stream broadcast (if ActionCable is configured)
      return unless defined?(Turbo::StreamsChannel)

      Turbo::StreamsChannel.broadcast_replace_to(
        "agentkit_suggestions_#{user_id}",
        target:  "suggestion_#{id}",
        partial: "agentkit/suggestions/suggestion",
        locals:  { suggestion: self }
      )
    rescue StandardError => e
      Rails.logger.warn("[AgentKit] Broadcast failed: #{e.message}")
    end
  end
end
