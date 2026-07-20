# frozen_string_literal: true

require_relative "spec_helper"

# ─── Shared step fixtures ───────────────────────────────────────────────────

class DoubleStep < Aflow::Step
  def id = "double"
  def call(ctx)
    n = ctx[:n] || 0
    Aflow::StepResult.success(output: { n: n * 2, doubled: true }, logs: ["doubled #{n}"])
  end
end

class AddTenStep < Aflow::Step
  def id = "add_ten"
  def call(ctx)
    Aflow::StepResult.success(output: { n: (ctx[:n] || 0) + 10 })
  end
end

class FailStep < Aflow::Step
  def id = "fail"
  def call(_ctx)
    raise RuntimeError, "boom"
  end
end

class SkipStep < Aflow::Step
  def id = "skip"
  def call(_ctx)
    Aflow::StepResult.skip(logs: ["skipped intentionally"])
  end
end

class TagStep < Aflow::Step
  def initialize(tag) = (@tag = tag; super())
  def id = @tag.to_s
  def call(ctx)
    Aflow::StepResult.success(output: { @tag => true, :last => @tag })
  end
end

class RetryStep < Aflow::Step
  config retry: 2, on_error: :continue

  def id = "flaky"
  def call(_ctx)
    Aflow::StepResult.retry(logs: ["not ready"])
  end
end

class TimeoutStep < Aflow::Step
  config timeout: 1

  def id = "slow"
  def call(_ctx)
    sleep 5
    Aflow::StepResult.success(output: { done: true })
  end
end

class FallbackTarget < Aflow::Step
  def id = "fallback_target"
  def call(_ctx)
    Aflow::StepResult.success(output: { recovered: true }, logs: ["fallback ran"])
  end
end

class ContinueOnErrorStep < Aflow::Step
  config on_error: :continue

  def id = "error_continue"
  def call(_ctx)
    raise "soft error"
  end
end

class OutputStep < Aflow::Step
  def initialize(key, value) = (@key = key; @value = value; super())
  def id = "output_#{@key}"
  def call(_ctx)
    Aflow::StepResult.success(output: { @key => @value })
  end
end

# ─── StepResult tests ───────────────────────────────────────────────────────

class StepResultTest < Minitest::Test
  def test_success_factory
    r = Aflow::StepResult.success(output: { x: 1 }, logs: ["ok"])
    assert r.success?
    assert_equal :success, r.status
    assert_equal({ x: 1 }, r.output)
    assert_equal ["ok"], r.logs
    assert_nil r.error
  end

  def test_error_factory
    err = RuntimeError.new("oops")
    r = Aflow::StepResult.error(error: err)
    assert r.error?
    assert_equal err, r.error
  end

  def test_skip_factory
    r = Aflow::StepResult.skip
    assert r.skipped?
  end

  def test_retry_factory
    r = Aflow::StepResult.retry
    assert r.retry?
  end

  def test_invalid_status_raises
    assert_raises(ArgumentError) { Aflow::StepResult.new(status: :invalid) }
  end

  def test_immutable_after_construction
    r = Aflow::StepResult.success(output: { x: 1 })
    assert r.frozen?
    assert r.output.frozen?
    assert r.logs.frozen?
  end

  def test_to_h
    r = Aflow::StepResult.success(output: { x: 1 })
    h = r.to_h
    assert_equal :success, h[:status]
    assert_equal({ x: 1 }, h[:output])
  end
end

# ─── Context tests ───────────────────────────────────────────────────────────

