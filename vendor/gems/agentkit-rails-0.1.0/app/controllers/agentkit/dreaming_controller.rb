# frozen_string_literal: true

module Agentkit
  # Admin-facing controller for inspecting and manually triggering dreaming cycles.
  # Mounted at /agentkit/dreaming.
  class DreamingController < ActionController::API
    before_action :authenticate_user!

    # GET /agentkit/dreaming/status
    def status
      last_run = Agentkit::AgentLog
        .for_agent("Agentkit::DreamingAgent")
        .where(event_type: "completed")
        .order(created_at: :desc)
        .first

      raw_count  = Agentkit::Memory.where(user: current_user, status: "embedded").count
      cons_count = Agentkit::Memory.where(user: current_user, status: "consolidated").count

      render json: {
        last_run_at:           last_run&.created_at,
        last_run_duration_ms:  last_run&.duration_ms,
        embedded_memories:     raw_count,
        consolidated_memories: cons_count,
        next_scheduled:        next_cron_time,
        config: {
          cron:      Agentkit.config.dreaming_cron,
          threshold: Agentkit.config.dreaming_threshold,
          auto_consolidate: Agentkit.config.auto_consolidate
        }
      }
    end

    # POST /agentkit/dreaming/run
    def run_now
      Agentkit::DreamingJob.perform_later
      render json: { status: "queued", message: "DreamingJob enqueued." }
    end

    private

    def next_cron_time
      # Parse cron string to estimate next run — simplified
      Agentkit.config.dreaming_cron
    end

    def authenticate_user!
      # Domain implements this
    end

    def current_user
      raise NotImplementedError, "Domain must implement current_user"
    end
  end
end
