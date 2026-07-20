# frozen_string_literal: true

require "openssl"

require_relative "ruby_a2a/version"
require_relative "ruby_a2a/errors"
require_relative "ruby_a2a/configuration"
require_relative "ruby_a2a/agent_card"
require_relative "ruby_a2a/models/part"
require_relative "ruby_a2a/models/message"
require_relative "ruby_a2a/models/task"
require_relative "ruby_a2a/models/artifact"
require_relative "ruby_a2a/models/artifact_processor"
require_relative "ruby_a2a/auth/strategy"
require_relative "ruby_a2a/auth/bearer_token"
require_relative "ruby_a2a/auth/api_key"
require_relative "ruby_a2a/auth/oauth2"
require_relative "ruby_a2a/http/sse_reader"
require_relative "ruby_a2a/http/base"
require_relative "ruby_a2a/client"

# RubyA2A — A dependency-light Ruby client AND server for the Agent-to-Agent (A2A) protocol.
#
# Server components are opt-in to preserve the zero-dependency client footprint:
#   require "ruby_a2a/server"   # loads RubyA2A::Server::* (uses only stdlib)
#
# Quick start:
#   RubyA2A.configure do |c|
#     c.poll_interval     = 2.0
#     c.max_poll_attempts = 30
#   end
#
#   auth   = RubyA2A::Auth::BearerToken.new(ENV["AGENT_TOKEN"])
#   client = RubyA2A::Client.new("https://agent.example.com", auth: auth)
#   task   = client.send_message("Hello!")
#   puts task.state
module RubyA2A
  class << self
    # Configures global defaults.
    # Accepts a block that yields the Configuration object.
    # This method must not perform network I/O.
    #
    # @yieldparam config [RubyA2A::Configuration]
    # @return [RubyA2A::Configuration]
    def configure
      yield configuration if block_given?
      configuration
    end

    # Returns the current global Configuration object.
    #
    # @return [RubyA2A::Configuration]
    def configuration
      @configuration ||= Configuration.new
    end

    # Resets the configuration to defaults. Primarily useful in tests.
    #
    # @return [RubyA2A::Configuration]
    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
