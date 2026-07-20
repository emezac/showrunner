# frozen_string_literal: true

module Aflow
  # Immutable state carrier. Every step receives a Context and must NOT mutate it.
  # Use #with to produce a new Context from a StepResult.
  class Context
    attr_reader :data, :history, :metadata

    def initialize(data: {}, history: [], metadata: {})
      @data     = deep_freeze(deep_dup(data))
      @history  = history.dup.freeze
      @metadata = deep_freeze(deep_dup(metadata))
      freeze
    end

    # Returns a new Context merging the step's output and appending to history.
    def with(step_id:, result:)
      Context.new(
        data:     deep_merge(data, result.output || {}),
        history:  history + [history_entry(step_id, result)],
        metadata: metadata
      )
    end

    # Convenience accessor — reads from data hash.
    def [](key)
      data[key]
    end

    def fetch(key, *args, &block)
      data.fetch(key, *args, &block)
    end

    def key?(key) = data.key?(key)

    def to_h
      { data: data, history: history, metadata: metadata }
    end

    def inspect
      "#<Aflow::Context data=#{data.inspect} history_size=#{history.size}>"
    end

    private

    def history_entry(step_id, result)
      {
        step_id:   step_id,
        status:    result.status,
        output:    result.output,
        error:     result.error ? serialize_error(result.error) : nil,
        logs:      result.logs,
        metrics:   result.metrics,
        timestamp: Time.now
      }.freeze
    end

    def serialize_error(err)
      { class: err.class.name, message: err.message }.freeze
    end

    def deep_merge(base, override)
      base.merge(override) do |_key, old_val, new_val|
        if old_val.is_a?(Hash) && new_val.is_a?(Hash)
          deep_merge(old_val, new_val)
        else
          new_val
        end
      end
    end

    def deep_dup(obj)
      case obj
      when Hash  then obj.transform_values { |v| deep_dup(v) }
      when Array then obj.map { |v| deep_dup(v) }
      else            obj.dup rescue obj
      end
    end

    def deep_freeze(obj)
      case obj
      when Hash  then obj.transform_values { |v| deep_freeze(v) }.freeze
      when Array then obj.map { |v| deep_freeze(v) }.freeze
      else            obj.freeze
      end
    end
  end
end
