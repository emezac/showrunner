# frozen_string_literal: true

require_relative "lib/agentkit/version"

Gem::Specification.new do |spec|
  spec.name          = "agentkit-rails"
  spec.version       = Agentkit::VERSION
  spec.authors       = ["AgentKit Team"]
  spec.email         = ["hello@agentkit.dev"]

  spec.summary       = "Agent-first Rails Engine for domain applications"
  spec.description   = <<~DESC
    AgentKit Rails is a gemified Rails Engine that provides the agent-first backbone
    for ConsultorSketch as reusable infrastructure. Includes semantic memory,
    HITL suggestion cycle, nightly dreaming, and the self-improvement Factory.
  DESC
  spec.homepage      = "https://github.com/agentkit/agentkit-rails"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir[
    "lib/**/*",
    "app/**/*",
    "db/migrate/**/*",
    "config/**/*",
    "bin/**/*",
    "*.gemspec",
    "README.md",
    "LICENSE"
  ]

  spec.executables   = ["agentkit"]
  spec.require_paths = ["lib"]

  # Core Rails dependencies
  spec.add_dependency "rails",           ">= 8.0"
  spec.add_dependency "pg",             ">= 1.5"
  spec.add_dependency "pgvector",       ">= 0.2"
  spec.add_dependency "sidekiq",        ">= 7.0"
  spec.add_dependency "sidekiq-cron",   ">= 1.9"

  # LLM & Agent runtime
  spec.add_dependency "ruby_llm",       ">= 0.9"

  # A2A protocol (Agent-to-Agent)
  spec.add_dependency "ruby-a2a",       ">= 0.1"

  # AgentSketch DSL (optional orchestration)
  # spec.add_dependency "agent_sketch", ">= 0.1"

  spec.add_development_dependency "rspec-rails"
  spec.add_development_dependency "factory_bot_rails"
end
