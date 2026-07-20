# frozen_string_literal: true

require "uri"
require "securerandom"

module RubyA2A
  # The primary interface for communicating with a remote A2A-compatible agent.
  #
  # Example:
  #   auth   = RubyA2A::Auth::BearerToken.new("my-token")
  #   client = RubyA2A::Client.new("https://agent.example.com", auth: auth)
  #   task   = client.send_message("Hello, agent!")
  class Client
    AGENT_CARD_PATHS = [
      "/.well-known/agent.json",
      "/.well-known/agent-card.json"
    ].freeze

    # @param base_url [String] URL of the remote agent host (https for production, http for local dev).
    # @param auth     [#apply!, nil] Authentication strategy object (nil = no auth).
    def initialize(base_url, auth: nil)
      validate_base_url!(base_url)

      @base_url = base_url.freeze
      @auth     = auth
      @config   = RubyA2A.configuration
      @http     = Http::Base.new(@base_url, auth: @auth, config: @config)
    end

    # Discovers and returns the remote Agent Card.
    # Tries /.well-known/agent.json first, then /.well-known/agent-card.json.
    # Result is memoized after first successful discovery.
    #
    # @return [RubyA2A::AgentCard]
    # @raise  [RubyA2A::AgentCardNotFoundError]
    def agent_card
      @agent_card ||= begin
        raw = nil

        AGENT_CARD_PATHS.each do |path|
          raw = @http.get(path)
          break if raw
        end

        raise AgentCardNotFoundError.new(@base_url) unless raw

        AgentCard.new(raw)
      end
    end

    # Sends a message to the remote agent via JSON-RPC and polls until the task completes.
    #
    # Accepts a String, a RubyA2A::Models::Message, a single Part, or an
    # Array of Parts. Wraps the message in a JSON-RPC 2.0 envelope.
    #
    # @param message_or_parts [String, Models::Message, Models::Part, Array<Models::Part>]
    # @return [Models::Task]
    def send_message(message_or_parts)
      message   = coerce_message(message_or_parts)
      body      = build_rpc_envelope(message)
      response  = @http.post("/", body: body)
      result    = response["result"]
      task      = Models::Task.new(result || response)

      return task if task.terminal?

      poll_until_complete(task.task_id)
    end

    # Sends a streaming message via JSON-RPC and yields each SSE event to the caller block.
    # If no block is given, returns an Enumerator.
    #
    # Requires the Agent Card to declare streaming capability.
    #
    # @param message_or_parts [String, Models::Message, Models::Part, Array<Models::Part>]
    # @yieldparam event [Hash] parsed SSE event — contains one of "task",
    #   "statusUpdate", or "artifactUpdate"
    # @return [Enumerator, nil]
    # @raise [RubyA2A::UnsupportedOperationError] when agent does not support streaming
    def stream_message(message_or_parts, &block)
      check_streaming_support!

      return to_enum(:stream_message, message_or_parts) unless block_given?

      message = coerce_message(message_or_parts)
      body    = build_rpc_envelope(message)
      body["method"] = "tasks/sendSubscribe"

      @http.post("/", body: body, sse: true, &block)
    end

    # Fetches the current state of a task.
    #
    # @param task_id [String]
    # @return [Models::Task]
    def get_task(task_id)
      validate_task_id!(task_id)

      response = @http.get("/tasks/#{task_id}")
      Models::Task.new(response)
    end

    # Attempts to cancel a task.
    #
    # @param task_id [String]
    # @return [Models::Task]
    def cancel_task(task_id)
      validate_task_id!(task_id)

      response = @http.post("/tasks/#{task_id}:cancel")
      Models::Task.new(response)
    end

    # Subscribes to SSE task update events.
    # Yields each event or returns an Enumerator when no block is given.
    #
    # @param task_id [String]
    # @yieldparam event [Hash]
    # @return [Enumerator, nil]
    def subscribe_to_task(task_id, &block)
      validate_task_id!(task_id)

      return to_enum(:subscribe_to_task, task_id) unless block_given?

      @http.post("/tasks/#{task_id}:subscribe", sse: true, &block)
    end

    # Polls a task until it reaches a terminal state.
    #
    # Uses configurable poll_interval (seconds) and max_poll_attempts.
    #
    # @param task_id [String]
    # @return [Models::Task]
    # @raise [RubyA2A::AuthRequiredError]   on TASK_STATE_AUTH_REQUIRED
    # @raise [RubyA2A::PollingTimeoutError] when max attempts are exceeded
    def poll_until_complete(task_id)
      validate_task_id!(task_id)

      attempts = 0
      max      = @config.max_poll_attempts
      interval = @config.poll_interval

      loop do
        task = get_task(task_id)

        raise AuthRequiredError.new(task: task) if task.auth_required?

        return task if task.terminal?

        attempts += 1

        raise PollingTimeoutError.new(task_id: task_id, attempts: attempts) if attempts >= max

        sleep interval
      end
    end

    private

    # ------------------------------------------------------------------
    # Message coercion
    # ------------------------------------------------------------------

    # Normalises the flexible message_or_parts argument into a Message.
    def coerce_message(message_or_parts)
      case message_or_parts
      when nil
        raise ArgumentError, "message must not be nil"
      when Models::Message
        message_or_parts
      when String
        raise ArgumentError, "message string must not be empty" if message_or_parts.strip.empty?

        Models::Message.new("user", [Models::Part.text(message_or_parts)])
      when Models::Part
        Models::Message.new("user", [message_or_parts])
      when Array
        raise ArgumentError, "parts array must not be empty" if message_or_parts.empty?

        message_or_parts.each_with_index do |p, i|
          unless p.is_a?(Models::Part)
            raise ArgumentError,
              "parts[#{i}] must be a RubyA2A::Models::Part; got #{p.class}"
          end
        end

        Models::Message.new("user", message_or_parts)
      else
        raise ArgumentError,
          "Unsupported message type: #{message_or_parts.class}. " \
          "Expected String, Models::Message, Models::Part, or Array<Models::Part>."
      end
    end

    # Builds a JSON-RPC 2.0 envelope wrapping the message for tasks/send.
    def build_rpc_envelope(message)
      {
        "jsonrpc" => "2.0",
        "id"      => SecureRandom.uuid,
        "method"  => "tasks/send",
        "params"  => {
          "id"      => SecureRandom.uuid,
          "message" => message.to_h
        }
      }
    end

    # ------------------------------------------------------------------
    # Validation helpers
    # ------------------------------------------------------------------

    def check_streaming_support!
      unless agent_card.streaming?
        raise UnsupportedOperationError.new(
          "This agent does not support streaming",
          reason: "UNSUPPORTED_OPERATION"
        )
      end
    end

    def validate_base_url!(url)
      raise ArgumentError, "base_url must not be nil"   if url.nil?
      raise ArgumentError, "base_url must not be empty" if url.to_s.strip.empty?

      begin
        uri = URI.parse(url)
      rescue URI::InvalidURIError
        raise ArgumentError, "base_url is not a valid URI: #{url.inspect}"
      end

      # Allow http for localhost development; require https for remote hosts
      unless uri.scheme == "https" || (uri.scheme == "http" && localhost?(uri.host))
        if uri.scheme == "http"
          raise TLSRequiredError.new(url)
        else
          raise ArgumentError, "base_url must use the https scheme; got #{url.inspect}"
        end
      end
    end

    def localhost?(host)
      return false if host.nil?
      host == "localhost" || host == "127.0.0.1" || host == "::1" || host.start_with?("localhost.")
    end

    def validate_task_id!(task_id)
      raise ArgumentError, "task_id must not be nil"   if task_id.nil?
      raise ArgumentError, "task_id must not be empty" if task_id.to_s.strip.empty?
    end
  end
end
