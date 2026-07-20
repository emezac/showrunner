# frozen_string_literal: true

class RenderTiming < ApplicationRecord
  belongs_to :project

  validates :n_shots, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :resolution, presence: true
  validates :total_seconds, presence: true, numericality: { greater_than_or_equal_to: 0 }
end
