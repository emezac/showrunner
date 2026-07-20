# frozen_string_literal: true

module Agentkit
  # Nightly cron job that runs DreamingAgent for each active user.
  # Scheduled via config/sidekiq_schedule.yml.
  #
  # What it does:
  #   1. Find all users with embedded (un-consolidated) memories
  #   2. Dispatch DreamingAgent for each user to cluster, synthesize, and consolidate
  #   3. Optionally auto-consolidate high-confidence clusters
  class DreamingJob < ApplicationJob
    queue_as :agentkit_dreaming

    # No retries — if dreaming fails one night, it runs again tomorrow.
    discard_on StandardError do |job, error|
      Rails.logger.error("[AgentKit::DreamingJob] Failed: #{error.message}")
    end

    def perform
      Rails.logger.info("[AgentKit::DreamingJob] Dreaming cycle started at #{Time.current}")

      users_with_raw_memories.each do |user|
        agent = Agentkit::DreamingAgent.new(user: user)
        agent.call
      rescue StandardError => e
        Rails.logger.error(
          "[AgentKit::DreamingJob] DreamingAgent failed for user #{user.id}: #{e.message}"
        )
      end

      Rails.logger.info("[AgentKit::DreamingJob] Dreaming cycle complete.")
    end

    private

    def users_with_raw_memories
      User.joins(:agentkit_memories)
          .where(agentkit_memories: { status: "embedded" })
          .distinct
    end
  end
end
