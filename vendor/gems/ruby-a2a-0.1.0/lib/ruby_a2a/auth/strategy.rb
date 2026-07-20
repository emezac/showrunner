# frozen_string_literal: true

module RubyA2A
  module Auth
    # Abstract base class for authentication strategies.
    # Subclasses must implement +apply!(request)+.
    #
    # The method receives a Net::HTTP::Request instance and mutates it
    # in place by adding the appropriate authentication headers.
    class Strategy
      # @param request [Net::HTTP::Request] the outgoing HTTP request
      # @return [Net::HTTP::Request] the mutated request
      def apply!(request)
        raise NotImplementedError, "#{self.class}#apply! is not implemented"
      end
    end
  end
end
