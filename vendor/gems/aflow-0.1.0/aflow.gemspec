# frozen_string_literal: true

require_relative "lib/aflow/version"

Gem::Specification.new do |spec|
  spec.name    = "aflow"
  spec.version = Aflow::VERSION
  spec.authors = ["aflow contributors"]
  spec.email   = []

  spec.summary     = "Directed graph execution engine with full traceability and replay."
  spec.description = <<~DESC
    Aflow executes steps in a directed graph, ensuring immutable context propagation,
    deterministic replay, structured tracing, parallel execution, and configurable
    failure strategies — without any runtime dependencies.
  DESC
  spec.homepage = "https://github.com/example/aflow"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir.glob("{lib,spec}/**/*") +
               %w[aflow.gemspec README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  # Runtime dependencies: NONE

  spec.metadata = {
    "source_code_uri"   => spec.homepage,
    "changelog_uri"     => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
end