class ContextTest < Minitest::Test
  def test_immutable_data
    ctx = Aflow::Context.new(data: { x: 1 })
    assert ctx.frozen?
    assert ctx.data.frozen?
  end

  def test_with_produces_new_context
    ctx  = Aflow::Context.new(data: { x: 1 })
    r    = Aflow::StepResult.success(output: { y: 2 })
    ctx2 = ctx.with(step_id: "step_a", result: r)

    refute_same ctx, ctx2
    assert_equal 1, ctx2[:x]
    assert_equal 2, ctx2[:y]
    assert_nil ctx[:y]
  end

  def test_with_appends_history
    ctx  = Aflow::Context.new
    r    = Aflow::StepResult.success(output: {})
    ctx2 = ctx.with(step_id: "s1", result: r)

    assert_equal 1, ctx2.history.size
    assert_equal "s1", ctx2.history.first[:step_id]
  end

  def test_deep_merge
    ctx  = Aflow::Context.new(data: { nested: { a: 1 } })
    r    = Aflow::StepResult.success(output: { nested: { b: 2 } })
    ctx2 = ctx.with(step_id: "s", result: r)

    assert_equal({ a: 1, b: 2 }, ctx2[:nested])
  end

  def test_bracket_accessor
    ctx = Aflow::Context.new(data: { answer: 42 })
    assert_equal 42, ctx[:answer]
  end

  def test_key_predicate
    ctx = Aflow::Context.new(data: { present: true })
    assert ctx.key?(:present)
    refute ctx.key?(:absent)
  end

  def test_original_context_not_mutated
    original_data = { x: 1 }
    ctx  = Aflow::Context.new(data: original_data)
    r    = Aflow::StepResult.success(output: { x: 99 })
    _ctx2 = ctx.with(step_id: "s", result: r)

    assert_equal 1, ctx[:x]
  end
end

# ─── Step tests ──────────────────────────────────────────────────────────────

class StepTest < Minitest::Test
  def test_abstract_id_raises
    s = Aflow::Step.new
    assert_raises(NotImplementedError) { s.id }
  end

  def test_abstract_call_raises
    s = Aflow::Step.new
    assert_raises(NotImplementedError) { s.call(Aflow::Context.new) }
  end

  def test_concrete_step
    ctx = Aflow::Context.new(data: { n: 5 })
    r   = DoubleStep.new.call(ctx)
    assert r.success?
    assert_equal 10, r.output[:n]
  end

  def test_config_defaults
    cfg = DoubleStep.new.config
    assert_equal 0, cfg[:retry]
    assert_nil cfg[:timeout]
    assert_equal :halt, cfg[:on_error]
  end

  def test_custom_config
    cfg = RetryStep.new.config
    assert_equal 2, cfg[:retry]
    assert_equal :continue, cfg[:on_error]
  end
end

# ─── Trace tests ────────────────────────────────────────────────────────────

class TraceTest < Minitest::Test
  def test_records_events
    trace  = Aflow::Trace.new
    result = Aflow::StepResult.success(output: { x: 1 })
    ctx    = Aflow::Context.new
    trace.record(step_id: "step_a", result: result, context_before: ctx, started_at: Time.now)
    trace.finish!

    assert_equal 1, trace.events.size
    assert_equal "step_a", trace.events.first.step_id
    assert_equal :success, trace.events.first.status
  end

  def test_success_predicate
    trace  = Aflow::Trace.new
    result = Aflow::StepResult.success(output: {})
    trace.record(step_id: "ok", result: result, context_before: Aflow::Context.new, started_at: Time.now)
    trace.finish!
    assert trace.success?
  end

  def test_failure_predicate
    trace  = Aflow::Trace.new
    result = Aflow::StepResult.error(error: RuntimeError.new("x"))
    trace.record(step_id: "bad", result: result, context_before: Aflow::Context.new, started_at: Time.now)
    trace.finish!
    refute trace.success?
  end

  def test_find_by_step_id
    trace  = Aflow::Trace.new
    result = Aflow::StepResult.success(output: { found: true })
    trace.record(step_id: "target", result: result, context_before: Aflow::Context.new, started_at: Time.now)
    trace.finish!

    event = trace.find("target")
    refute_nil event
    assert_equal :success, event.status
  end

  def test_to_h_structure
    trace = Aflow::Trace.new
    trace.finish!
    h = trace.to_h
    assert h.key?(:trace_id)
    assert h.key?(:steps)
    assert h.key?(:success)
  end
end

