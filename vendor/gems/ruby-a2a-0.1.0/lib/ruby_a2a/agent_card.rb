# frozen_string_literal: true

module RubyA2A
  # Represents the JSON Agent Card document discovered from a remote agent.
  # All data is held in the raw Hash; accessors are convenience wrappers.
  class AgentCard
    attr_reader :raw

    def initialize(raw)
      raise ArgumentError, "AgentCard raw data must be a Hash" unless raw.is_a?(Hash)

      @raw = raw.freeze
    end

    # The primary A2A endpoint URL declared by the agent.
    def a2a_endpoint_url
      @raw["a2aEndpointUrl"]
    end

    # Returns true when the agent declares streaming capability.
    def streaming?
      @raw.dig("capabilities", "streaming") == true
    end

    # Security schemes declared by the agent.
    def security_schemes
      @raw["securitySchemes"] || {}
    end

    # Skills declared by the agent.
    def skills
      @raw["skills"] || []
    end

    def to_h
      @raw.dup
    end
  end
end
