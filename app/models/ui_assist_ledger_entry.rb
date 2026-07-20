# frozen_string_literal: true

class UiAssistLedgerEntry < ApplicationRecord
  belongs_to :project

  validates :tokens_used, presence: true, numericality: { greater_than_or_equal_to: 0 }
end