# ─── Flow DSL tests ──────────────────────────────────────────────────────────

class FlowDSLTest < Minitest::Test
  def test_single_step
    flow = Aflow::Flow.build { step :double }
    ctx, trace = flow.run(
      registry:        { double: DoubleStep.new },
      initial_context: Aflow::Context.new(data: { n: 3 })
    )
    assert_equal 6, ctx[:n]
    assert trace.success?
  end

  def test_sequence
    flow = Aflow::Flow.build do
      sequence do
        step :double
        step :add_ten
      end
    end

    ctx, _ = flow.run(
      registry:        { double: DoubleStep.new, add_ten: AddTenStep.new },
      initial_context: Aflow::Context.new(data: { n: 5 })
    )
    # double(5) = 10 → add_ten(10) = 20
    assert_equal 20, ctx[:n]
  end

  def test_parallel_merges_outputs
    flow = Aflow::Flow.build do
      parallel do
        step :tag_a
        step :tag_b
      end
    end

    ctx, _ = flow.run(
      registry: { tag_a: TagStep.new(:a), tag_b: TagStep.new(:b) }
    )

    assert ctx[:a]
    assert ctx[:b]
  end

  def test_nested_sequence_and_parallel
    flow = Aflow::Flow.build do
      sequence do
        step :double
        parallel do
          step :tag_a
          step :tag_b
        end
        step :add_ten
      end
    end

    ctx, trace = flow.run(
      registry: {
        double:  DoubleStep.new,
        tag_a:   TagStep.new(:a),
        tag_b:   TagStep.new(:b),
        add_ten: AddTenStep.new
      },
      initial_context: Aflow::Context.new(data: { n: 4 })
    )

    assert_equal 18, ctx[:n]   # double(4)=8, parallel no-op on n, add_ten(8)=18
    assert ctx[:a]
    assert ctx[:b]
    assert trace.success?
  end

  def test_conditional_true_branch
    flow = Aflow::Flow.build do
      condition(->(ctx) { ctx[:n] > 5 }) do
        on_true  { step :tag_a }
        on_false { step :tag_b }
      end
    end

    ctx, _ = flow.run(
      registry:        { tag_a: TagStep.new(:a), tag_b: TagStep.new(:b) },
      initial_context: Aflow::Context.new(data: { n: 10 })
    )
    assert ctx[:a]
    refute ctx[:b]
  end

  def test_conditional_false_branch
    flow = Aflow::Flow.build do
      condition(->(ctx) { ctx[:n] > 5 }) do
        on_true  { step :tag_a }
        on_false { step :tag_b }
      end
    end

    ctx, _ = flow.run(
      registry:        { tag_a: TagStep.new(:a), tag_b: TagStep.new(:b) },
      initial_context: Aflow::Context.new(data: { n: 2 })
    )
    refute ctx[:a]
    assert ctx[:b]
  end

  def test_skip_step_continues_flow
    flow = Aflow::Flow.build do
      sequence do
        step :skip
        step :add_ten
      end
    end

    ctx, trace = flow.run(
      registry:        { skip: SkipStep.new, add_ten: AddTenStep.new },
      initial_context: Aflow::Context.new(data: { n: 5 })
    )
    assert_equal 15, ctx[:n]
    assert trace.success?
  end
end

# ─── Error handling tests ────────────────────────────────────────────────────

