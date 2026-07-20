# frozen_string_literal: true

module RubyA2A
  module Models
    # Represents an A2A artifact, which carries output content from the agent.
    class Artifact
      attr_reader :raw

      def initialize(raw)
        raise ArgumentError, "Artifact raw data must be a Hash" unless raw.is_a?(Hash)

        @raw = raw.dup.freeze
      end

      def artifact_id
        @raw["artifactId"]
      end

      def name
        @raw["name"]
      end

      def parts
        @raw["parts"] || []
      end

      def to_h
        @raw.dup
      end

      # Returns a new Artifact with additional parts appended.
      def append_parts(new_parts)
        merged = to_h
        merged["parts"] = (merged["parts"] || []) + Array(new_parts)
        self.class.new(merged)
      end
    end
  end
end
