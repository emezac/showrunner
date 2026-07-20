# frozen_string_literal: true

module Agentkit
  # Represents a single unit of semantic memory for an agent.
  # Vectors are stored via pgvector and indexed with IVFFlat cosine ops.
  #
  # Lifecycle: raw → (EmbeddingJob) → embedded → (DreamingJob) → consolidated | archived
  #
  # memory_type:
  #   "observation"  — factual event or interaction observed
  #   "pattern"      — recurring trend identified across observations
  #   "insight"      — synthesized understanding (usually from DreamingAgent)
  class Memory < ApplicationRecord
    self.table_name = "agentkit_memories"

    # pgvector
    has_neighbors :embedding

    # ─── Associations ─────────────────────────────────────────────────────────
    belongs_to :user
    belongs_to :account, optional: true

    # ─── Validations ──────────────────────────────────────────────────────────
    validates :content,     presence: true
    validates :memory_type, inclusion: { in: %w[observation pattern insight] }
    validates :status,      inclusion: { in: %w[raw embedded consolidated archived] }
    validates :confidence,  numericality: { in: 0.0..1.0 }

    # ─── Scopes ───────────────────────────────────────────────────────────────
    scope :raw,          -> { where(status: "raw") }
    scope :embedded,     -> { where(status: "embedded") }
    scope :consolidated, -> { where(status: "consolidated") }
    scope :archived,     -> { where(status: "archived") }
    scope :active,       -> { where(status: %w[embedded consolidated]) }
    scope :by_agent,     ->(name) { where(source_agent: name) }
    scope :tagged,       ->(tag)  { where("tags @> ?", [tag].to_json) }
    scope :high_confidence, -> { where("confidence >= 0.8") }

    # ─── Callbacks ────────────────────────────────────────────────────────────
    before_create :set_defaults

    private

    def set_defaults
      self.tags   ||= []
      self.status ||= "raw"
    end
  end
end
