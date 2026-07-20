# ruby-a2a

A dependency-light Ruby **client and server** for [Google's Agent-to-Agent (A2A) protocol](https://google.github.io/A2A/).

Build A2A agents entirely in Ruby — from a standalone WEBrick script to a full Rails-mounted Rack app — using only the Ruby standard library.

---

## Table of Contents

1. [Features](#features)
2. [Requirements](#requirements)
3. [Installation](#installation)
4. [Client: Quick Start](#client-quick-start)
5. [Client: Message Construction](#client-message-construction)
6. [Client: Authentication](#client-authentication)
7. [Client: Streaming (SSE)](#client-streaming-sse)
8. [Client: Task Management](#client-task-management)
9. [Client: Error Handling](#client-error-handling)
10. [Client: Configuration Reference](#client-configuration-reference)
11. [Server: Quick Start](#server-quick-start)
12. [Server: Executor DSL](#server-executor-dsl)
13. [Server: TaskContext API](#server-taskcontext-api)
14. [Server: Rack / Rails Mount](#server-rack--rails-mount)
15. [Server: Authentication Middleware](#server-authentication-middleware)
16. [Server: TaskStore](#server-taskstore)
17. [Server: HTTP Endpoints](#server-http-endpoints)
18. [Server: Streaming (SSE)](#server-streaming-sse)
19. [Server: Full Example](#server-full-example)
20. [Architecture Overview](#architecture-overview)
21. [License](#license)

---

## Features

### Client
- **PORO-first** — no required inheritance, no monkey-patching
- **Zero runtime dependencies** — uses only Ruby stdlib (`net/http`, `openssl`, `json`, `uri`, `base64`, `logger`)
- **Secure by default** — TLS 1.2+ enforced, certificate verification always on
- **Polling & SSE streaming** — first-class async support
- **Pluggable authentication** — Bearer Token, API Key, optional OAuth2
- **Typed error hierarchy** — all A2A protocol errors map to typed Ruby exceptions

### Server
- **Rack-compatible** — mount in Rails, Sinatra, Puma, or run standalone with WEBrick
- **JSON-RPC 2.0** — full protocol compliance with standard error codes
- **Declarative DSL** — define agents with `agent_name`, `skill`, `capabilities` class macros
- **SSE streaming** — `tasks/sendSubscribe` with chunked artifact emission
- **Pluggable TaskStore** — in-memory default, swap for Redis/ActiveRecord
- **Auth middleware** — Bearer Token or API Key validation via injectable lambda
- **A2A Agent Card** — auto-generated from DSL at `GET /.well-known/agent.json`

---

## Requirements

- Ruby >= 3.2

---

## Installation

```ruby
# Gemfile
gem "ruby-a2a"
```

```bash
bundle install
```

---

## Client: Quick Start

```ruby
require "ruby_a2a"

RubyA2A.configure do |c|
  c.poll_interval     = 2.0
  c.max_poll_attempts = 30
  c.logger            = Logger.new($stdout)
end

auth   = RubyA2A::Auth::BearerToken.new(ENV["AGENT_TOKEN"])
client = RubyA2A::Client.new("https://agent.example.com", auth: auth)

# Discover the Agent Card
card = client.agent_card
puts card.streaming?   # => true / false
puts card.skills       # => Array of skill hashes

# Send a message — polls automatically until terminal state
task = client.send_message("What is the capital of France?")
puts task.state        # => "TASK_STATE_COMPLETED"
puts task.artifacts    # => Array of artifact hashes
```

---

## Client: Message Construction

```ruby
# Convenience: from a plain String
client.send_message("Hello, agent!")

# Text part
part = RubyA2A::Models::Part.text("Analyze this text.")

# Structured JSON data part
part = RubyA2A::Models::Part.data({ "metric" => 42, "env" => "prod" })

# Raw binary part (Base64-encoded automatically)
part = RubyA2A::Models::Part.raw(
  File.binread("report.pdf"),
  filename:   "report.pdf",
  media_type: "application/pdf"
)

# External URL reference part
part = RubyA2A::Models::Part.url(
  "https://example.com/doc.pdf",
  media_type: "application/pdf"
)

# Compose a multi-part message
message = RubyA2A::Models::Message.new("ROLE_USER", [text_part, data_part, url_part])
task = client.send_message(message)
```

---

## Client: Authentication

```ruby
# Bearer Token (Authorization: Bearer <token>)
auth = RubyA2A::Auth::BearerToken.new(ENV["AGENT_TOKEN"])

# API Key — default header: X-API-Key
auth = RubyA2A::Auth::ApiKey.new(ENV["AGENT_KEY"])

# API Key — custom header
auth = RubyA2A::Auth::ApiKey.new(ENV["AGENT_KEY"], header: "X-My-Auth")

# OAuth2 — requires gem "oauth2", "~> 2.0" in your Gemfile
token = oauth2_client.client_credentials.get_token
auth  = RubyA2A::Auth::OAuth2.new(token)

client = RubyA2A::Client.new("https://agent.example.com", auth: auth)
```

---

## Client: Streaming (SSE)

```ruby
# stream_message yields each Server-Sent Event as a Hash
client.stream_message("Generate a report") do |event|
  case
  when event["statusUpdate"]
    puts "[Status] #{event['statusUpdate']['message']}"
  when event["artifactUpdate"]
    u = event["artifactUpdate"]
    print u.dig("artifact", "parts", 0, "text")
  end
end

# Without a block — returns an Enumerator
enum = client.stream_message("Generate a report")
enum.each { |e| process(e) }

# Subscribe to an existing task's events
client.subscribe_to_task("task-abc-123") do |event|
  puts event.inspect
end
```

---

## Client: Task Management

```ruby
# Fetch current state of a task
task = client.get_task("task-abc-123")
puts task.state       # => "TASK_STATE_WORKING"
puts task.terminal?   # => false

# Cancel a task
canceled = client.cancel_task("task-abc-123")
puts canceled.state   # => "TASK_STATE_CANCELED"

# Manual polling loop
task = client.poll_until_complete("task-abc-123")
task.artifacts.each do |artifact|
  artifact["parts"].each { |p| puts p["text"] }
end
```

---

## Client: Error Handling

```ruby
begin
  task = client.send_message("Hello")

rescue RubyA2A::AuthRequiredError => e
  # Task paused — needs user to complete an OAuth / auth flow
  puts "Auth needed for task #{e.task.task_id}"

rescue RubyA2A::PollingTimeoutError => e
  puts "Gave up after #{e.attempts} attempts for task #{e.task_id}"

rescue RubyA2A::TaskNotFoundError => e
  puts "Task not found. Reason: #{e.reason}"

rescue RubyA2A::TaskNotCancelableError => e
  puts "Cannot cancel: #{e.message}"

rescue RubyA2A::UnsupportedOperationError => e
  puts "Agent doesn't support that: #{e.message}"

rescue RubyA2A::AgentCardNotFoundError => e
  puts "No agent card found at #{agent_url}"

rescue RubyA2A::TLSRequiredError => e
  puts "Must use HTTPS: #{e.message}"

rescue RubyA2A::A2AProtocolError => e
  # Catch-all for unknown A2A errors
  puts "Protocol error (#{e.reason}): #{e.message}"
end
```

---

## Client: Configuration Reference

| Key                   | Default                     | Description                             |
|-----------------------|-----------------------------|-----------------------------------------|
| `timeout`             | `30`                        | General socket timeout (seconds)        |
| `open_timeout`        | `10`                        | TCP connection timeout (seconds)        |
| `read_timeout`        | `30`                        | Read timeout (seconds)                  |
| `poll_interval`       | `1.0`                       | Seconds between polling iterations      |
| `max_poll_attempts`   | `60`                        | Maximum polling iterations before error |
| `a2a_version`         | `"1.0"`                     | Value of the `A2A-Version` header       |
| `logger`              | `Logger.new($stdout, WARN)` | Ruby `Logger` instance                  |
| `minimum_tls_version` | `TLS1_2_VERSION`            | Minimum TLS version (`TLS1_2`, `TLS1_3`)|

---

## Server: Quick Start

```ruby
require "ruby_a2a/server"

class EchoAgent < RubyA2A::Server::Executor
  agent_name        "EchoAgent"
  agent_description "Echoes back any message sent to it."
  agent_url         "http://localhost:8080"
  capabilities      streaming: false

  skill id:          "echo",
        name:        "Echo",
        description: "Returns the user's message verbatim.",
        tags:        ["demo"]

  def handle_task(params, context)
    text = params.dig("message", "parts", 0, "text") || ""
    context.update_status("working")
    context.complete!(build_agent_message(build_text_part("Echo: #{text}")))
  end
end

server = RubyA2A::Server::HttpServer.new(
  executor: EchoAgent.new,
  port:     8080
)
server.start
```

```bash
ruby my_agent.rb

# Discover
curl http://localhost:8080/.well-known/agent.json

# Send a task
curl -X POST http://localhost:8080/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tasks/send",
    "params": {
      "message": {
        "role": "ROLE_USER",
        "parts": [{ "text": "Hello!" }]
      }
    }
  }'
```

---

## Server: Executor DSL

Inherit from `RubyA2A::Server::Executor` and use the class-level DSL to declare metadata:

```ruby
class MyAgent < RubyA2A::Server::Executor
  # ── Metadata ──────────────────────────────────────────────────────────────
  agent_name        "MyAgent"
  agent_description "A production-ready A2A agent written in Ruby."
  agent_url         "https://myagent.example.com"
  protocol_version  "0.2.1"          # default: "0.2.1"

  # ── Capabilities (serialized into the Agent Card) ─────────────────────────
  capabilities streaming:          true,
               push_notifications: false

  # ── Skills (declare one or more) ──────────────────────────────────────────
  skill id:          "summarize",
        name:        "Summarize Text",
        description: "Returns a concise summary of the provided text.",
        tags:        ["nlp", "text"],
        examples:    ["Summarize this article: ..."]

  skill id:   "translate",
        name: "Translate",
        description: "Translates text to a target language.",
        tags: ["nlp", "i18n"]

  # ── Auth scheme (optional) ────────────────────────────────────────────────
  # :none (default), :bearer_token, or :api_key
  auth_scheme :bearer_token

  # ── Task handler ──────────────────────────────────────────────────────────
  def handle_task(params, context)
    # params is the full JSON-RPC `params` hash from the client
    text = params.dig("message", "parts", 0, "text") || ""

    # Notify client the agent is working
    context.update_status("working", message: { "text" => "Processing..." })

    # Do your work (call an LLM, run Aflow, query a DB, etc.)
    result = my_llm.call(text)

    # Build the response using convenience helpers
    reply = build_agent_message(build_text_part(result))

    # Complete the task — writes to store and sends final SSE event
    context.complete!(reply)
  end

  private

  def my_llm
    # inject your LLM client here
  end
end
```

### DSL Reference

| Macro | Arguments | Description |
|---|---|---|
| `agent_name` | `String` | Agent's display name (required for Agent Card) |
| `agent_description` | `String` | Short description |
| `agent_url` | `String` | Public URL of the agent |
| `protocol_version` | `String` | A2A protocol version (default `"0.2.1"`) |
| `capabilities` | `Hash` | Capability flags (`streaming:`, `push_notifications:`) |
| `skill` | `Hash` | Declare a skill (`id:`, `name:`, `description:`, `tags:`, `examples:`) |
| `auth_scheme` | `:none` / `:bearer_token` / `:api_key` | Advertised auth in Agent Card |

### Instance Helpers (available inside `handle_task`)

| Method | Description |
|---|---|
| `build_text_part(text)` | Creates a `Models::Part` with text content |
| `build_data_part(data)` | Creates a `Models::Part` with JSON-serializable data |
| `build_agent_message(*parts)` | Creates a `Models::Message` with role `ROLE_AGENT` |

---

## Server: TaskContext API

`context` is passed as the second argument to `handle_task`. It drives the task lifecycle:

```ruby
def handle_task(params, context)
  # 1. Transition to a working state
  context.update_status("working")
  context.update_status("working", message: { "text" => "Step 1/3..." })

  # 2. Emit streaming artifact chunks (SSE only — no-op in synchronous mode)
  context.emit_artifact_chunk("output-1", "Partial text chunk...", index: 0)
  context.emit_artifact_chunk("output-1", " more text...",         index: 1, append: true)

  # 3a. Complete successfully
  reply = build_agent_message(build_text_part("Done!"))
  context.complete!(reply)

  # 3b. Or fail explicitly
  context.fail!("Something went wrong: could not reach upstream service")
end
```

### `context` Method Reference

| Method | Description |
|---|---|
| `context.task_id` | The UUID of the current task |
| `context.update_status(state, message: nil)` | Transition state (`"working"`, `"input-required"`, …) |
| `context.emit_artifact_chunk(id, text, index: 0, append: false)` | Emit SSE chunk; no-op in sync mode |
| `context.complete!(message)` | Mark task `completed`, save artifact, send final SSE |
| `context.fail!(reason)` | Mark task `failed` with error message |

### Valid A2A States

`"submitted"` → `"working"` → `"completed"` / `"failed"` / `"canceled"` / `"input-required"`

---

## Server: Rack / Rails Mount

### Standalone `config.ru`

```ruby
# config.ru
require "ruby_a2a/server"
require_relative "my_agent"

store = RubyA2A::Server::TaskStore::InMemory.new
app   = RubyA2A::Server::RackApp.new(executor: MyAgent.new, store: store)

run app
```

```bash
bundle exec rackup -p 8080
```

### Rails routes

```ruby
# config/routes.rb
require "ruby_a2a/server"
require_relative "app/agents/my_agent"

Rails.application.routes.draw do
  mount RubyA2A::Server::RackApp.new(executor: MyAgent.new), at: "/a2a"
end
```

The agent card will be at `GET /a2a/.well-known/agent.json` and the RPC endpoint at `POST /a2a/`.

---

## Server: Authentication Middleware

Wrap the `RackApp` with `AuthMiddleware` to gate all JSON-RPC calls behind a token check:

```ruby
require "ruby_a2a/server"

store    = RubyA2A::Server::TaskStore::InMemory.new
rack_app = RubyA2A::Server::RackApp.new(executor: MyAgent.new, store: store)

# Bearer Token validation
protected_app = RubyA2A::Server::AuthMiddleware.new(
  rack_app,
  validator: ->(token) { token == ENV.fetch("AGENT_SECRET") },
  scheme:    :bearer_token   # or :api_key
)

# config.ru
run protected_app
```

The Agent Card endpoint (`GET /.well-known/agent.json`) is **always public** and bypasses authentication.

**Client request with auth:**
```bash
curl -X POST http://localhost:8080/ \
  -H "Authorization: Bearer my-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tasks/send","params":{...}}'
```

**Unauthenticated response (HTTP 401):**
```json
{
  "jsonrpc": "2.0",
  "id": null,
  "error": {
    "code": -32600,
    "message": "Unauthorized: valid authentication credentials are required"
  }
}
```

---

## Server: TaskStore

`TaskStore::InMemory` is the default. Implement the same interface to use Redis, ActiveRecord, or any other backend:

```ruby
class MyRedisTaskStore
  def save_task(task)
    # task is a Hash with string keys and a "taskId" field
    redis.set("task:#{task['taskId']}", task.to_json)
    task
  end

  def get_task(id)
    raw = redis.get("task:#{id}")
    raw ? JSON.parse(raw) : nil
  end

  def update_task_status(id, status)
    task = get_task(id)
    return nil unless task
    updated = task.merge("status" => task.fetch("status", {}).merge(status))
    save_task(updated)
  end

  def all_tasks
    # ...
  end

  private

  def redis
    @redis ||= Redis.new
  end
end

# Use it
store = MyRedisTaskStore.new
app   = RubyA2A::Server::RackApp.new(executor: MyAgent.new, store: store)
```

### TaskStore Interface

| Method | Signature | Description |
|---|---|---|
| `save_task` | `(task_hash) → task_hash` | Persist a new or updated task |
| `get_task` | `(id) → Hash \| nil` | Fetch by task ID |
| `update_task_status` | `(id, status_hash) → Hash \| nil` | Merge into existing status sub-object |
| `all_tasks` | `() → Array<Hash>` | Return all stored tasks |

---

## Server: HTTP Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/.well-known/agent.json` | Agent Card (always public) |
| `GET` | `/.well-known/agent-card.json` | Agent Card (alias) |
| `POST` | `/` | JSON-RPC 2.0 endpoint |
| `POST` | `/a2a` | JSON-RPC 2.0 endpoint (alias) |
| `POST` | `/a2a/rpc` | JSON-RPC 2.0 endpoint (alias) |
| `GET` | `/tasks/:id` | REST convenience — returns raw task hash |

### Supported JSON-RPC Methods

| Method | Description |
|---|---|
| `tasks/send` | Synchronous task execution |
| `tasks/sendSubscribe` | Streaming task execution (SSE response) |
| `message/send` | Alias for `tasks/send` |
| `message/stream` | Alias for `tasks/sendSubscribe` |
| `tasks/get` | Fetch task by ID |
| `tasks/cancel` | Cancel a non-terminal task |

### JSON-RPC Error Codes

| Code | Constant | Meaning |
|---|---|---|
| `-32700` | `PARSE_ERROR` | Malformed JSON in request body |
| `-32600` | `INVALID_REQUEST` | Missing `jsonrpc`/`method`, or bad envelope |
| `-32601` | `METHOD_NOT_FOUND` | Unsupported A2A method |
| `-32602` | `INVALID_PARAMS` | Missing required params (e.g., `id` for `tasks/get`) |
| `-32603` | `INTERNAL_ERROR` | Unhandled executor exception |
| `-32000` | `TASK_NOT_FOUND` | No task with that ID in the store |
| `-32001` | `TASK_NOT_CANCELABLE` | Task is already in a terminal state |

---

## Server: Streaming (SSE)

Use `tasks/sendSubscribe` (or `message/stream`) to receive incremental updates:

```bash
curl -X POST http://localhost:8080/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tasks/sendSubscribe",
    "params": {
      "message": {
        "role": "ROLE_USER",
        "parts": [{ "text": "Write me a poem" }]
      }
    }
  }'
```

**Response (`Content-Type: text/event-stream`):**
```
event: TaskStatusUpdateEvent
data: {"taskId":"...","status":{"state":"submitted"},"final":false}

event: TaskStatusUpdateEvent
data: {"taskId":"...","status":{"state":"working"},"final":false}

event: TaskArtifactUpdateEvent
data: {"taskId":"...","artifact":{"artifactId":"output-1","parts":[{"text":"Roses are red,"}],"index":0},"final":false}

event: TaskArtifactUpdateEvent
data: {"taskId":"...","artifact":{"artifactId":"output-1","parts":[{"text":" violets are blue"}],"index":1,"append":true},"final":false}

event: TaskStatusUpdateEvent
data: {"taskId":"...","status":{"state":"completed"},"final":true}

event: result
data: {"jsonrpc":"2.0","id":1,"result":{...}}

data: [DONE]
```

**Inside `handle_task` — emit streaming chunks:**
```ruby
def handle_task(params, context)
  context.update_status("working")

  ["Line 1...", " Line 2...", " Line 3."].each_with_index do |chunk, i|
    context.emit_artifact_chunk("poem", chunk, index: i, append: i > 0)
    sleep 0.1  # simulate LLM token streaming
  end

  context.complete!(build_agent_message(build_text_part("Line 1... Line 2... Line 3.")))
end
```

---

## Server: Full Example

`example_server.rb` — a complete, runnable agent (included in the repo):

```ruby
require "ruby_a2a/server"

class PepitoAgent < RubyA2A::Server::Executor
  agent_name        "Pepito el Chistoso"
  agent_description "Agente contador de chistes en español."
  agent_url         "http://localhost:8080"
  capabilities      streaming: true, push_notifications: false

  skill id:          "tell_joke",
        name:        "Contar Chiste",
        description: "Genera un chiste original en español.",
        tags:        %w[humor entretenimiento],
        examples:    ["Cuéntame un chiste de programadores"]

  JOKES = {
    "programadores" => "¿Por qué los programadores prefieren el modo oscuro? ¡Porque la luz atrae a los bugs! 🤣",
    "animales"      => "¿Qué le dijo el perro al hueso? '¡Eres el hueso de mi vida!' 🤣"
  }.freeze

  def handle_task(params, context)
    text  = params.dig("message", "parts", 0, "text") || ""
    topic = JOKES.keys.find { |k| text.downcase.include?(k) }
    joke  = JOKES[topic] || "¡No entiendo, pero aquí va un chiste! ¿Por qué el libro de matemáticas está triste? ¡Porque tiene muchos problemas! 🤣"

    context.update_status("working", message: { "text" => "Buscando el chiste perfecto..." })
    context.complete!(build_agent_message(build_text_part(joke)))
  end
end

server = RubyA2A::Server::HttpServer.new(executor: PepitoAgent.new, port: 8080)

trap("INT")  { server.shutdown }
trap("TERM") { server.shutdown }

server.start
```

```bash
ruby -I lib example_server.rb

curl http://localhost:8080/.well-known/agent.json

curl -X POST http://localhost:8080/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tasks/send",
    "params": {
      "message": {
        "role": "ROLE_USER",
        "parts": [{ "text": "Cuéntame un chiste de programadores" }]
      }
    }
  }'
```

---

## Architecture Overview

```
ruby-a2a
├── lib/
│   ├── ruby_a2a.rb                    # Client entry point
│   ├── ruby_a2a/
│   │   ├── configuration.rb           # Global config (timeouts, logger, TLS)
│   │   ├── errors.rb                  # Typed exception hierarchy
│   │   ├── agent_card.rb              # AgentCard model (client-side)
│   │   ├── client.rb                  # RubyA2A::Client
│   │   ├── auth/
│   │   │   ├── bearer_token.rb        # Auth::BearerToken
│   │   │   ├── api_key.rb             # Auth::ApiKey
│   │   │   └── oauth2.rb              # Auth::OAuth2 (optional)
│   │   ├── http/
│   │   │   ├── base.rb                # HTTP adapter (net/http)
│   │   │   └── sse_reader.rb          # Server-Sent Events parser
│   │   ├── models/
│   │   │   ├── part.rb                # Models::Part (text/data/raw/url)
│   │   │   ├── message.rb             # Models::Message
│   │   │   ├── task.rb                # Models::Task
│   │   │   ├── artifact.rb            # Models::Artifact
│   │   │   └── artifact_processor.rb  # Artifact assembly from SSE chunks
│   │   ├── server.rb                  # Server opt-in entry point
│   │   └── server/
│   │       ├── executor.rb            # Executor (base class + DSL) + TaskContext
│   │       ├── dispatcher.rb          # JSON-RPC 2.0 router
│   │       ├── rack_app.rb            # Rack application
│   │       ├── http_server.rb         # WEBrick standalone wrapper
│   │       ├── task_store.rb          # TaskStore::InMemory (pluggable)
│   │       └── auth_middleware.rb     # Rack auth middleware
├── example.rb                         # Client usage demo
└── example_server.rb                  # Server usage demo (Pepito el Chistoso)
```

### Request Lifecycle (server)

```
HTTP Request
     │
     ▼
RackApp#call
     │
     ├─ GET /.well-known/agent.json ──► Executor.agent_card_hash → JSON
     │
     ├─ GET /tasks/:id ───────────────► TaskStore#get_task → JSON
     │
     └─ POST / ────────────────────────► parse JSON-RPC body
                                              │
                                         Dispatcher#dispatch
                                              │
                                    ┌─────────┴──────────┐
                                    │                    │
                               tasks/send          tasks/sendSubscribe
                                    │                    │
                              TaskContext          TaskContext (SSE)
                                    │                    │
                            Executor#handle_task  Executor#handle_task
                                    │                    │
                             TaskStore (write)    TaskStore + SSE events
                                    │                    │
                            JSON-RPC response     text/event-stream body
```

---

## License

MIT
