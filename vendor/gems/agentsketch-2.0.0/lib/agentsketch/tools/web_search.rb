# frozen_string_literal: true

module AgentSketch
  module Tools
    # Built-in web search tool. Delegates to Tavily, SerpAPI, or DuckDuckGo.
    # Subclasses RubyLLM::Tool so it is passed directly to ruby_llm agents.
    class WebSearch < RubyLLM::Tool
      description "Busca información actualizada en la web"

      param :query,       desc: "La consulta de búsqueda"
      param :max_results, desc: "Número máximo de resultados (default: 5)"

      def initialize(config = {})
        @provider    = config.fetch(:provider, :serpapi).to_sym
        @max_results = config.fetch(:max_results, 5).to_i
        super()
      end

      def execute(query:, max_results: nil)
        limit = (max_results || @max_results).to_i

        case @provider
        when :tavily
          search_tavily(query, limit)
        when :serp, :serpapi
          search_serp(query, limit)
        when :duckduckgo
          search_duckduckgo(query, limit)
        else
          search_duckduckgo(query, limit)
        end
      rescue StandardError => e
        "Error en búsqueda web: #{e.message}"
      end

      private

      def search_tavily(query, limit)
        require "net/http"
        require "json"

        api_key = ENV["TAVILY_API_KEY"]
        raise ToolError.new("web_search", StandardError.new("TAVILY_API_KEY no configurada")) unless api_key

        uri  = URI("https://api.tavily.com/search")
        body = { api_key: api_key, query: query, max_results: limit }.to_json

        req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
        req.body = body

        resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }
        data = JSON.parse(resp.body)

        (data["results"] || []).map do |r|
          "#{r['title']}\n#{r['url']}\n#{r['content']}"
        end.join("\n\n---\n\n")
      end

      def search_serp(query, limit)
        require "net/http"
        require "json"

        api_key = ENV["SERPAPI_KEY"]
        raise "SERPAPI_KEY no configurada" unless api_key

        uri = URI("https://serpapi.com/search.json")
        uri.query = URI.encode_www_form(q: query, num: limit, api_key: api_key)

        resp = Net::HTTP.get_response(uri)
        data = JSON.parse(resp.body)

        (data["organic_results"] || []).first(limit).map do |r|
          "#{r['title']}\n#{r['link']}\n#{r['snippet']}"
        end.join("\n\n---\n\n")
      end

      def search_duckduckgo(query, limit)
        require "net/http"
        require "json"

        uri = URI("https://api.duckduckgo.com/")
        uri.query = URI.encode_www_form(q: query, format: "json", no_html: 1, skip_disambig: 1)

        resp = Net::HTTP.get_response(uri)
        data = JSON.parse(resp.body)

        results = []
        results << "#{data['Heading']}: #{data['AbstractText']}" if data["AbstractText"]&.length > 10
        (data["RelatedTopics"] || []).first(limit - 1).each do |t|
          results << t["Text"] if t["Text"]
        end

        results.empty? ? "No se encontraron resultados para: #{query}" : results.join("\n\n---\n\n")
      end
    end
  end
end
