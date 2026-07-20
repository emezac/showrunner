# frozen_string_literal: true

require "base64"
require "json"

module RubyA2A
  module Models
    # Represents one unit of content within a Message.
    # Exactly one content field must be set.
    class Part
      CONTENT_FIELDS = %i[text data raw url].freeze

      attr_reader :text, :data, :raw, :url, :filename, :media_type

      # Convenience constructor — plain text part.
      def self.text(text)
        raise ArgumentError, "text must not be nil" if text.nil?

        new(text: text)
      end

      # Convenience constructor — structured data part (JSON-serializable).
      # Accepted types: Hash, Array, String, Numeric, TrueClass, FalseClass.
      def self.data(data)
        raise ArgumentError, "data must not be nil" if data.nil?

        unless data.is_a?(Hash)   || data.is_a?(Array)  ||
               data.is_a?(String) || data.is_a?(Numeric) ||
               data == true       || data == false
          raise ArgumentError,
            "data must be a JSON-serializable type (Hash, Array, String, Numeric, or Boolean); " \
            "got #{data.class}"
        end

        new(data: data)
      end

      # Convenience constructor — raw binary part.
      def self.raw(bytes, filename:, media_type:)
        raise ArgumentError, "bytes must not be nil"     if bytes.nil?
        raise ArgumentError, "filename must not be nil"  if filename.nil?
        raise ArgumentError, "filename must not be empty" if filename.to_s.strip.empty?
        raise ArgumentError, "media_type must not be nil" if media_type.nil?
        raise ArgumentError, "media_type must not be empty" if media_type.to_s.strip.empty?

        new(raw: bytes, filename: filename, media_type: media_type)
      end

      # Convenience constructor — external URL reference part.
      def self.url(url, media_type:)
        raise ArgumentError, "url must not be nil"        if url.nil?
        raise ArgumentError, "media_type must not be nil"  if media_type.nil?
        raise ArgumentError, "media_type must not be empty" if media_type.to_s.strip.empty?

        new(url: url, media_type: media_type)
      end

      # Serialize to a Hash suitable for JSON encoding.
      # Nil values are omitted. raw bytes are Base64-encoded.
      def to_h
        case content_field
        when :text
          { "text" => @text }
        when :data
          h = { "data" => @data, "mediaType" => "application/json" }
          h.compact
        when :raw
          h = {
            "raw"       => ::Base64.strict_encode64(@raw.to_s),
            "filename"  => @filename,
            "mediaType" => @media_type
          }
          h.compact
        when :url
          h = { "url" => @url, "mediaType" => @media_type }
          h.compact
        end
      end

      private

      def initialize(text: nil, data: nil, raw: nil, url: nil, filename: nil, media_type: nil)
        @text       = text
        @data       = data
        @raw        = raw
        @url        = url
        @filename   = filename
        @media_type = media_type

        validate!
        freeze
      end

      def content_field
        CONTENT_FIELDS.find { |f| !send(f).nil? }
      end

      def validate!
        set_fields = CONTENT_FIELDS.count { |f| !send(f).nil? }

        if set_fields.zero?
          raise ArgumentError, "A Part must have exactly one content field; none were set"
        end

        if set_fields > 1
          raise ArgumentError, "A Part must have exactly one content field; #{set_fields} were set"
        end
      end
    end
  end
end
