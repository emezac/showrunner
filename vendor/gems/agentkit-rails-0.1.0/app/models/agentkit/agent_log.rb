# frozen_string_literal: true

module Agentkit
  # Immutable audit log of every agent action.
  # Written by ApplicationAgent#agent_log — never modified after creation.
  #
  # event_type values:
  #   started | completed | failed | memorized | suggested | recalled
  class AgentLog < ApplicationRecord
    self.table_name = "agentkit_agent_logs"

    # ─── Associations ─────────────────────────────────────────────────────────
    belongs_to :user, optional: true

    # ─── Validations ──────────────────────────────────────────────────────────
    validates :agent_name, presence: true
    validates :event_type, inclusion: {
      in: %w[started completed failed memorized suggested recalled],
      allow_blank: true
    }

    # ─── Scopes ───────────────────────────────────────────────────────────────
    scope :for_agent,   ->(name) { where(agent_name: name) }
    scope :failed,      -> { where(status: "failed") }
    scope :recent,      -> { order(created_at: :desc) }
    scope :today,       -> { where(created_at: Date.current.all_day) }

    # ─── Computed ─────────────────────────────────────────────────────────────
    def self.total_cost_usd(scope = all)
      scope.sum(:cost_usd).round(6)
    end

    def self.avg_duration_ms(scope = all)
      scope.average(:duration_ms)&.round(1)
    end
  end
end
