# AgentKit Rails

**Agent-first Rails Engine** — reduce weeks of setup to hours.

[![Gem Version](https://badge.fury.io/rb/agentkit-rails.svg)](https://badge.fury.io/rb/agentkit-rails)

AgentKit Rails is a gemified `Rails::Engine` that provides the agent-first backbone for domain applications. It ships semantic memory, Human-in-the-Loop (HITL) suggestion cycles, nightly dreaming consolidation, and a self-improvement Factory — all available from the first commit.

> **Core principle:** The kernel knows nothing about your domain.  
> It knows only agents, memory, suggestions, and jobs. The domain extends, never modifies.

---

## Stack

| Layer | Technology |
|-------|-----------|
| Database | Rails 8 · PostgreSQL · pgvector |
| Background | Sidekiq · sidekiq-cron |
| LLM runtime | ruby_llm |
| Agent protocol | ruby-a2a (A2A) |
| Frontend | Hotwire (Turbo + Stimulus) |
| Orchestration | AgentSketch DSL (optional) |

---

## Installation

```bash
gem install agentkit-rails
```

Or add to your Gemfile:

```ruby
gem "agentkit-rails"
```

**Prerequisites:**
- Ruby >= 3.1
- PostgreSQL with pgvector extension
- Redis (for Sidekiq)

---

## Quick start — Setup Wizard

The fastest way to get started is the interactive Setup Wizard:

```bash
# 1. Install the gem globally for CLI access
gem install agentkit-rails

# 2. Run the Wizard (~5 minute assessment)
agentkit new my_legal_app

# 3. Configure environment
cd my_legal_app
cp .env.example .env      # Add your API keys

# 4. Start
bundle install
rails db:create db:migrate db:seed
bin/dev

# 5. Verify — create your first entity and watch the agent run
rails console
> Caso.create!(title: "Test case", brief: "Contract dispute")
# => CasoIntakeAgent fires in background, creates suggestion in dashboard
```

---

## Manual installation (existing app)

```ruby
# config/application.rb
require "agentkit"
```

```ruby
# config/initializers/agentkit.rb
Agentkit.configure do |config|
  config.domain_name       = "MyApp"
  config.primary_entity    = :project
  config.llm_default_model = "claude-sonnet-4-6"
  config.llm_fast_model    = "gemini-2.5-flash"
  config.llm_complex_model = "claude-opus-4-6"
  config.embedding_model   = "gemini-embedding-2"
  config.hitl_level        = :strict     # :strict | :advisory | :silent
  config.features          = [:rag, :scope_guard]
  config.a2a_enabled       = false
end
```

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount Agentkit::Engine => "/agentkit"
  # your routes...
end
```

```bash
rails agentkit:install:migrations
rails db:migrate
```

---

## Architecture

```
agentkit-rails/
├── lib/agentkit/
│   ├── engine.rb              # Rails::Engine
│   ├── configuration.rb       # Agentkit.configure block
│   ├── application_agent.rb   # Base class: chat, memorize!, recall!, suggest!
│   ├── memory_engine.rb       # pgvector interface: store, search, cluster
│   ├── hitl_engine.rb         # suggest!, approve, reject, snooze
│   ├── model_router.rb        # fast/default/complex/code/vision profiles
│   ├── skill_registry.rb      # load_skill, compose_skills
│   └── context_engineer.rb    # build_context hook
├── app/
│   ├── agents/agentkit/
│   │   ├── dreaming_agent.rb
│   │   ├── evolution_suggester_agent.rb
│   │   └── codificador_agent.rb
│   ├── jobs/agentkit/
│   │   ├── dreaming_job.rb
│   │   ├── embedding_job.rb
│   │   ├── agent_worker_job.rb
│   │   ├── evolution_report_job.rb
│   │   ├── financial_health_job.rb
│   │   └── auto_apply_suggestion_job.rb
│   ├── models/agentkit/
│   │   ├── memory.rb
│   │   ├── agent_log.rb
│   │   ├── agent_suggestion.rb
│   │   ├── evolution_item.rb
│   │   └── code_generation.rb
│   ├── concerns/agentkit/
│   │   └── agent_triggerable.rb
│   └── controllers/agentkit/
│       ├── a2a_controller.rb
│       ├── suggestions_controller.rb
│       ├── dreaming_controller.rb
│       └── fabrica_controller.rb
└── db/migrate/               # 5 kernel migrations (agentkit_ prefix)
```

---

## Domain agent example

```ruby
# app/agents/application_agent.rb (domain — inherits kernel)
class ApplicationAgent < Agentkit::ApplicationAgent
  def domain_context
    "Firm: #{Current.account&.name}. Active cases: #{Caso.active.count}."
  end
end

# app/agents/caso_intake_agent.rb
class CasoIntakeAgent < ApplicationAgent
  def call(caso)
    memories = recall!("caso intake #{caso.practice_area}")
    ctx      = build_context(query: caso.brief)

    analysis = chat(
      "Analyze this case: #{caso.brief}",
      model:  :default,
      system: ctx
    )

    memorize!(analysis, tags: ["intake", caso.practice_area])
    suggest!(type: "case_review", title: "Initial analysis", description: analysis)
  end
end
```

---

## AgentTriggerable

Include in any ActiveRecord model to wire agent triggers to lifecycle events:

```ruby
class Caso < ApplicationRecord
  include Agentkit::AgentTriggerable

  trigger_agent CasoIntakeAgent, on: :create
  trigger_agent CasoRiskAgent,   on: :create, async: true
  trigger_agent ScopeGuardAgent, on: :update, if: :brief_changed?
end
```

---

## ApplicationAgent public interface

| Method | Description |
|--------|-------------|
| `chat(prompt, model: nil, system: nil)` | Call LLM. `model` accepts `:fast`, `:default`, `:complex`, `:code`, `:vision` or a model string. |
| `memorize!(content, tags:, type:, confidence:)` | Store text in memory; dispatches `EmbeddingJob`. |
| `recall!(query, k:, threshold:, types:)` | Semantic search via cosine distance. |
| `suggest!(type:, title:, description:, priority:, suggestable:)` | Create HITL suggestion. |
| `build_context(query: nil)` | Assembles system prompt from kernel + domain context + memories. |
| `domain_context` | Override hook — return domain-specific context string. |
| `agent_log(event:, payload:)` | Write to `AgentLog` for traceability. |

---

## HITL levels

| Level | Behavior |
|-------|----------|
| `:strict` | Every suggestion requires human approval before any action. Safe by default. |
| `:advisory` | Suggestions are visible; auto-applied after configured delay if not reviewed. |
| `:silent` | Suggestions logged only. No UI interruption. |

---

## Nightly Dreaming

`DreamingJob` runs every night (configurable cron) and:

1. Clusters embedded memories by cosine similarity
2. Synthesizes each cluster into a higher-level insight
3. Archives originals, saves consolidated `insight` memory
4. Optionally auto-consolidates high-confidence clusters

---

## Self-improvement Factory (Fábrica)

1. `EvolutionSuggesterAgent` analyzes logs and patterns → proposes `EvolutionItem` records
2. Developer accepts an item via Fábrica UI → `CodificadorAgent` generates Rails code
3. Developer reviews `CodeGeneration` record → applies to disk with one click
4. `EvolutionItem` status → `done`

---

## A2A agent cards

When `a2a_enabled: true`, the engine mounts 7 agent cards at `/agentkit/a2a`:

| Card | Input → Output |
|------|----------------|
| `memory_query` | `query, user_id` → top-5 similar memories |
| `suggestion_resolver` | `suggestion_id, action` → approve/reject/snooze |
| `risk_assessor` | `entity_id, entity_type` → risk score + factors |
| `velocity_predictor` | `entity_id` → velocity vs milestones |
| `client_enricher` | `client_id` → enriched data |
| `contract_addendum` | `entity_id, scope_change` → addendum draft |
| `dreaming_summary` | *(none)* → last dreaming cycle summary |

Secure with `AGENTKIT_A2A_KEY` env var → `X-A2A-Key` header.

---

## Roadmap

| Version | Features |
|---------|----------|
| **v0.1** — Kernel base | ApplicationAgent, MemoryEngine, HITLEngine, AgentTriggerable, jobs, 5-table schema |
| **v0.2** — Wizard CLI | 7-phase assessment, domain_profile.json, Rails app generator |
| **v0.3** — Fábrica | EvolutionSuggesterAgent, CodificadorAgent, Fábrica UI |
| **v0.4** — A2A + AgentSketch | A2AController, AgentSketch multi-agent workflows, MCP server |
| **v1.0** — Multi-tenant | Account model, memory scoping, vertical marketplace |

---

## License

MIT
