# frozen_string_literal: true

module Agentkit
  # Scheduled job that runs EvolutionSuggesterAgent to surface improvement ideas.
  # Frequency configured via Agentkit.config or sidekiq_schedule.yml.
  class EvolutionReportJob < ApplicationJob
    queue_as :agentkit_evolution

    discard_on StandardError do |job, error|
      Rails.logger.error("[AgentKit::EvolutionReportJob] Failed: #{error.message}")
    end

    def perform
      Rails.logger.info("[AgentKit::EvolutionReportJob] Evolution report started.")

      # Run for each admin user (or a single configured account)
      admin_users.each do |user|
        Agentkit::EvolutionSuggesterAgent.new(user: user).call
      rescue StandardError => e
        Rails.logger.error(
          "[AgentKit::EvolutionReportJob] Failed for user #{user.id}: #{e.message}"
        )
      end
    end

    private

    def admin_users
      # Assumes the domain User model has a role or admin flag.
      # Domains can override this by subclassing EvolutionReportJob.
      if User.respond_to?(:admins)
        User.admins
      elsif User.column_names.include?("role")
        User.where(role: "admin")
      else
        User.limit(1)
      end
    end
  end
end
