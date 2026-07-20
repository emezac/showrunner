# frozen_string_literal: true

module AgentSketch
  module Tools
    # Retrieval-Augmented Generation tool.
    # Embeds a query via RubyLLM and performs nearest-neighbor search against
    # a configured vector store (pgvector via `neighbor` gem, or in-memory fallback).
    class RAG < RubyLLM::Tool
      description "Recupera documentos relevantes de la base de conocimiento"

      param :query, desc: "La consulta para buscar documentos relevantes"
      param :top_k, desc: "Número de documentos a recuperar (default: 5)"

      def initialize(config = {})
        @top_k           = config.fetch(:top_k, 5).to_i
        @score_threshold = config.fetch(:score_threshold, 0.0).to_f
        @table           = config.fetch(:index, "documents").to_s
        @vector_store    = config.fetch(:vector_store, :pgvector).to_sym
        super()
      end

      def execute(query:, top_k: nil)
        limit = (top_k || @top_k).to_i

        query_embedding = embed(query)
        return "Error al generar embedding de la consulta." unless query_embedding

        results = search_vector_store(query_embedding, limit)
        return "No se encontraron documentos relevantes para: #{query}" if results.empty?

        results.each_with_index.map do |doc, i|
          "[#{i + 1}] #{doc[:title]}\n#{doc[:content]}"
        end.join("\n\n---\n\n")
      rescue StandardError => e
        "Error en RAG: #{e.message}"
      end

      private

      def embed(text)
        RubyLLM.embed(text).vectors
      rescue StandardError
        nil
      end

      def search_vector_store(embedding, limit)
        case @vector_store
        when :pgvector
          search_pgvector(embedding, limit)
        when :in_memory
          search_in_memory(embedding, limit)
        else
          search_in_memory(embedding, limit)
        end
      end

      def search_pgvector(embedding, limit)
        # Requires `neighbor` gem and ActiveRecord with pgvector
        return [] unless defined?(Document)

        Document
          .nearest_neighbors(:embedding, embedding, distance: :cosine)
          .limit(limit * 2)
          .select { |r| r.respond_to?(:neighbor_distance) && r.neighbor_distance <= (1.0 - @score_threshold) }
          .first(limit)
          .map { |r| { title: r.try(:title) || "Documento", content: r.try(:content) || r.try(:body) || "" } }
      rescue StandardError
        []
      end

      def search_in_memory(embedding, limit)
        # Fallback: search from a shared in-memory store
        store = AgentSketch::Tools::RAG.in_memory_store
        return [] if store.empty?

        store
          .map    { |doc| doc.merge(score: cosine_similarity(embedding, doc[:embedding])) }
          .sort_by { |doc| -doc[:score] }
          .first(limit)
          .select  { |doc| doc[:score] >= @score_threshold }
          .map     { |doc| { title: doc[:title], content: doc[:content] } }
      end

      def cosine_similarity(a, b)
        return 0.0 unless a && b && a.size == b.size

        dot   = a.zip(b).sum { |x, y| x * y }
        mag_a = Math.sqrt(a.sum { |x| x**2 })
        mag_b = Math.sqrt(b.sum { |x| x**2 })
        denom = mag_a * mag_b
        denom.zero? ? 0.0 : dot / denom
      end

      class << self
        def in_memory_store
          @in_memory_store ||= []
        end

        # Ingest a document into the in-memory store (for testing/dev without pgvector)
        def ingest(title:, content:)
          embedding = RubyLLM.embed("#{title}\n#{content}").vectors
          in_memory_store << { title: title, content: content, embedding: embedding }
        rescue StandardError => e
          warn "RAG ingest failed: #{e.message}"
        end
      end
    end
  end
end
