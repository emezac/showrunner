# frozen_string_literal: true

require "timeout"

module Aflow
  # Walks a node graph, executes steps, handles failures, records traces.
  class Executor
    class HaltError < StandardError
      attr_reader :step_id, :cause
      def initialize(step_id, cause)
        @step_id = step_id
        @cause   = cause
        super("Flow halted at step '#{step_id}': #{cause.message}")
      end
    end

    # @param root         [Aflow::Nodes::Base]  root node of the graph
    # @param registry     [Hash]                { step_id_symbol => Step instance }
    # @param replay_trace [Aflow::Trace]        optional — enables replay mode
    def initialize(root, registry:, replay_trace: nil)
      raise ArgumentError, "registry must be a Hash" unless registry.is_a?(Hash)
      @root         = root
      @registry     = registry.transform_keys(&:to_sym)
      @replay_trace = replay_trace
      @trace        = Trace.new
    end

    # Run the flow from an initial context.
    # @param initial_context [Aflow::Context]
    # @return [Array(Aflow::Context, Aflow::Trace)]
    def run(initial_context: Context.new)
      final_context = execute_node(@root, initial_context)
      @trace.finish!
      [final_context, @trace]
    rescue HaltError => e
      @trace.finish!
      raise e
    end

    private

    # ── Node dispatch ──────────────────────────────────────────────────────

    def execute_node(node, context)
      case node.type
      when :sequence    then execute_sequence(node, context)
      when :parallel    then execute_parallel(node, context)
      when :step        then execute_step(node, context)
      when :conditional then execute_conditional(node, context)
      else
        raise ArgumentError, "Unknown node type: #{node.type.inspect}"
      end
    end

    def execute_sequence(node, context)
      node.children.reduce(context) do |ctx, child|
        execute_node(child, ctx)
      end
    end

    def execute_parallel(node, context)
      mutex  = Mutex.new
      errors = []

      threads = node.children.map do |child|
        Thread.new do
          Thread.current[:result_context] = execute_node(child, context)
        rescue => e
          mutex.synchronize { errors << e }
          Thread.current[:result_context] = context
        end
      end

      result_contexts = threads.map do |t|
        t.join
        t[:result_context]
      end

      raise errors.first if errors.any?

      # Merge all branch outputs onto the original context — later branches win on key conflicts
      result_contexts.reduce(context) do |acc, branch_ctx|
        merge_parallel_contexts(acc, branch_ctx, context)
      end
    end

    def execute_conditional(node, context)
      branch = node.condition.call(context) ? node.on_true : node.on_false
      return context unless branch
      execute_node(branch, context)
    end

    # ── Step execution ────────────────────────────────────────────────────

    def execute_step(node, context)
      step = fetch_step(node.step_id)
      cfg  = step.config

      # Replay mode: return previously recorded output without re-executing
      if replay_mode?
        past = @replay_trace.find(node.step_id.to_s)
        if past
          replayed = StepResult.new(
            status: past.status,
            output: past.output_snapshot,
            logs:   ["[replay] #{node.step_id}"]
          )
          @trace.record(step_id: node.step_id.to_s, result: replayed,
                        context_before: context, started_at: Time.now)
          return context.with(step_id: node.step_id.to_s, result: replayed)
        end
      end

      started_at = Time.now
      result     = execute_with_policy(step, context, cfg)

      @trace.record(
        step_id:        node.step_id.to_s,
        result:         result,
        context_before: context,
        started_at:     started_at
      )

      handle_result(node, context, result, cfg)
    end

    def execute_with_policy(step, context, cfg)
      max_tries   = 1 + (cfg[:retry] || 0)
      last_result = nil

      max_tries.times do
        last_result = safely_call(step, context, cfg[:timeout])
        break unless last_result.retry?
      end

      # Exhausted retries — promote to error
      if last_result&.retry?
        StepResult.error(
          error: RuntimeError.new("Step '#{step.id}' exhausted #{max_tries} retry attempt(s)"),
          logs:  (last_result.logs || []) + ["Retry limit reached after #{max_tries} attempt(s)"]
        )
      else
        last_result
      end
    end

    def safely_call(step, context, timeout_seconds)
      if timeout_seconds
        Timeout.timeout(timeout_seconds) { step.call(context) }
      else
        step.call(context)
      end
    rescue Timeout::Error => e
      StepResult.error(
        error: e,
        logs:  ["Timeout after #{timeout_seconds}s in step '#{step.id}'"]
      )
    rescue => e
      StepResult.error(
        error: e,
        logs:  ["Unexpected error in step '#{step.id}': #{e.class}: #{e.message}"]
      )
    end

    def handle_result(node, context, result, cfg)
      case result.status
      when :success, :skipped
        context.with(step_id: node.step_id.to_s, result: result)

      when :error
        if cfg[:fallback]
          run_fallback(cfg[:fallback], context, result)
        elsif cfg[:on_error] == :continue
          context.with(step_id: node.step_id.to_s, result: result)
        else
          raise HaltError.new(node.step_id.to_s, result.error || RuntimeError.new("Unknown error"))
        end

      else
        context
      end
    end

    def run_fallback(fallback_id, context, _failed_result)
      fallback_node = Nodes::StepNode.new(fallback_id)
      execute_step(fallback_node, context)
    rescue KeyError
      raise ArgumentError, "Fallback step '#{fallback_id}' not found in registry"
    end

    # ── Helpers ───────────────────────────────────────────────────────────

    def fetch_step(step_id)
      @registry.fetch(step_id.to_sym) do
        raise KeyError, "Step '#{step_id}' not found in registry. " \
                        "Available: #{@registry.keys.map(&:inspect).join(', ')}"
      end
    end

    def replay_mode?
      !@replay_trace.nil?
    end

    # Merge parallel branch results: only apply outputs that differ from the
    # original snapshot to avoid overwriting sibling branch data.
    def merge_parallel_contexts(accumulated, branch_ctx, original_ctx)
      changed = branch_ctx.data.reject { |k, v| original_ctx.data[k] == v }
      return accumulated if changed.empty?

      Context.new(
        data:     deep_merge(accumulated.data, changed),
        history:  accumulated.history + branch_ctx.history.last(1),
        metadata: accumulated.metadata
      )
    end

    def deep_merge(base, override)
      base.merge(override) do |_key, old_val, new_val|
        old_val.is_a?(Hash) && new_val.is_a?(Hash) ? deep_merge(old_val, new_val) : new_val
      end
    end
  end
end
