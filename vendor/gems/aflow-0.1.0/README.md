# aflow

A directed-graph execution engine for Ruby. Each node transforms an immutable `Context`, every run is fully traceable, and any run can be replayed deterministically.

```ruby
context, trace = Aflow.flow do
  sequence do
    step :fetch
    parallel do
      step :analyze
      step :summarize
    end
    step :store
  end
end.run(
  registry:        { fetch: FetchStep.new, analyze: AnalyzeStep.new,
                     summarize: SummarizeStep.new, store: StoreStep.new },
  initial_context: Aflow::Context.new(data: { url: "https://example.com" })
)
```

## Installation

```ruby
# Gemfile
gem "aflow"
```

```
bundle install
```

Or install standalone:

```
gem install aflow
```

**Requirements:** Ruby >= 3.1. No runtime dependencies.

---

## Core concepts

### Step

The atomic unit of work. Inherit from `Aflow::Step` and implement `#id` and `#call`.

```ruby
class FetchStep < Aflow::Step
  def id = "fetch"

  def call(context)
    response = HTTP.get(context[:url])

    Aflow::StepResult.success(
      output:  { body: response.body, status: response.code },
      logs:    ["Fetched #{context[:url]}"],
      metrics: { duration_ms: response.duration }
    )
  rescue => e
    Aflow::StepResult.error(error: e, logs: ["Fetch failed: #{e.message}"])
  end
end
```

`#call` receives an `Aflow::Context` and **must** return an `Aflow::StepResult`. Never mutate the context directly.

### StepResult

```ruby
# Success — output is merged into the context for subsequent steps
Aflow::StepResult.success(output: { key: value }, logs: [], metrics: {})

# Error — flow halts (unless on_error: :continue is configured)
Aflow::StepResult.error(error: exception)

# Skipped — context passes through unchanged, flow continues
Aflow::StepResult.skip(logs: ["reason"])

# Retry — executor re-runs the step up to the configured retry limit
Aflow::StepResult.retry(logs: ["not ready yet"])
```

### Context

Immutable. Every transformation produces a new `Context` — the original is never modified.

```ruby
ctx = Aflow::Context.new(data: { user_id: 42 }, metadata: { env: "production" })

ctx[:user_id]          # => 42
ctx.key?(:user_id)     # => true
ctx.fetch(:missing)    # => KeyError
```

### Flow DSL

Compose steps into a graph using the builder DSL.

```ruby
flow = Aflow::Flow.build do
  sequence do
    step :validate

    parallel do
      step :enrich_profile
      step :enrich_scores
    end

    condition(->(ctx) { ctx[:score] > 0.8 }) do
      on_true  { step :approve }
      on_false { step :review  }
    end

    step :notify
  end
end
```

Available node types:

| Node | Behaviour |
|------|-----------|
| `sequence` | Children run left-to-right; each receives the previous step's output |
| `parallel` | Children run concurrently in threads; outputs are merged |
| `condition` | Evaluates a lambda against the context; routes to `on_true` or `on_false` |
| `step` | Leaf node — runs a single registered step |

### Running a flow

```ruby
context, trace = flow.run(
  registry:        { validate: ValidateStep.new, ... },
  initial_context: Aflow::Context.new(data: { input: "..." })
)

context[:result]   # access merged outputs
trace.success?     # true/false
trace.total_duration_ms
```

`#run` returns `[Context, Trace]`. It raises `Aflow::Executor::HaltError` if a step fails and no recovery strategy is configured.

---

## Failure strategies

Configure per step using the `.config` class method:

```ruby
class UnreliableStep < Aflow::Step
  config retry:    3,               # re-run up to 3 extra times on :retry result
         timeout:  10,              # seconds; triggers :error on expiry
         fallback: :fallback_step,  # step id to run if this one errors
         on_error: :continue        # :halt (default) | :continue

  def id = "unreliable"
  def call(context) = ...
end
```

Fallback steps are regular steps looked up from the same registry:

```ruby
class FallbackStep < Aflow::Step
  def id = "fallback_step"
  def call(context)
    Aflow::StepResult.success(output: { recovered: true })
  end
end
```

---

## Tracing

Every run produces a `Trace` with a full event log:

```ruby
context, trace = flow.run(...)

trace.trace_id          # unique hex id
trace.success?          # false if any step errored
trace.total_duration_ms

trace.events.each do |event|
  puts "#{event.step_id}: #{event.status} (#{event.duration_ms}ms)"
  puts "  input:  #{event.input_snapshot}"
  puts "  output: #{event.output_snapshot}"
  puts "  logs:   #{event.logs}"
end

trace.to_h   # serialisable hash — persist to DB or log to JSON
```

---

## Replay

Pass a previous trace to `#run` to replay the flow. Steps whose output is already in the trace are skipped — their recorded outputs are re-injected into the context without re-execution.

```ruby
# First run
context, original_trace = flow.run(registry: registry, initial_context: ctx)

# Replay — outputs from the trace are reused, no steps are re-executed
context2, replay_trace = flow.run(
  registry:        registry,
  initial_context: ctx,
  replay_trace:    original_trace
)
```

Partial replay (replay from step X) can be achieved by trimming the trace before passing it in:

```ruby
# Not yet built into the DSL — trim events manually for now
partial_trace.instance_variable_set(:@events, original_trace.events.first(2))
```

---

## Agents / LLM steps

A step that calls an LLM is just a step:

```ruby
class LlmStep < Aflow::Step
  config timeout: 30

  def initialize(client) = (@client = client; super())
  def id = "llm"

  def call(context)
    response = @client.chat(messages: [{ role: "user", content: context[:prompt] }])

    Aflow::StepResult.success(
      output:  { llm_output: response.content },
      metrics: { tokens: response.usage.total_tokens }
    )
  rescue => e
    Aflow::StepResult.error(error: e)
  end
end
```

---

## Development

```bash
bundle install
bundle exec rake test
```

---

## Roadmap

- [ ] Persistent trace storage (ActiveRecord adapter)
- [ ] Step-level caching
- [ ] Flow versioning
- [ ] DAG visualisation (CLI / HTML)
- [ ] Async execution (Fiber / Ractors)

---

## License

MIT
