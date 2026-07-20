# frozen_string_literal: true

module Aflow
  # Immutable value object returned by every Step#call.
  # Use the factory methods (.success, .error, .skip) instead of .new directly.
  class StepResult
    VALID_STATUSES = %i[success error skipped retry].freeze

    attr_reader :status, :output, :error, :logs, :metrics, :next_steps

    def initialize(status:, output: {}, error: nil, logs: [], metrics: {}, next_steps: nil)
      raise ArgumentError, "Invalid status: #{status.inspect}. Must be one of #{VALID_STATUSES}" \
        unless VALID_STATUSES.include?(status)

      @status     = status
      @output     = (output || {}).freeze
      @error      = error
      @logs       = (logs || []).dup.freeze
      @metrics    = (metrics || {}).freeze
      @next_steps = next_steps&.dup&.freeze
      freeze
    end

    # --- Factory methods ---

    def self.success(output: {}, logs: [], metrics: {}, next_steps: nil)
      new(status: :success, output: output, logs: logs, metrics: metrics, next_steps: next_steps)
    end

    def self.error(error:, logs: [], metrics: {}, output: {})
      new(status: :error, error: error, logs: logs, metrics: metrics, output: output)
    end

    def self.skip(logs: [])
      new(status: :skipped, logs: logs)
    end

    def self.retry(logs: [], metrics: {})
      new(status: :retry, logs: logs, metrics: metrics)
    end

    # --- Predicates ---

    def success?  = status == :success
    def error?    = status == :error
    def skipped?  = status == :skipped
    def retry?    = status == :retry

    def to_h
      {
        status:     status,
        output:     output,
        error:      error&.message,
        logs:       logs,
        metrics:    metrics,
        next_steps: next_steps
      }
    end

    def inspect
      "#<Aflow::StepResult status=#{status} output=#{output.inspect}#{" error=#{error.message.inspect}" if error}>"
    end
  end
end
