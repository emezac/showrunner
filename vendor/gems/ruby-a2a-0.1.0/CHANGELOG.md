# Changelog

All notable changes to `ruby-a2a` will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

## [0.1.0] — 2026-05-02

### Added

- `RubyA2A.configure` / `RubyA2A.configuration` — global configuration
- `RubyA2A::Client.new(base_url, auth:)` — HTTPS-only client with TLS enforcement
- `RubyA2A::Client#agent_card` — Agent Card discovery with fallback path
- `RubyA2A::Client#send_message` — send message + automatic polling
- `RubyA2A::Client#stream_message` — SSE streaming via block or Enumerator
- `RubyA2A::Client#get_task` / `#cancel_task` — task lifecycle management
- `RubyA2A::Client#subscribe_to_task` — SSE task subscription
- `RubyA2A::Client#poll_until_complete` — configurable polling loop
- `RubyA2A::Models::Message` — role + parts message model with camelCase serialization
- `RubyA2A::Models::Part` — text / data / raw / url content parts
- `RubyA2A::Models::Task` — task model with `terminal?` and `auth_required?`
- `RubyA2A::Models::Artifact` + `ArtifactProcessor` — artifact streaming with append support
- `RubyA2A::AgentCard` — agent card model with `streaming?`
- `RubyA2A::Auth::BearerToken` — Bearer Token strategy
- `RubyA2A::Auth::ApiKey` — API Key header strategy
- `RubyA2A::Auth::OAuth2` — optional OAuth2 strategy (requires `oauth2 ~> 2.0`)
- `RubyA2A::Http::Base` — stdlib-only HTTP layer (`net/http` + `openssl`)
- `RubyA2A::Http::SseReader` — Server-Sent Events parser with partial chunk handling
- Full typed error hierarchy: `TLSRequiredError`, `AgentCardNotFoundError`,
  `AuthRequiredError`, `PollingTimeoutError`, `A2AProtocolError` and subtypes
- A2A protocol error reason → typed exception mapping
- Unit and integration test suite (RSpec + WebMock)
- CI workflow (GitHub Actions, Ruby 3.2)
