# frozen_string_literal: true

# =============================================================================
# QWEN ROUTER — Adaptador centralizado para DashScope / compatible-mode (v1).
# =============================================================================
# Parámetros configurables vía entorno:
#   QWEN_TOKEN                (alias: DASHSCOPE_API_KEY)
#   QWEN_BASE_URL             (default: https://dashscope-intl.aliyuncs.com/compatible-mode/v1)
#   QWEN_READ_TIMEOUT         (default: 180)
#   QWEN_OPEN_TIMEOUT         (default: 15)
#   QWEN_MAX_RETRIES          (default: 3)
#   QWEN_MODEL                (default: qwen3.7-plus)
# =============================================================================

require "net/http"
require "uri"
require "json"
require_relative "stable_media"

module QwenRouter
  class Error < StandardError; end
  class BudgetExceeded < Error; end
  class TransientError < Error; end
  class MalformedResponse < Error; end

  Config = Struct.new(:api_key, :base_url, :default_model, :read_timeout,
                       :open_timeout, :max_retries, keyword_init: true) do
    def self.default
      key = ENV["QWEN_TOKEN"] || ENV["DASHSCOPE_API_KEY"]
      raise QwenRouter::Error, "Falta QWEN_TOKEN (o DASHSCOPE_API_KEY) en el entorno" if key.to_s.strip.empty?

      new(
        api_key:       key,
        # QWEN_BASE_URL/QWEN_MODEL are the canonical deployment names. The
        # lower-case aliases match the environment file supplied by Qwen Cloud
        # and keep a freshly copied env.example functional without translation.
        base_url:      ENV["QWEN_BASE_URL"].presence || ENV["base_url"].presence ||
                       "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        default_model: ENV["QWEN_MODEL"].presence || ENV["model1"].presence || "qwen3.7-plus",
        read_timeout:  ENV.fetch("QWEN_READ_TIMEOUT", "180").to_i,
        open_timeout:  ENV.fetch("QWEN_OPEN_TIMEOUT", "15").to_i,
        max_retries:   ENV.fetch("QWEN_MAX_RETRIES", "3").to_i
      )
    end
  end

  # Modelo por etapa (SDD §8, tabla). Si tu cuenta solo tiene acceso a un
  # modelo (p.ej. qwen3.7-max) todas las etapas caen a Config#default_model —
  # es intencional: esto es una optimización de coste, no un requisito.
  def self.model_for(stage, config)
    override = ENV["QWEN_MODEL_#{stage.to_s.upcase}"]
    override || config.default_model
  end

  Result = Struct.new(:content, :tokens_used, :raw, keyword_init: true)

  # Heurística barata pre-vuelo (~4 chars/token). Se usa SOLO para decidir
  # si abortar ANTES de gastar red y cuota — el conteo real y autoritativo
  # de tokens siempre viene de response["usage"]["total_tokens"].
  def self.estimate_tokens(text)
    (text.to_s.length / 4.0).ceil
  end

  # ledger: hash mutable compartido {tokens_used:, tokens_remaining:, ...}
  # (el mismo objeto que ShowrunnerEngine#token_ledger) — se actualiza
  # in-place para que el budget_ledger del manifest siempre refleje la
  # realidad, incluso si esta llamada falla a mitad de pipeline.
  def self.call(system:, user:, stage: :scriptwrite, max_tokens: 800,
                 response_format: :json, ledger: nil, config: Config.default)
    model = model_for(stage, config)

    projected = estimate_tokens(system) + estimate_tokens(user) + max_tokens
    if ledger && projected > ledger[:tokens_remaining].to_i && !overrun_authorized?(ledger)
      raise BudgetExceeded,
        "#{stage}: projected #{projected} tokens > remaining budget #{ledger[:tokens_remaining]}"
    end

    body = {
      model: model,
      messages: [
        { role: "system", content: system },
        { role: "user",   content: user },
      ],
      max_tokens: max_tokens,
    }
    body[:response_format] = { type: "json_object" } if response_format == :json

    raw = with_retries(config.max_retries) { post_chat(config, body) }

    content = raw.dig("choices", 0, "message", "content")
    raise MalformedResponse, "Respuesta sin contenido: #{raw.inspect[0, 300]}" if content.nil?

    tokens_used = raw.dig("usage", "total_tokens") || projected
    record_usage!(ledger, stage: stage, model: model, tokens_used: tokens_used) if ledger

    Result.new(content: content, tokens_used: tokens_used, raw: raw)
  end

  # Igual que .call pero valida/parsea JSON, con UN reintento de
  # "reparación" (stage: :repair) si el modelo devolvió JSON inválido —
  # cheapest-adequate model por defecto, solo se paga el extra si hace falta
  # (SDD §10: "qwen-max reserved for rare fallback").
  def self.call_json(system:, user:, stage: :scriptwrite, max_tokens: 800, ledger: nil, config: Config.default)
    result = call(system: system, user: user, stage: stage, max_tokens: max_tokens,
                  response_format: :json, ledger: ledger, config: config)
    begin
      return [strip_json(result.content), result]
    rescue JSON::ParserError
      repaired = call(
        system: "Devuelve EXCLUSIVAMENTE un objeto JSON válido equivalente al contenido dado. " \
                 "Sin explicación, sin markdown, sin backticks.",
        user: result.content, stage: :repair, max_tokens: max_tokens, ledger: ledger, config: config
      )
      begin
        [strip_json(repaired.content), repaired]
      rescue JSON::ParserError => e
        # Ni el intento original ni la reparación dieron JSON usable — esto
        # SIEMPRE debe llegar al llamador como QwenRouter::Error, nunca como
        # JSON::ParserError crudo, para que el rescue de más arriba
        # (degradación a modo offline) lo capture correctamente.
        raise MalformedResponse, "Qwen returned invalid JSON even after repair: #{e.message}"
      end
    end
  end

  # OpenAI-compatible multimodal chat. `content` is an array containing text
  # and public image_url items. Qwen 3.7 supports image input and structured
  # output through this same endpoint, so visual QA stays behind the project's
  # single Qwen adapter.
  def self.call_vision_json(system:, content:, stage: :visual_consistency,
                            max_tokens: 1_200, ledger: nil, config: Config.default)
    content = normalize_vision_media(content)
    model = ENV["QWEN_VISION_MODEL"].presence || model_for(stage, config)
    text = Array(content).filter_map { |item| item[:text] || item["text"] }.join(" ")
    visual_token_estimate = Array(content).sum do |item|
      type = (item[:type] || item["type"]).to_s
      if type == "image_url"
        max_pixels = (item[:max_pixels] || item["max_pixels"]).to_i
        max_pixels.positive? ? [(max_pixels / 1024.0).ceil, 256].min : 256
      elsif type == "video"
        Array(item[:video] || item["video"]).size * 64
      else
        0
      end
    end
    # QA images are intentionally capped near 512x512 (or smaller video
    # frames), roughly 256 visual tokens with Qwen's 32x32 token grid.
    projected = estimate_tokens(system) + estimate_tokens(text) + visual_token_estimate + max_tokens

    if ledger && projected > ledger[:tokens_remaining].to_i && !overrun_authorized?(ledger)
      raise BudgetExceeded,
        "#{stage}: projected #{projected} tokens > remaining budget #{ledger[:tokens_remaining]}"
    end

    body = {
      model: model,
      messages: [
        { role: "system", content: system },
        { role: "user", content: content }
      ],
      max_tokens: max_tokens,
      response_format: { type: "json_object" }
    }
    raw = with_retries(config.max_retries) { post_chat(config, body) }
    response_content = raw.dig("choices", 0, "message", "content")
    raise MalformedResponse, "Vision response without content" if response_content.nil?

    parsed = strip_json(response_content)
    tokens_used = raw.dig("usage", "total_tokens") || projected
    record_usage!(ledger, stage: stage, model: model, tokens_used: tokens_used) if ledger

    [parsed, Result.new(content: response_content, tokens_used: tokens_used, raw: raw)]
  rescue JSON::ParserError => e
    raise MalformedResponse, "Vision model returned invalid JSON: #{e.message}"
  end

  def self.normalize_vision_media(content)
    Array(content).map do |item|
      normalized = item.respond_to?(:deep_dup) ? item.deep_dup : item.dup
      type = (normalized[:type] || normalized["type"]).to_s
      next normalized unless type == "image_url"

      image = normalized[:image_url] || normalized["image_url"] || {}
      url = image[:url] || image["url"]
      provider_url = StableMedia.provider_input(url)
      raise Error, "Vision reference is expired and has no durable local copy" unless provider_url

      image = image.to_h.dup
      image.delete(:url)
      image.delete("url")
      if normalized.key?(:image_url)
        normalized[:image_url] = image.merge(url: provider_url)
      else
        normalized["image_url"] = image.merge("url" => provider_url)
      end
      normalized
    end
  end

  def self.overrun_authorized?(ledger)
    value = ledger[:allow_token_overrun] || ledger["allow_token_overrun"]
    value == true || value == 1 || value.to_s.casecmp("true").zero? || value.to_s == "1"
  end

  def self.record_usage!(ledger, stage:, model:, tokens_used:)
    ledger[:tokens_used] = ledger[:tokens_used].to_i + tokens_used.to_i
    ledger[:tokens_remaining] = [ledger[:tokens_remaining].to_i - tokens_used.to_i, 0].max
    budget = (ledger[:token_budget] || ledger["token_budget"]).to_i
    ledger[:tokens_over_budget] = [ledger[:tokens_used] - budget, 0].max if budget.positive?
    (ledger[:calls] ||= []) << { stage: stage, model: model, tokens: tokens_used, at: Time.now.utc.iso8601 }
  end

  def self.strip_json(text)
    cleaned = text.to_s.strip.sub(/\A```json/i, "").sub(/\A```/, "").sub(/```\z/, "").strip
    begin
      res = JSON.parse(cleaned)
      res = JSON.parse(res) if res.is_a?(String)
      res
    rescue JSON::ParserError
      # El modelo a veces ignora response_format:json_object y devuelve
      # varios objetos JSON concatenados (NDJSON-like) en vez de uno solo
      # envuelto correctamente — p.ej. {"id":"1A",...}{"id":"2B",...} sin
      # array contenedor. En vez de rendirnos, extraemos TODOS los valores
      # JSON balanceados que aparezcan en el texto, ignorando cualquier
      # preámbulo/relleno alrededor.
      values = extract_json_values(cleaned)
      raise if values.empty?
      values.size == 1 ? values.first : values
    end
  end

  # Escanea el texto carácter a carácter (respetando strings/escapes) y
  # devuelve cada valor JSON top-level que logre parsear de forma
  # independiente, en el orden en que aparecen. Tolera prosa/basura entre
  # medias — solo le importan los tramos que sí son JSON válido.
  def self.extract_json_values(text)
    values = []
    i = 0
    len = text.length
    while i < len
      ch = text[i]
      if ch == "{" || ch == "["
        json_start = i
        depth = 0
        in_string = false
        escape = false
        j = i
        while j < len
          c = text[j]
          if in_string
            if escape
              escape = false
            elsif c == "\\"
              escape = true
            elsif c == '"'
              in_string = false
            end
          else
            case c
            when '"' then in_string = true
            when "{", "[" then depth += 1
            when "}", "]" then depth -= 1
            end
          end
          j += 1
          break if depth == 0 && j > json_start
        end
        candidate = text[json_start...j]
        begin
          values << JSON.parse(candidate)
          i = j
          next
        rescue JSON::ParserError
          # No era un valor JSON completo empezando aquí — seguimos buscando.
        end
      end
      i += 1
    end
    values
  end

  def self.with_retries(max_retries)
    attempt = 0
    begin
      attempt += 1
      yield
    rescue TransientError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ETIMEDOUT => e
      if attempt <= max_retries
        sleep(backoff(attempt))
        retry
      end
      raise Error, "Qwen request failed after #{attempt} attempts: #{e.message}"
    end
  end

  # Backoff exponencial con jitter — evita reintentos sincronizados si se
  # lanzan varias llamadas en paralelo (p.ej. clasificación + storyboard).
  def self.backoff(attempt)
    (2**attempt) * 0.5 + rand * 0.3
  end

  def self.post_chat(config, body)
    uri  = URI("#{config.base_url}/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = uri.scheme == "https"
    http.read_timeout = config.read_timeout
    http.open_timeout = config.open_timeout

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"]  = "application/json"
    request["Authorization"] = "Bearer #{config.api_key}"
    request.body = JSON.generate(body)

    response = http.request(request)

    raise TransientError, "HTTP #{response.code}" if response.code.to_i == 429 || response.code.to_i >= 500

    parsed = begin
      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "Respuesta no-JSON de Qwen (HTTP #{response.code}): #{response.body[0, 300]}"
    end

    unless response.is_a?(Net::HTTPSuccess)
      msg = parsed["error"] || parsed["message"] || response.body[0, 300]
      raise Error, "Qwen error #{response.code}: #{msg}"
    end

    parsed
  end
end
