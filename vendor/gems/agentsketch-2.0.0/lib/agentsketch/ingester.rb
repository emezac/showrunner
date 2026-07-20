# frozen_string_literal: true

module AgentSketch
  # Ingests documents into a vector store for use with the :rag tool.
  #
  # Usage:
  #   AgentSketch.ingest do
  #     source :directory, path: "./docs/", recursive: true
  #     source :url,       urls: ["https://docs.example.com"]
  #     chunk_size    512
  #     chunk_overlap 64
  #     into :pgvector, table: "documents"
  #   end
  class Ingester
    def initialize
      @sources       = []
      @chunk_size    = 512
      @chunk_overlap = 64
      @destination   = { backend: :in_memory }
    end

    def source(type, **opts)
      @sources << { type: type, **opts }
    end

    def chunk_size(n)    = (@chunk_size = n)
    def chunk_overlap(n) = (@chunk_overlap = n)

    def into(backend, **opts)
      @destination = { backend: backend, **opts }
    end

    def run
      documents = load_documents
      chunks    = split_into_chunks(documents)

      puts "AgentSketch::Ingester: #{chunks.size} chunks de #{documents.size} documentos"

      ingest_chunks(chunks)

      puts "AgentSketch::Ingester: ingesta completada ✓"
    end

    private

    def load_documents
      @sources.flat_map do |source|
        case source[:type]
        when :directory then load_directory(source)
        when :url       then load_urls(source)
        when :pdf       then load_pdfs(source)
        when :text      then [{ title: source[:title] || "inline", content: source[:content] }]
        else []
        end
      end
    end

    def load_directory(source)
      path      = source[:path]
      recursive = source.fetch(:recursive, false)
      pattern   = recursive ? "#{path}/**/*" : "#{path}/*"

      Dir.glob(pattern)
         .select { |f| File.file?(f) }
         .select { |f| %w[.txt .md .json .csv .yaml .yml].include?(File.extname(f).downcase) }
         .map do |f|
           { title: File.basename(f), content: File.read(f, encoding: "utf-8") }
         rescue StandardError
           nil
         end
         .compact
    end

    def load_urls(source)
      require "net/http"
      require "uri"

      (source[:urls] || []).map do |url|
        uri  = URI.parse(url)
        body = Net::HTTP.get(uri)
        # Strip basic HTML tags
        text = body.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
        { title: url, content: text }
      rescue StandardError => e
        warn "Ingester: failed to load #{url}: #{e.message}"
        nil
      end.compact
    end

    def load_pdfs(source)
      path = source[:path]
      Dir.glob("#{path}/*.pdf").map do |f|
        # Basic PDF text extraction — requires `pdf-reader` gem
        if defined?(PDF::Reader)
          reader  = PDF::Reader.new(f)
          content = reader.pages.map(&:text).join("\n")
          { title: File.basename(f), content: content }
        else
          warn "Ingester: gem 'pdf-reader' required for PDF ingestion"
          nil
        end
      rescue StandardError => e
        warn "Ingester: failed to read PDF #{f}: #{e.message}"
        nil
      end.compact
    end

    def split_into_chunks(documents)
      documents.flat_map do |doc|
        text   = doc[:content].to_s
        chunks = []
        i      = 0

        while i < text.length
          chunk_end = [i + @chunk_size, text.length].min
          # Try to break at word boundary
          if chunk_end < text.length
            last_space = text.rindex(/\s/, chunk_end)
            chunk_end  = last_space if last_space && last_space > i
          end

          chunks << { title: doc[:title], content: text[i...chunk_end].strip }
          i += @chunk_size - @chunk_overlap
          i  = [i, 0].max
        end

        chunks.reject { |c| c[:content].empty? }
      end
    end

    def ingest_chunks(chunks)
      case @destination[:backend]
      when :in_memory
        chunks.each do |chunk|
          Tools::RAG.ingest(title: chunk[:title], content: chunk[:content])
        end
      when :pgvector
        ingest_pgvector(chunks)
      else
        chunks.each do |chunk|
          Tools::RAG.ingest(title: chunk[:title], content: chunk[:content])
        end
      end
    end

    def ingest_pgvector(chunks)
      return warn "pgvector ingestion requires ActiveRecord + neighbor gem" unless defined?(ActiveRecord::Base)

      chunks.each do |chunk|
        embedding = RubyLLM.embed("#{chunk[:title]}\n#{chunk[:content]}").vectors
        table = @destination.fetch(:table, "documents")

        ActiveRecord::Base.connection.execute(
          "INSERT INTO #{table} (title, content, embedding) VALUES ($1, $2, $3)",
          [chunk[:title], chunk[:content], embedding.to_s]
        )
      rescue StandardError => e
        warn "Ingester: failed to ingest chunk '#{chunk[:title]}': #{e.message}"
      end
    end
  end
end
