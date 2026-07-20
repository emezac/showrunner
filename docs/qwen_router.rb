# frozen_string_literal: true
# =============================================================================
# qwen_router.rb — Único punto de acceso a los modelos LLM de Qwen Cloud
#
# SDD §8: "A single Ruby adapter is the only path to Qwen models, enforcing
# the hackathon's 'all LLM calls through Qwen' constraint and giving one
# place to instrument token accounting." Este archivo ES ese adaptador.
#
# Usa el endpoint OpenAI-compatible de Qwen Cloud:
#   POST {base_url}/chat/completions
#
# (Distinto del endpoint nativo de DashScope para vídeo — ver
#  happy_horse_client.rb — que usa /api/v1/services/aigc/video-generation/*)
#
# AUTENTICACIÓN — nunca hardcodear:
#   ENV["QWEN_TOKEN"]        (preferido)
#   ENV["DASHSCOPE_API_KEY"] (fallback, mismo valor si tu cuenta usa una
#                             sola clave para LLM + vídeo)
#
# Si alguna vez pegaste una clave real en un chat, commit, log o ticket,
# consideralá comprometida y rotala en la consola de Qwen Cloud.
#
# Variables de entorno opcionales:
#   QWEN_BASE_URL            (default: dashscope-intl compatible-mode/v1)
#   QWEN_MODEL                (default: qwen3.7-max)
#   QWEN_MODEL_CLASSIFY / QWEN_MODEL_SCRIPT / QWEN_MODEL_STORYBOARD /
#   QWEN_MODEL_REPAIR         (opcional — asignar modelos más baratos por
#                              etapa si tu cuenta tiene acceso a varios;
#                              si no se definen, todo cae a QWEN_MODEL)
# =============================================================================

require "net/http"
require "uri"
require "json"

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
        base_url:      ENV.fetch("QWEN_BASE_URL", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
        default_model: ENV.fetch("QWEN_MODEL", "qwen3.7-max"),
        read_timeout:  Integer(ENV.fetch("QWEN_READ_TIMEOUT", 90)),
        open_timeout:  Integer(ENV.fetch("QWEN_OPEN_TIMEOUT", 15)),
        max_retries:   Integer(ENV.fetch("QWEN_MAX_RETRIES", 3))
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
    if ledger && projected > ledger[:tokens_remaining]
      raise BudgetExceeded,
        "#{stage}: proyectado #{projected} tokens > presupuesto restante #{ledger[:tokens_remaining]}"
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
    if ledger
      ledger[:tokens_used]     = (ledger[:tokens_used] || 0) + tokens_used
      ledger[:tokens_remaining] = [ledger[:tokens_remaining] - tokens_used, 0].max
      (ledger[:calls] ||= []) << { stage: stage, model: model, tokens: tokens_used, at: Time.now.utc.iso8601 }
    end

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
        raise MalformedResponse, "Qwen devolvió JSON inválido incluso tras reparación: #{e.message}"
      end
    end
  end

  def self.strip_json(text)
    cleaned = text.to_s.strip.sub(/\A```json/i, "").sub(/\A```/, "").sub(/```\z/, "").strip
    begin
      JSON.parse(cleaned)
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
      raise Error, "Llamada a Qwen falló tras #{attempt} intentos: #{e.message}"
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
