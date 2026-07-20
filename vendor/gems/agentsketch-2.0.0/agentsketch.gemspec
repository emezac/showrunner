# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "agentsketch"
  spec.version       = "2.0.0"

  spec.authors       = ["Enrique Meza C"]
  spec.email         = ["emezac@gmail.com"]

  spec.summary       = "Declarative Multi-Agent Orchestration DSL for Ruby"

  spec.description = <<~DESC
    AgentSketch is a Ruby DSL that acts as an intention orchestrator:
    declare agents, tools, memory and workflows in semantic domain terms.
    The runtime — built on Aflow, ruby_llm and ruby-a2a — translates those
    declarations to LLM calls, embeddings, vector searches and retry policies.
  DESC

  spec.homepage = "https://github.com/agentsketch/agentsketch"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir.chdir(__dir__) do
    Dir.glob("{lib,spec}/**/*") + %w[READMER.md LICENSE Gemfile agentsketch.gemspec]
  end

  spec.require_paths = ["lib"]

  # Core dependencies
  spec.add_dependency "aflow",    "~> 0.1.0"
  spec.add_dependency "ruby_llm", "~> 1.15"

  # Dev
  spec.add_development_dependency "rspec",   "~> 3.12"
  spec.add_development_dependency "rake",    "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.60"
end