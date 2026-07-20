# frozen_string_literal: true

module RubyA2A
  module Models
    # Represents an A2A message with a role and an array of Parts.
    class Message
      ALLOWED_ROLES = %w[user agent].freeze
      ROLE_MAP = {
        "ROLE_USER"  => "user",
        "ROLE_AGENT" => "agent"
      }.freeze

      attr_reader :role, :parts

      def initialize(role, parts)
        raise ArgumentError, "role must not be nil"   if role.nil?
        raise ArgumentError, "role must not be empty" if role.to_s.strip.empty?
        raise ArgumentError, "parts must not be nil"  if parts.nil?

        normalized = ROLE_MAP[role.to_s] || role.to_s
        unless ALLOWED_ROLES.include?(normalized)
          raise ArgumentError, "role must be one of #{ALLOWED_ROLES.join(", ")}; got #{role.inspect}"
        end

        @role  = normalized.freeze
        @parts = Array(parts).tap do |arr|
          arr.each_with_index do |p, i|
            unless p.is_a?(Part)
              raise ArgumentError, "parts[#{i}] must be a RubyA2A::Models::Part; got #{p.class}"
            end
          end
        end.freeze

        freeze
      end

      # Serialize to a camelCase Hash suitable for A2A JSON encoding.
      # Nil values are omitted.
      def to_h
        {
          "role"  => @role,
          "parts" => @parts.map(&:to_h)
        }
      end
    end
  end
end
