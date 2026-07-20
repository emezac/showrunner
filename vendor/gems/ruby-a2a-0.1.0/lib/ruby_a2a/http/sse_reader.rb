# frozen_string_literal: true

require "json"

module RubyA2A
  module Http
    # Reads a Server-Sent Events stream from a Net::HTTP response.
    #
    # Accumulates chunks into a buffer, extracts complete SSE events
    # delimited by a blank line (\n\n), parses the JSON payload on
    # each "data:" line, and yields the parsed Hash to the caller.
    #
    # Ignores heartbeat events (empty data lines).
    # Handles partial chunks safely — no event is yielded until the
    # full blank-line delimiter is received.
    #
    # Each yielded event Hash contains exactly one of:
    #   "task", "statusUpdate", "artifactUpdate"
    class SseReader
      EVENT_DELIMITER = "\n\n"
      DATA_PREFIX     = "data:"

      def initialize
        @buffer = +""
      end

      # Feed a raw chunk of bytes received from the HTTP response body.
      # Yields each complete parsed event to the caller block.
      #
      # @param chunk  [String]
      # @yieldparam event [Hash]
      def feed(chunk, &block)
        return if chunk.nil? || chunk.empty?

        @buffer << chunk
        extract_events(&block)
      end

      # Flush any remaining buffer content after the stream closes.
      # Yields any final complete event that lacked a trailing \n\n.
      #
      # @yieldparam event [Hash]
      def flush(&block)
        return if @buffer.strip.empty?

        parse_event(@buffer.dup, &block)
        @buffer.clear
      end

      private

      def extract_events(&block)
        while (idx = @buffer.index(EVENT_DELIMITER))
          raw_event = @buffer.slice!(0, idx + EVENT_DELIMITER.length)
          parse_event(raw_event, &block)
        end
      end

      def parse_event(raw_event, &block)
        data_lines = raw_event
          .each_line
          .map(&:chomp)
          .select { |line| line.start_with?(DATA_PREFIX) }
          .map    { |line| line.sub(/\Adata:\s*/, "") }

        return if data_lines.empty?

        json_str = data_lines.join
        return if json_str.strip.empty?

        begin
          event = JSON.parse(json_str)
          yield event if block_given? && event.is_a?(Hash)
        rescue JSON::ParserError => e
          raise RubyA2A::A2AProtocolError.new(
            "Invalid SSE JSON payload: #{e.message}",
            reason: nil,
            details: [{ "raw" => json_str }]
          )
        end
      end
    end
  end
end
