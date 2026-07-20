# frozen_string_literal: true

module Agentkit
  # Generic Sidekiq job that instantiates any agent class and calls it
  # with a domain record. Used by AgentTriggerable for async triggers.
  #
  # Arguments:
  #   agent_class_name  [String] Fully-qualified agent class name
  #   record_class_name [String] ActiveRecord class name
  #   record_id         [Integer] Primary key of the domain record
  #   user_id           [Integer, nil] User to associate with the agent run
  #
  # Example (called by AgentTriggerable):
  #   Agentkit::AgentWorkerJob.perform_later(
  #     "CasoIntakeAgent", "Caso", 42, current_user.id
  #   )
  class AgentWorkerJob < ApplicationJob
    queue_as :agentkit_agents

    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    def perform(agent_class_name, record_class_name, record_id, user_id = nil)
      agent_class  = agent_class_name.constantize
      record_class = record_class_name.constantize
      record       = record_class.find(record_id)
      user         = user_id ? User.find_by(id: user_id) : nil

      agent = agent_class.new(user: user)
      agent.call(record)

      Rails.logger.info(
        "[AgentKit::AgentWorkerJob] #{agent_class_name} completed for " \
        "#{record_class_name}##{record_id}"
      )
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.warn("[AgentKit::AgentWorkerJob] Record not found: #{e.message}")
      # Don't retry — record was deleted
    end
  end
end
