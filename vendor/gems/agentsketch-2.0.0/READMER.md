# AgentSketch

**Declarative Multi-Agent Orchestration DSL for Ruby**

> *"Describe qué deben hacer los agentes. AgentSketch decide cómo."*

AgentSketch es un DSL Ruby que actúa como orquestador de intención: el usuario declara agentes, herramientas, memoria y flujos de trabajo en términos semánticos del dominio. El runtime —construido sobre [`aflow`](https://github.com/aflow-rb/aflow), [`ruby_llm`](https://rubyllm.com) y [`ruby-a2a`](https://github.com/ruby-a2a/ruby-a2a)— traduce esas declaraciones a llamadas LLM, embeddings, búsquedas vectoriales y políticas de retry.

```ruby
result = AgentSketch.run(input: "Investiga y escribe un artículo sobre LLMs en 2025") do

  agent :researcher do
    model   "gpt-4o"
    role    "Investigador experto en tecnología"
    tools   [:web_search, :rag]
    memory  :sliding_window, size: 10
    retry   max: 3, backoff: :exponential
  end

  agent :writer do
    model         "claude-sonnet-4-6"
    role          "Escritor técnico de alta calidad"
    output_format :markdown
    memory        :full
  end

  workflow { researcher >> writer }
end

puts result.output
puts result.cost_summary
```

---

## Requisitos

- Ruby >= 3.2
- Gemas core: `aflow`, `ruby_llm`, `ruby-a2a` (solo para A2A)

## Instalación

```ruby
# Gemfile
gem "agentsketch"
```

```bash
bundle install
```

---

## Configuración

```ruby
AgentSketch.configure do |c|
  c.llm do |llm|
    llm.openai_api_key    = ENV["OPENAI_API_KEY"]
    llm.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
    llm.ollama_api_base   = "http://localhost:11434"
  end

  # Para RAG y memoria episódica
  c.vector :pgvector, connection: ENV["DATABASE_URL"]

  # Observabilidad
  c.tracing :file, path: "./traces/"
end
```

---

## Workflows

### Secuencial `>>`
```ruby
workflow { researcher >> fact_checker >> writer >> editor }
```

### Paralelo `||`
```ruby
workflow do
  (research_tech || research_market || research_legal) >> synthesizer
end
```

### Condicional `route`
```ruby
workflow do
  classifier >> route { |ctx|
    case ctx[:category]
    when "technical" then tech_writer
    else                  general_writer
    end
  }
end
```

### Bucle `loop_until`
```ruby
workflow do
  loop_until(max: 5, condition: ->(ctx) { ctx[:quality_score].to_i >= 8 }) do
    writer >> critic
  end >> publisher
end
```

---

## Herramientas built-in

| Herramienta | Descripción |
|---|---|
| `:web_search` | Búsqueda web (Tavily, SerpAPI, DuckDuckGo) |
| `:rag` | Búsqueda semántica en vector store (pgvector, Qdrant) |
| `:calculator` | Evaluación matemática segura |
| `:text_editor` | Buffer de texto mutable para escritura iterativa |
| `:file_reader` | Lectura de archivos locales (txt, md, csv, json) |
| `:code_runner` | Ejecución de código en subprocess/Docker |
| `:image_analyzer` | Análisis multimodal de imágenes (modelos con visión) |
| `:memory_search` | Búsqueda semántica en memoria episódica del agente |

### Herramienta personalizada

```ruby
tool :database_query do
  description "Ejecuta una consulta SQL de solo lectura"
  param :query, desc: "SQL SELECT válido"

  execute do |query:|
    DB.query(query).map(&:to_h)
  end
end
```

---

## Memoria

```ruby
memory :sliding_window, size: 10   # últimos N mensajes
memory :full                        # historial completo
memory :summarize, every: 5        # resume cada N turnos
memory :episodic, top_k: 3        # embeddings + búsqueda semántica
memory :none                        # stateless
```

---

## Resiliencia

```ruby
agent :unreliable do
  model    "gpt-4o"
  retry    max: 3, backoff: :exponential
  timeout  60
  fallback :economy_agent
end
```

---

## Comunicación inter-agente — A2A

### Exponer workflow como servidor A2A

```ruby
AgentSketch.serve_a2a(
  port: 4567,
  name: "Research & Write Agent"
) do
  agent :researcher do ... end
  agent :writer     do ... end
  workflow { researcher >> writer }
end
```

### Consumir agente A2A externo como herramienta

```ruby
AgentSketch::A2A::ClientTool.register(
  name:  :legal_agent,
  url:   "https://legal-agent.internal.com",
  token: ENV["LEGAL_AGENT_TOKEN"]
)

AgentSketch.run(input: "...") do
  agent :coordinator do
    tools [:legal_agent, :web_search]
  end
  workflow { coordinator }
end
```

---

## Servidor MCP

```ruby
AgentSketch.serve_mcp(
  name:        "research_workflow",
  description: "Investiga y escribe artículos"
) do
  agent :researcher do ... end
  agent :writer     do ... end
  workflow { researcher >> writer }
end
```

---

## Ingesta de documentos para RAG

```ruby
AgentSketch.ingest do
  source :directory, path: "./docs/", recursive: true
  source :url,       urls: ["https://docs.example.com"]
  chunk_size    512
  chunk_overlap 64
  into :pgvector, table: "documents"
end
```

---

## Tracing y replay

```ruby
result = AgentSketch.run(input: "...") { ... }

# Acceder al trace
result.trace.events.each do |event|
  puts "#{event.step_id}: #{event.status} (#{event.duration_ms}ms)"
end

# Replay — reutiliza outputs del trace anterior sin re-ejecutar
result2 = AgentSketch.run(input: "...", replay_trace: result.trace) { ... }
```

---

## Dry run — preview del DAG

```ruby
result = AgentSketch.run(dry_run: true, input: "...") do
  agent :a do ... end
  agent :b do ... end
  workflow { a >> b }
end

puts result.output  # ASCII diagram of the DAG
```

---

## Stack

| Necesidad | Solución |
|---|---|
| LLM adapters | `ruby_llm` — OpenAI, Anthropic, Ollama, Gemini, Groq, Mistral… |
| Tool calling + ReAct loop | `RubyLLM::Tool`, `RubyLLM::Agent` |
| Embeddings | `RubyLLM.embed` |
| Orquestación DAG | `Aflow::Flow` — sequential, parallel, condition, loop |
| Tracing + replay | `Aflow::Trace` |
| Retry, timeout, fallback | `Aflow::Step.config` |
| MCP server | `Aflow::MCP::Server` |
| A2A inter-agent | `ruby-a2a` |

**Sin Python. Sin subprocesos. Sin IPC.**

---

## Ejemplos

Ver el directorio `examples/`:

- `research_and_write.rb` — researcher >> writer (básico)
- `parallel_research.rb` — investigación paralela en tres frentes
- `customer_support.rb` — loop_until con critic
- `a2a_server.rb` — exponer workflow como servidor A2A
- `a2a_bridge.rb` — consumir agente A2A externo
- `mcp_server.rb` — exponer como servidor MCP

---

## Desarrollo

```bash
bundle install
bundle exec rspec
```

---

## Licencia

MIT