class ErrorHandlingTest < Minitest::Test
  def test_halt_on_error_raises
    flow = Aflow::Flow.build { step :fail }

    assert_raises(Aflow::Executor::HaltError) do
      flow.run(registry: { fail: FailStep.new })
    end
  end

  def test_on_error_continue_does_not_raise
    flow = Aflow::Flow.build do
      sequence do
        step :error_continue
        step :add_ten
      end
    end

    ctx, trace = flow.run(
      registry:        { error_continue: ContinueOnErrorStep.new, add_ten: AddTenStep.new },
      initial_context: Aflow::Context.new(data: { n: 5 })
    )

    assert_equal 15, ctx[:n]
    refute trace.success?  # error was recorded
  end

  def test_retry_exhaustion_continues_with_on_error_continue
    flow = Aflow::Flow.build { step :flaky }

    # RetryStep has on_error: :continue — after exhausting retries it should record error but not halt
    ctx, trace = flow.run(registry: { flaky: RetryStep.new })
    refute trace.success?
  end

  def test_timeout_triggers_error
    flow = Aflow::Flow.build { step :slow }

    assert_raises(Aflow::Executor::HaltError) do
      flow.run(registry: { slow: TimeoutStep.new })
    end
  end

  def test_fallback_step_runs_on_error
    fail_with_fallback = Class.new(Aflow::Step) do
      config fallback: :fallback_target
      def id = "fail_fb"
      def call(_) = raise("primary failed")
    end

    flow = Aflow::Flow.build { step :fail_fb }

    ctx, trace = flow.run(
      registry: {
        fail_fb:         fail_with_fallback.new,
        fallback_target: FallbackTarget.new
      }
    )

    assert ctx[:recovered]
  end

  def test_missing_step_raises_key_error
    flow = Aflow::Flow.build { step :nonexistent }

    assert_raises(KeyError) do
      flow.run(registry: {})
    end
  end
end

# ─── Replay tests ────────────────────────────────────────────────────────────

class ReplayTest < Minitest::Test
  def test_replay_reuses_previous_outputs
    flow = Aflow::Flow.build do
      sequence do
        step :double
        step :add_ten
      end
    end

    registry = { double: DoubleStep.new, add_ten: AddTenStep.new }
    initial  = Aflow::Context.new(data: { n: 3 })

    # First run
    _, original_trace = flow.run(registry: registry, initial_context: initial)

    # Replay — steps should not actually execute, outputs come from trace
    call_count = 0
    spy_double = Class.new(Aflow::Step) do
      define_method(:id) { "double" }
      define_method(:call) { |_| call_count += 1; Aflow::StepResult.success(output: { n: 999 }) }
    end.new

    ctx2, replay_trace = flow.run(
      registry:        { double: spy_double, add_ten: AddTenStep.new },
      initial_context: initial,
      replay_trace:    original_trace
    )

    assert_equal 0, call_count, "Step should not have been called in replay mode"
    assert_equal 16, ctx2[:n]   # original: double(3)=6 + add_ten(6)=16
  end
end

# ─── Trace completeness tests ────────────────────────────────────────────────

class TraceCompletenessTest < Minitest::Test
  def test_trace_records_all_steps
    flow = Aflow::Flow.build do
      sequence do
        step :double
        step :add_ten
      end
    end

    _, trace = flow.run(
      registry:        { double: DoubleStep.new, add_ten: AddTenStep.new },
      initial_context: Aflow::Context.new(data: { n: 1 })
    )

    step_ids = trace.events.map(&:step_id)
    assert_includes step_ids, "double"
    assert_includes step_ids, "add_ten"
  end

  def test_trace_records_duration
    flow = Aflow::Flow.build { step :double }
    _, trace = flow.run(
      registry:        { double: DoubleStep.new },
      initial_context: Aflow::Context.new(data: { n: 2 })
    )

    assert trace.events.first.duration_ms >= 0
    refute_nil trace.total_duration_ms
  end

  def test_trace_captures_input_snapshot
    flow = Aflow::Flow.build { step :double }
    _, trace = flow.run(
      registry:        { double: DoubleStep.new },
      initial_context: Aflow::Context.new(data: { n: 7 })
    )

    assert_equal 7, trace.events.first.input_snapshot[:n]
  end
end

# ─── Aflow convenience helper ────────────────────────────────────────────────

class AflowHelperTest < Minitest::Test
  def test_aflow_flow_helper
    flow = Aflow.flow { step :double }
    ctx, _ = flow.run(
      registry:        { double: DoubleStep.new },
      initial_context: Aflow::Context.new(data: { n: 4 })
    )
    assert_equal 8, ctx[:n]
  end
end
