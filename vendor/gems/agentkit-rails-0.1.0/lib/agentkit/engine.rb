# frozen_string_literal: true

require "rails/engine"

module Agentkit
  class Engine < ::Rails::Engine
    isolate_namespace Agentkit

    # ─── Eager load paths ────────────────────────────────────────────────────
    config.eager_load_paths += %W[
      #{root}/lib
      #{root}/app/agents
      #{root}/app/jobs
      #{root}/app/models
      #{root}/app/concerns
      #{root}/app/controllers
    ]

    # ─── Autoload paths ───────────────────────────────────────────────────────
    config.autoload_paths += %W[
      #{root}/lib
      #{root}/app/agents
      #{root}/app/jobs
      #{root}/app/models
      #{root}/app/concerns
      #{root}/app/controllers
    ]

    # ─── Migrations ───────────────────────────────────────────────────────────
    initializer "agentkit.migrations" do |app|
      unless app.root.to_s == root.to_s
        config.paths["db/migrate"].expanded.each do |path|
          app.config.paths["db/migrate"] << path
        end
      end
    end

    # ─── Routes ───────────────────────────────────────────────────────────────
    initializer "agentkit.routes" do
      config.after_initialize do
        # Ensure engine routes are loaded
      end
    end

    # ─── Sidekiq cron ────────────────────────────────────────────────────────
    initializer "agentkit.sidekiq_cron", after: :load_config_initializers do
      if defined?(Sidekiq) && defined?(Sidekiq::Cron)
        cron_file = root.join("config", "sidekiq_schedule.yml")
        if cron_file.exist?
          schedule = YAML.load_file(cron_file)
          Sidekiq::Cron::Job.load_from_hash(schedule)
        end
      end
    end

    # ─── pgvector extension check ─────────────────────────────────────────────
    initializer "agentkit.pgvector_check", after: :connect_on_startup do
      # Silently skip during asset precompile / db:create
      next unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection_pool.connected?

      unless ActiveRecord::Base.connection.extension_enabled?("vector")
        Rails.logger.warn(
          "[AgentKit] pgvector extension not enabled. " \
          "Run: rails db:migrate after enabling the extension in Postgres."
        )
      end
    rescue StandardError
      # Don't crash startup if DB isn't ready
    end

    # ─── Configuration yield ──────────────────────────────────────────────────
    initializer "agentkit.configuration", before: :load_config_initializers do |app|
      app.config.agentkit = Agentkit.config
    end
  end
end
