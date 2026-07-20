# frozen_string_literal: true

module Agentkit
  # An item proposed by EvolutionSuggesterAgent for improving the domain app.
  # Can lead to CodeGeneration records when accepted.
  #
  # item_type: new_field | new_agent | new_dsl | refactor | new_skill
  # status:    pending | accepted | in_progress | done | rejected
  class EvolutionItem < ApplicationRecord
    self.table_name = "agentkit_evolution_items"

    # ─── Associations ─────────────────────────────────────────────────────────
    belongs_to :user
    has_many :code_generations,
             class_name:  "Agentkit::CodeGeneration",
             foreign_key: :evolution_item_id,
             dependent:   :destroy

    # ─── Validations ──────────────────────────────────────────────────────────
    validates :title,     presence: true
    validates :item_type, inclusion: { in: %w[new_field new_agent new_dsl refactor new_skill] }
    validates :status,    inclusion: { in: %w[pending accepted in_progress done rejected] }
    validates :priority,  inclusion: { in: %w[low medium high critical], allow_blank: true }

    # ─── Scopes ───────────────────────────────────────────────────────────────
    scope :pending,     -> { where(status: "pending") }
    scope :accepted,    -> { where(status: "accepted") }
    scope :in_progress, -> { where(status: "in_progress") }
    scope :done,        -> { where(status: "done") }
    scope :recent,      -> { order(created_at: :desc) }

    # ─── State machine helpers ────────────────────────────────────────────────
    def accept!
      update!(status: "accepted")
      Agentkit::AgentWorkerJob.perform_later("Agentkit::CodificadorAgent", id, user_id)
    end

    def reject!(reason: nil)
      meta = reason ? { "rejection_reason" => reason } : {}
      update!(status: "rejected")
    end

    def start_coding!
      update!(status: "in_progress")
    end

    def complete!
      update!(status: "done")
    end
  end
end
