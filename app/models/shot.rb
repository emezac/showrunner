# frozen_string_literal: true

class Shot < ApplicationRecord
  belongs_to :project
  belongs_to :variant_of, class_name: "Shot", optional: true
  has_many :variants, class_name: "Shot", foreign_key: "variant_of_id", dependent: :nullify

  validates :shot_id, presence: true
  validates :duration, presence: true, numericality: { greater_than: 0 }
end
