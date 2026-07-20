# frozen_string_literal: true

require_relative "artifact"

module RubyA2A
  module Models
    # Processes complete artifacts and streaming artifact fragments delivered
    # via SSE events. Maintains an internal registry keyed by artifactId.
    #
    # Usage:
    #   processor = ArtifactProcessor.new
    #   processor.process(event)  # => RubyA2A::Models::Artifact
    #   processor.artifacts       # => Hash of artifactId => Artifact
    class ArtifactProcessor
      attr_reader :artifacts

      def initialize
        @artifacts = {}
      end

      # Processes a single parsed SSE event Hash.
      # If the event contains an "artifactUpdate" key, updates internal state.
      # Returns the affected Artifact or nil when the event is not an artifact update.
      def process(event)
        raise ArgumentError, "event must not be nil" if event.nil?
        raise ArgumentError, "event must be a Hash"  unless event.is_a?(Hash)

        update = event["artifactUpdate"]
        return nil unless update.is_a?(Hash)

        artifact_id = update["artifactId"]
        append      = update["append"] == true
        new_parts   = update["parts"] || []

        if append && @artifacts.key?(artifact_id)
          existing           = @artifacts[artifact_id]
          @artifacts[artifact_id] = existing.append_parts(new_parts)
        else
          @artifacts[artifact_id] = Artifact.new(update)
        end

        @artifacts[artifact_id]
      end
    end
  end
end
