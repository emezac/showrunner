# frozen_string_literal: true

require "json"

module RubyA2A
  module Server
    # Rack application that exposes an A2A-compliant HTTP interface.
    #
    # Routes handled:
    #   GET  /.well-known/agent.json       → Agent Card (discovery)
    #   GET  /.well-known/agent-card.json  → Agent Card (alias)
    #   POST /                             → JSON-RPC 2.0 endpoint
    #   POST /a2a                          → JSON-RPC 2.0 endpoint (alias)
    #   GET  /tasks/:id                    → Task state query (convenience REST)
    #
    # == Streaming (SSE)
    #
    # When the JSON-RPC method is `tasks/sendSubscribe` or `message/stream`,
    # the response is sent as `text/event-stream`. Each A2A event is flushed
    # as soon as it is produced by the Executor.
    #
    # == Usage (config.ru)
    #
    #   require "ruby_a2a/server"
    #
    #   app = RubyA2A::Server::RackApp.new(
    #     executor: MyAgent.new,
    #     store:    RubyA2A::Server::TaskStore::InMemory.new
    #   )
    #   run app
    #
    class RackApp
      AGENT_CARD_PATHS = %w[
        /.well-known/agent.json
        /.well-known/agent-card.json
        /a2a/agent-card
      ].freeze

      RPC_PATHS = %w[/ /a2a /rpc /a2a/rpc].freeze

      def initialize(executor:, store: nil)
        @executor   = executor
        @store      = store || TaskStore::InMemory.new
        @dispatcher = Dispatcher.new(executor: executor, store: @store)
      end

      # @param env [Hash] Rack environment
      # @return [Array]  [status, headers, body]
      def call(env)
        method = env["REQUEST_METHOD"]
        path   = env["PATH_INFO"]

        # ── Agent Card (GET) ──────────────────────────────────────────────
        if method == "GET" && AGENT_CARD_PATHS.include?(path)
          return agent_card_response
        end

        # ── Convenience REST task query (GET /tasks/:id) ──────────────────
        if method == "GET" && (m = path.match(%r{\A/tasks/([^/]+)\z}))
          return rest_get_task(m[1])
        end

        # ── JSON-RPC (POST) ───────────────────────────────────────────────
        if method == "POST" && (RPC_PATHS.include?(path) || path.start_with?("/a2a"))
          return handle_rpc(env)
        end

        not_found_response
      end

      private

      # ------------------------------------------------------------------
      # Agent Card
      # ------------------------------------------------------------------

      def agent_card_response
        body = JSON.generate(@executor.class.agent_card_hash)
        json_response(200, body)
      end

      # ------------------------------------------------------------------
      # REST convenience
      # ------------------------------------------------------------------

      def rest_get_task(task_id)
        task = @store.get_task(task_id)
        if task
          json_response(200, JSON.generate(task))
        else
          body = JSON.generate({ "error" => "Task not found: #{task_id}" })
          json_response(404, body)
        end
      end

      # ------------------------------------------------------------------
      # JSON-RPC dispatch
      # ------------------------------------------------------------------

      def handle_rpc(env)
        raw_body = read_body(env)

        begin
          request = JSON.parse(raw_body)
        rescue JSON::ParserError => e
          err = { "jsonrpc" => "2.0", "id" => nil,
                  "error" => { "code" => -32_700, "message" => "Parse error: #{e.message}" } }
          return json_response(200, JSON.generate(err))
        end

        rpc_method = request["method"].to_s

        # Streaming path
        if streaming_method?(rpc_method)
          return handle_sse(request)
        end

        # Synchronous path
        result = @dispatcher.dispatch(request)
        json_response(200, JSON.generate(result))
      end

      def streaming_method?(method)
        method == "tasks/sendSubscribe" || method == "message/stream"
      end

      # ------------------------------------------------------------------
      # SSE streaming response
      # ------------------------------------------------------------------

      def handle_sse(request)
        rpc_id = request["id"]

        # Use Rack hijack when available (Puma, Falcon) for true streaming.
        # Fall back to a buffered body (for WEBrick / test environments).
        events_buffer = []

        sse_writer = lambda do |event_type, data|
          # Python A2A SDK expects every SSE event wrapped in JSON-RPC envelope
          rpc_envelope = {
            "jsonrpc" => "2.0",
            "id"      => rpc_id,
            "result"  => data
          }
          chunk = format_sse(event_type, rpc_envelope)
          events_buffer << chunk
        end

        result = @dispatcher.dispatch(request, sse_writer: sse_writer)

        # Append the final JSON-RPC envelope as the last SSE data line
        events_buffer << format_sse("result", result)
        events_buffer << "data: [DONE]\n\n"

        body = events_buffer.join

        [
          200,
          {
            "Content-Type"  => "text/event-stream; charset=utf-8",
            "Cache-Control" => "no-cache",
            "X-Accel-Buffering" => "no",
            "Content-Length" => body.bytesize.to_s
          },
          [body]
        ]
      end

      # ------------------------------------------------------------------
      # Helpers
      # ------------------------------------------------------------------

      def format_sse(event_type, data)
        json_data = data.is_a?(String) ? data : JSON.generate(data)
        "event: #{event_type}\ndata: #{json_data}\n\n"
      end

      def read_body(env)
        input = env["rack.input"]
        input&.read || ""
      ensure
        input&.rewind rescue nil
      end

      def json_response(status, body)
        [
          status,
          {
            "Content-Type"   => "application/json; charset=utf-8",
            "Content-Length" => body.bytesize.to_s
          },
          [body]
        ]
      end

      def not_found_response
        body = JSON.generate({ "error" => "Not Found" })
        [404, { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }, [body]]
      end
    end
  end
end
