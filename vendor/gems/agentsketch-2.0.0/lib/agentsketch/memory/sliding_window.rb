# frozen_string_literal: true

module AgentSketch
  module Memory
    # Keeps only the last N interactions in memory.
    class SlidingWindow < Base
      def initialize(opts = {})
        super
        @size    = opts.fetch(:size, 10)
        @history = []   # [{input:, output:}]
      end

      def build_context(_current_input)
        return "" if @history.empty?

        lines = ["Historial reciente de conversación:"]
        @history.last(@size).each do |turn|
          lines << "  Usuario: #{turn[:input]}"
          lines << "  Asistente: #{turn[:output]}"
        end
        lines.join("\n")
      end

      def save(input, output)
        @history << { input: input.to_s, output: output.to_s }
        @history = @history.last(@size * 2) if @history.size > @size * 4
      end
    end

    # Keeps the complete conversation history.
    class Full < Base
      def initialize(opts = {})
        super
        @history = []
      end

      def build_context(_current_input)
        return "" if @history.empty?

        lines = ["Historial completo de conversación:"]
        @history.each do |turn|
          lines << "  Usuario: #{turn[:input]}"
          lines << "  Asistente: #{turn[:output]}"
        end
        lines.join("\n")
      end

      def save(input, output)
        @history << { input: input.to_s, output: output.to_s }
      end
    end

    # Summarizes history every N turns using a cheap LLM call.
    class Summarize < Base
      def initialize(opts = {})
        super
        @every     = opts.fetch(:every, 5)
        @model     = opts.fetch(:model, "gpt-4o-mini")
        @keep_last = opts.fetch(:keep_last, 3)
        @history   = []
        @summary   = nil
      end

      def build_context(_current_input)
        parts = []
        parts << "Resumen de conversación anterior:\n#{@summary}" if @summary
        unless @history.empty?
          parts << "Turnos recientes:"
          @history.last(@keep_last).each do |turn|
            parts << "  Usuario: #{turn[:input]}"
            parts << "  Asistente: #{turn[:output]}"
          end
        end
        parts.join("\n")
      end

      def save(input, output)
        @history << { input: input.to_s, output: output.to_s }
        summarize! if @history.size >= @every
      end

      private

      def summarize!
        return unless defined?(RubyLLM)

        text = @history.map { |t| "User: #{t[:input]}\nAssistant: #{t[:output]}" }.join("\n\n")
        response = RubyLLM.chat(model: @model)
                          .ask("Resume esta conversación en 3-5 oraciones concisas:\n\n#{text}")
        @summary = response.content
        @history = @history.last(@keep_last)
      rescue StandardError
        # If summarization fails, keep raw history
      end
    end

    # Semantic episodic memory: embeds and retrieves similar past interactions.
    # Requires the `neighbor` gem and pgvector.
    class Episodic < Base
      def initialize(opts = {})
        super
        @top_k    = opts.fetch(:top_k, 3)
        @store    = opts.fetch(:store, :in_memory)
        @episodes = []  # in-memory fallback: [{summary:, embedding:}]
      end

      def build_context(current_input)
        relevant = retrieve(current_input)
        return "" if relevant.empty?

        lines = ["Recuerdos relevantes de interacciones anteriores:"]
        relevant.each { |ep| lines << "  - #{ep[:summary]}" }
        lines.join("\n")
      end

      def save(input, output)
        return unless defined?(RubyLLM)

        summary_resp = RubyLLM.chat(model: "gpt-4o-mini")
                               .ask("Resume en una oración: Input: #{input[0, 200]} Output: #{output[0, 200]}")
        summary   = summary_resp.content
        embedding = embed("#{input}\n#{output}")

        @episodes << { summary: summary, embedding: embedding }
        @episodes = @episodes.last(500) # cap in-memory store
      rescue StandardError
        # Degrade gracefully if embedding fails
      end

      private

      def retrieve(query)
        return [] if @episodes.empty?
        return [] unless defined?(RubyLLM)

        query_embedding = embed(query)
        return [] unless query_embedding

        @episodes
          .map    { |ep| ep.merge(score: cosine_similarity(query_embedding, ep[:embedding])) }
          .sort_by { |ep| -ep[:score] }
          .first(@top_k)
      rescue StandardError
        []
      end

      def embed(text)
        RubyLLM.embed(text).vectors
      rescue StandardError
        nil
      end

      def cosine_similarity(a, b)
        return 0.0 unless a && b && a.size == b.size

        dot     = a.zip(b).sum { |x, y| x * y }
        mag_a   = Math.sqrt(a.sum { |x| x**2 })
        mag_b   = Math.sqrt(b.sum { |x| x**2 })
        denom   = mag_a * mag_b
        denom.zero? ? 0.0 : dot / denom
      end
    end
  end
end
