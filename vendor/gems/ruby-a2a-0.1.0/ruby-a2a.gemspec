# frozen_string_literal: true

require_relative "lib/ruby_a2a/version"

Gem::Specification.new do |spec|
  spec.name          = "ruby-a2a"
  spec.version       = RubyA2A::VERSION
  spec.authors       = ["Enrique Meza C"]
  spec.email         = ["emezac@gmail.com"]
  spec.summary       = "A dependency-light Ruby client for Google's Agent-to-Agent (A2A) protocol"

  spec.description = <<~DESC
    ruby-a2a provides a PORO-first, explicit client for communicating with remote
    A2A-compatible agents. It supports message sending, task polling, SSE streaming,
    pluggable authentication strategies (Bearer Token, API Key, optional OAuth2),
    Agent Card discovery, and typed protocol error mapping — using only Ruby stdlib.
  DESC

  spec.license  = "MIT"
  spec.homepage = "https://github.com/example/ruby-a2a"

  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir.glob("lib/**/*") +
               %w[README.md CHANGELOG.md ruby-a2a.gemspec]

  spec.require_paths = ["lib"]
  spec.executables   = []

  spec.add_dependency "webrick", "~> 1.8"
  spec.add_dependency "logger", "~> 1.6"

  spec.add_development_dependency "rspec",   "~> 3.12"
  spec.add_development_dependency "webmock", "~> 3.23"
  spec.add_development_dependency "vcr",     "~> 6.2"
  spec.add_development_dependency "rake",    "~> 13.0"
end