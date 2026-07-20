# frozen_string_literal: true

module RubyA2A
  # Base error for all ruby-a2a errors
  class Error < StandardError; end

  # Errors that map directly to A2A protocol error reasons
  class A2AProtocolError < Error
    attr_reader :reason, :details

    def initialize(message = nil, reason: nil, details: nil)
      super(message)
      @reason  = reason
      @details = details
    end
  end

  class TaskNotFoundError          < A2AProtocolError; end
  class UnsupportedOperationError  < A2AProtocolError; end
  class VersionNotSupportedError   < A2AProtocolError; end
  class ContentTypeNotSupportedError < A2AProtocolError; end
  class TaskNotCancelableError     < A2AProtocolError; end

  # Raised when a task transitions to TASK_STATE_AUTH_REQUIRED
  class AuthRequiredError < Error
    attr_reader :task

    def initialize(message = "Task requires additional authentication", task: nil)
      super(message)
      @task = task
    end
  end

  # Raised when poll_until_complete exceeds max_poll_attempts
  class PollingTimeoutError < Error
    attr_reader :task_id, :attempts

    def initialize(task_id:, attempts:)
      super("Polling timed out after #{attempts} attempts for task #{task_id}")
      @task_id  = task_id
      @attempts = attempts
    end
  end

  # Raised when agent card cannot be discovered at either well-known path
  class AgentCardNotFoundError < Error
    def initialize(base_url)
      super("Agent card not found at #{base_url}/.well-known/agent.json or /.well-known/agent-card.json")
    end
  end

  # Raised when a plain HTTP base_url is supplied
  class TLSRequiredError < Error
    def initialize(url)
      super("TLS is required. Plain HTTP is forbidden. Got: #{url}")
    end
  end

  # Maps A2A protocol error reason strings to typed exceptions
  ERROR_REASON_MAP = {
    "TASK_NOT_FOUND"             => TaskNotFoundError,
    "UNSUPPORTED_OPERATION"      => UnsupportedOperationError,
    "VERSION_NOT_SUPPORTED"      => VersionNotSupportedError,
    "CONTENT_TYPE_NOT_SUPPORTED" => ContentTypeNotSupportedError,
    "TASK_NOT_CANCELABLE"        => TaskNotCancelableError
  }.freeze

  # Raises the appropriate typed exception for a parsed A2A error body.
  # Expects the parsed JSON body Hash from a non-2xx response.
  def self.raise_protocol_error!(body)
    error_obj = body.is_a?(Hash) ? body["error"] : nil
    message   = error_obj&.dig("message") || "A2A protocol error"
    details   = error_obj&.dig("details") || []
    reason    = nil

    # Dig through google.rpc.ErrorInfo in details array
    if details.is_a?(Array)
      error_info = details.find { |d| d.is_a?(Hash) && d["@type"]&.include?("ErrorInfo") }
      reason = error_info&.dig("reason")
    end

    klass = ERROR_REASON_MAP.fetch(reason, A2AProtocolError)
    raise klass.new(message, reason: reason, details: details)
  end
end
