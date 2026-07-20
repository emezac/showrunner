# frozen_string_literal: true

require "json"
require "securerandom"

module RubyA2A
  module Server
    # JSON-RPC 2.0 dispatcher.
    #
    # Receives a parsed Hash representing a JSON-RPC request and routes it
    # to the appropriate A2A method on the Executor. Returns a JSON-RPC
    # response Hash (never raises — errors become JSON-RPC error objects).
    #
    # Supported A2A methods:
    #   tasks/send            → synchronous execution
    #   tasks/sendSubscribe   → streaming (SSE) execution
    #   tasks/get             → task status query
    #   tasks/cancel          → task cancellation
    #
    class Dispatcher
      # JSON-RPC 2.0 standard error codes
      PARSE_ERROR      = -32_700
      INVALID_REQUEST  = -32_600
      METHOD_NOT_FOUND = -32_601
      INVALID_PARAMS   = -32_602
      INTERNAL_ERROR   = -32_603

      # A2A application-level error codes
      TASK_NOT_FOUND   = -32_000
      TASK_NOT_CANCEL  = -32_001

      SUPPORTED_METHODS = %w[
        tasks/send
        tasks/sendSubscribe
        tasks/get
        tasks/cancel
        message/send
        message/stream
      ].freeze

      def initialize(executor:, store:)
        @executor = executor
        @store    = store
      end

      # Dispatches a single JSON-RPC request hash.
      #
      # @param request [Hash]         parsed JSON-RPC body
      # @param sse_writer [#call, nil] callable(event_type, data_hash) for SSE
      # @return [Hash]                JSON-RPC response envelope
      def dispatch(request, sse_writer: nil)
        unless request.is_a?(Hash)
          return error_response(nil, INVALID_REQUEST, "Invalid Request: body must be a JSON object")
        end

        rpc_id  = request["id"]
        jsonrpc = request["jsonrpc"]
        method  = request["method"]
        params  = request["params"] || {}

        # Validate JSON-RPC 2.0 envelope
        if jsonrpc != "2.0"
          return error_response(rpc_id, INVALID_REQUEST,
                                "Invalid Request: 'jsonrpc' must be '2.0'")
        end

        if method.nil? || method.to_s.strip.empty?
          return error_response(rpc_id, INVALID_REQUEST, "Invalid Request: 'method' is required")
        end

        unless SUPPORTED_METHODS.include?(method)
          return error_response(rpc_id, METHOD_NOT_FOUND,
                                "Method not found: '#{method}' is not a supported A2A method")
        end

        route(rpc_id, method, params, sse_writer)
      rescue JSON::ParserError => e
        error_response(nil, PARSE_ERROR, "Parse error: #{e.message}")
      rescue StandardError => e
        error_response(rpc_id, INTERNAL_ERROR, "Internal error: #{e.message}")
      end

      private

      # ------------------------------------------------------------------
      # Routing
      # ------------------------------------------------------------------

      def route(rpc_id, method, params, sse_writer)
        case method
        when "tasks/send", "message/send"
          handle_tasks_send(rpc_id, params, sse_writer: nil)
        when "tasks/sendSubscribe", "message/stream"
          handle_tasks_send(rpc_id, params, sse_writer: sse_writer)
        when "tasks/get"
          handle_tasks_get(rpc_id, params)
        when "tasks/cancel"
          handle_tasks_cancel(rpc_id, params)
        end
      end

      # ------------------------------------------------------------------
      # tasks/send  (synchronous execution)
      # ------------------------------------------------------------------

      def handle_tasks_send(rpc_id, params, sse_writer:)
        task_id = params.dig("id") || SecureRandom.uuid

        # Bootstrap the task in the store
        message = (params["message"] || {}).dup
        message["messageId"] ||= SecureRandom.uuid
        message["role"] = message["role"].to_s.downcase

        initial_task = {
          "id"         => task_id,
          "contextId"  => params["contextId"] || SecureRandom.uuid,
          "status"     => { "state" => "submitted" },
          "artifacts"  => [],
          "history"    => [message]
        }
        @store.save_task(initial_task)

        context = TaskContext.new(
          task_id:    task_id,
          store:      @store,
          sse_writer: sse_writer
        )

        # Notify submitted state via SSE immediately
        if sse_writer
          context_id = initial_task["contextId"] || ""
          sse_writer.call("TaskStatusUpdateEvent", {
            "taskId"    => task_id,
            "contextId" => context_id,
            "status"    => { "state" => "submitted" },
            "final"     => false
          })
        end

        @executor.handle_task(params, context)

        final_task = @store.get_task(task_id)
        success_response(rpc_id, final_task)
      rescue StandardError => e
        context&.fail!(e.message) rescue nil
        error_response(rpc_id, INTERNAL_ERROR, "Executor error: #{e.message}")
      end

      # ------------------------------------------------------------------
      # tasks/get
      # ------------------------------------------------------------------

      def handle_tasks_get(rpc_id, params)
        task_id = params["id"] || params["taskId"]

        unless task_id
          return error_response(rpc_id, INVALID_PARAMS, "Invalid params: 'id' is required for tasks/get")
        end

        task = @store.get_task(task_id)

        unless task
          return error_response(rpc_id, TASK_NOT_FOUND,
                                "Task not found: '#{task_id}'",
                                reason: "TASK_NOT_FOUND")
        end

        success_response(rpc_id, task)
      end

      # ------------------------------------------------------------------
      # tasks/cancel
      # ------------------------------------------------------------------

      def handle_tasks_cancel(rpc_id, params)
        task_id = params["id"] || params["taskId"]

        unless task_id
          return error_response(rpc_id, INVALID_PARAMS, "Invalid params: 'id' is required for tasks/cancel")
        end

        task = @store.get_task(task_id)

        unless task
          return error_response(rpc_id, TASK_NOT_FOUND,
                                "Task not found: '#{task_id}'",
                                reason: "TASK_NOT_FOUND")
        end

        state = task.dig("status", "state")
        terminal_states = %w[completed failed canceled]

        if terminal_states.include?(state)
          return error_response(rpc_id, TASK_NOT_CANCEL,
                                "Task is not cancelable: already in state '#{state}'",
                                reason: "TASK_NOT_CANCELABLE")
        end

        updated = @store.update_task_status(task_id, { "state" => "canceled" })
        success_response(rpc_id, updated)
      end

      # ------------------------------------------------------------------
      # Response builders
      # ------------------------------------------------------------------

      def success_response(id, result)
        { "jsonrpc" => "2.0", "id" => id, "result" => result }
      end

      def error_response(id, code, message, reason: nil)
        error = { "code" => code, "message" => message }
        if reason
          error["data"] = {
            "details" => [{
              "@type"  => "type.googleapis.com/google.rpc.ErrorInfo",
              "reason" => reason
            }]
          }
        end
        { "jsonrpc" => "2.0", "id" => id, "error" => error }
      end
    end
  end
end
