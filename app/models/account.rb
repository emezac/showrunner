# frozen_string_literal: true

class Account < ApplicationRecord
  # agentkit-rails associations will be loaded dynamically,
  # or we can define any required validations here.
  validates :name, presence: true
end
