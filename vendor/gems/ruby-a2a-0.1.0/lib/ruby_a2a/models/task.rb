# frozen_string_literal: true

module RubyA2A
  module Models
    # Represents an A2A task returned by the remote agent.
    class Task
      STATES_UNPREFIXED = {
        "submitted"          => "submitted",
        "working"            => "working",
        "input-required"     => "input-required",
        "completed"          => "completed",
        "failed"             => "failed",
        "canceled"           => "canceled",
        "unknown"            => "unknown"
      }.freeze

      STATES_PREFIXED = {
        "TASK_STATE_SUBMITTED"     => "submitted",
        "TASK_STATE_WORKING"       => "working",
        "TASK_STATE_COMPLETED"     => "completed",
        "TASK_STATE_FAILED"        => "failed",
        "TASK_STATE_CANCELED"      => "canceled",
        "TASK_STATE_AUTH_REQUIRED" => "auth-required"
      }.freeze

      TERMINAL_UNPREFIXED = %w[completed failed canceled].freeze
      TERMINAL_PREFIXED   = %w[TASK_STATE_COMPLETED TASK_STATE_FAILED TASK_STATE_CANCELED].freeze
      ALL_TERMINAL = (TERMINAL_UNPREFIXED + TERMINAL_PREFIXED).freeze

      AUTH_REQUIRED_STATES = %w[auth-required TASK_STATE_AUTH_REQUIRED].freeze

      attr_reader :raw

      def initialize(raw)
        raise ArgumentError, "Task raw data must be a Hash" unless raw.is_a?(Hash)

        @raw = raw.freeze
      end

      def task_id
        @raw["taskId"] || @raw["id"]
      end

      def status
        @raw["status"]
      end

      def state
        status.is_a?(Hash) ? status["state"] : nil
      end

      def artifacts
        @raw["artifacts"] || []
      end

      # Returns true when the task is in a terminal state.
      # Supports both TASK_STATE_* and unprefixed conventions.
      def terminal?
        s = state
        return false if s.nil?
        ALL_TERMINAL.include?(s)
      end

      def auth_required?
        AUTH_REQUIRED_STATES.include?(state)
      end

      def to_h
        @raw.dup
      end
    end
  end
end
