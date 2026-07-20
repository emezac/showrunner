# frozen_string_literal: true

# AgentKit Rails — agent-first Rails Engine
# Require this file by adding `gem "agentkit-rails"` to your Gemfile.

require "agentkit/version"
require "agentkit/configuration"
require "agentkit/model_router"
require "agentkit/skill_registry"
require "agentkit/memory_engine"
require "agentkit/hitl_engine"
require "agentkit/context_engineer"
require "agentkit/application_agent"
require "agentkit/engine"

module Agentkit
  class << self
    # Global configuration singleton.
    def config
      @config ||= Configuration.new
    end

    # Configure block — called from config/initializers/agentkit.rb
    #
    # Example:
    #   Agentkit.configure do |c|
    #     c.domain_name       = "LegalSketch"
    #     c.primary_entity    = :caso
    #     c.llm_default_model = "claude-sonnet-4-6"
    #     c.hitl_level        = :strict
    #     c.features          = [:rag, :scraping, :scope_guard]
    #   end
    def configure
      yield(config)
    end

    # Reset config — used in tests.
    def reset_config!
      @config = Configuration.new
    end
  end
end
