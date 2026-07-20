# frozen_string_literal: true

module Aflow
  # Accumulates step execution events during a flow run.
  # Used for auditing, debugging, and deterministic replay.
  class Trace
    Event = Struct.new(
      :step_id,
      :status,
      :input_snapshot,
      :output_snapshot,
      :error,
      :logs,
      :metrics,
      :started_at,
      :ended_at,
      :duration_ms,
      keyword_init: true
    )

    attr_reader :trace_id, :events, :started_at, :ended_at

    def initialize
      @trace_id   = generate_id
      @events     = []
      @started_at = Time.now
      @ended_at   = nil
    end

    def record(step_id:, result:, context_before:, started_at:)
      ended_at = Time.now
      @events << Event.new(
        step_id:          step_id,
        status:           result.status,
        input_snapshot:   context_before.data.dup.freeze,
        output_snapshot:  result.output.dup.freeze,
        error:            result.error ? { class: result.error.class.name, message: result.error.message } : nil,
        logs:             result.logs.dup.freeze,
        metrics:          result.metrics.dup.freeze,
        started_at:       started_at,
        ended_at:         ended_at,
        duration_ms:      ((ended_at - started_at) * 1000).round(2)
      )
    end

    def finish!
      @ended_at = Time.now
      freeze_events
      self
    end

    def find(step_id)
      events.find { |e| e.step_id == step_id }
    end

    def success?
      events.none? { |e| e.status == :error }
    end

    def total_duration_ms
      return nil unless ended_at
      ((ended_at - started_at) * 1000).round(2)
    end

    def to_h
      {
        trace_id:        trace_id,
        started_at:      started_at,
        ended_at:        ended_at,
        total_ms:        total_duration_ms,
        success:         success?,
        steps:           events.map(&:to_h)
      }
    end

    def inspect
      "#<Aflow::Trace id=#{trace_id} steps=#{events.size} success=#{success?}>"
    end

    private

    def generate_id
      require "securerandom"
      SecureRandom.hex(8)
    end

    def freeze_events
      @events = @events.freeze
    end
  end
end
