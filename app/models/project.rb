# frozen_string_literal: true

class Project < ApplicationRecord
  include Agentkit::AgentTriggerable

  belongs_to :user
  has_many :shots, dependent: :destroy
  has_many :render_timings, dependent: :destroy
  has_many :ui_assist_ledger_entries, dependent: :destroy

  validates :prompt, presence: true, length: { maximum: 100000 }
  validates :status, presence: true

  # The agent runner looks for triggering_user to scope memory
  def triggering_user
    user
  end

  # Helper to access fields from the direction jsonb column
  def director_style
    direction["director_influence"]
  end

  def camera_style
    direction["camera_style"]
  end

  def color_grading
    direction["color_grade"]
  end

  def music_genre
    direction["music_style"]
  end

  def narrator_voice
    direction["voice_style"]
  end
end
