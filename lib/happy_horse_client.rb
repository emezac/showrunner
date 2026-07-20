# frozen_string_literal: true
# =============================================================================
# happy_horse_client.rb — DashScope / HappyHorse video-synthesis client
#
# Este es el archivo enlazado en el envío de Devpost como prueba de
# despliegue en Alibaba Cloud (SDD §9.1): es el único lugar del código que
# habla con dashscope-intl.aliyuncs.com para generación de vídeo.
#
# Envía jobs HappyHorse async (t2v / i2v), hace polling hasta terminal,
# descarga resultados, y soporta envío por lotes con concurrencia acotada
# (varios shots de una escena en paralelo sin saturar la cuota de DashScope).
#
# Env:
#   QWEN_TOKEN o DASHSCOPE_API_KEY  (se prueba en ese orden — nunca
#                                    hardcodear; si compartiste una clave en
#                                    texto plano en algún sitio, rotala ya)
#
# Uso básico:
#   client = HappyHorseClient.new
#
#   job = client.submit_t2v(prompt: "...", resolution: "720P", duration: 5)
#   result = client.poll_until_done(job.task_id) { |r, elapsed| puts r.status }
#   client.download(result.video_url, to: "shot_1_1.mp4")
#
# Envío por lotes (varios shots a la vez, con límite de concurrencia):
#   results = client.submit_batch(shots, max_concurrent: 3) do |shot, result_or_error|
#     ...
#   end
# =============================================================================

require "net/http"
require "json"
require "uri"
require "fileutils"
require "digest"
require_relative "stable_media"

module HappyHorse
  class Error < StandardError; end
  class BudgetExceeded < Error; end
  class ContentPolicyError < Error; end
  class TaskFailedError < Error; end
  class TaskTimeoutError < Error; end
  class TransientHttpError < Error; end
  class DownloadVerificationError < Error; end

  # ── Value objects ──────────────────────────────────────────────────────────

  SubmitResult = Struct.new(:task_id, :request_id, :raw, keyword_init: true)

  PollResult = Struct.new(:task_id, :status, :video_url, :error_message,
                           :submit_time, :end_time, :raw, keyword_init: true) do
    def pending?   = status == "PENDING"
    def running?   = status == "RUNNING"
    def succeeded? = status == "SUCCEEDED"
    def failed?    = status == "FAILED"
    def terminal?  = succeeded? || failed?

    def image_url
      raw.to_h.dig("output", "choices", 0, "message", "content", 0, "image") ||
        raw.to_h.dig("output", "results", 0, "url") ||
        raw.to_h.dig("output", "image_url")
    end
  end

  # Logger mínimo por defecto — inyectable para integrarse con Rails.logger,
  # un logger de Sidekiq, etc. Solo necesita responder a #info/#warn/#error.
  class NullLogger
    def info(msg)  = nil
    def warn(msg)  = nil
    def error(msg) = nil
  end

  class StdoutLogger
    def info(msg)  = puts("  ℹ  #{msg}")
    def warn(msg)  = puts("  ⚠  #{msg}")
    def error(msg) = puts("  ✗  #{msg}")
  end

  # ── Configuración ───────────────────────────────────────────────────────────

  Config = Struct.new(:api_key, :host, :video_model, :read_timeout, :open_timeout,
                       keyword_init: true) do
    def self.default
      key = ENV["QWEN_TOKEN"] || ENV["DASHSCOPE_API_KEY"]
      raise HappyHorse::Error, "Falta QWEN_TOKEN (o DASHSCOPE_API_KEY) en el entorno" if key.to_s.strip.empty?

      new(
        api_key:      key,
        host:         ENV.fetch("DASHSCOPE_HOST", "dashscope-intl.aliyuncs.com"),
        video_model:  ENV.fetch("HAPPYHORSE_MODEL", "happyhorse-1.1"),
        read_timeout: Integer(ENV.fetch("DASHSCOPE_READ_TIMEOUT", 180)),
        open_timeout: Integer(ENV.fetch("DASHSCOPE_OPEN_TIMEOUT", 15))
      )
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# CLIENTE
# ─────────────────────────────────────────────────────────────────────────────

class HappyHorseClient
  SYNTHESIS_PATH       = "/api/v1/services/aigc/video-generation/video-synthesis"
  IMAGE_SYNTHESIS_PATH = "/api/v1/services/aigc/text2image/image-synthesis"
  IMAGE_GENERATION_PATH = "/api/v1/services/aigc/image-generation/generation"
  # wan2.7-image-pro requiere el endpoint multimodal-generation (respuesta SÍNCRONA)
  MULTIMODAL_PATH      = "/api/v1/services/aigc/multimodal-generation/generation"
  TASK_PATH            = "/api/v1/tasks/%{task_id}"

  VALID_RESOLUTIONS = %w[480P 720P 1080P].freeze
  VALID_RATIOS      = %w[16:9 9:16 1:1].freeze
  # DashScope's video models accept only these discrete clip lengths. Keep
  # this contract at the provider boundary so legacy manifests, repairs and
  # direct client calls cannot accidentally submit an unsupported duration.
  VALID_VIDEO_DURATIONS = [3, 4, 5].freeze

  # Polling: arranca rápido, retrocede a intervalos más largos para no
  # gastar cuota de requests en tareas de vídeo que tardan minutos.
  POLL_SCHEDULE    = [5, 5, 10, 10, 15, 30].freeze # segundos; el último se repite
  MAX_POLL_SECONDS = 360 # 6 minutos — luego TaskTimeoutError (SDD §9.3)
  MAX_SUBMIT_RETRIES = 3
  DEFAULT_NEGATIVE_PROMPT = [
    "identity drift", "different face", "different clothing", "different proportions",
    "object redesign", "color change", "material change", "scale change",
    "duplicate subject", "missing required object", "morphing", "style shift",
    "floating without cause", "teleportation", "broken anatomy",
    "unrequested visible text", "typography", "captions", "subtitles", "labels",
    "logos", "watermarks", "measurement rulers", "calibration grids",
    "technical diagrams", "interface overlays"
  ].join(", ").freeze
  NARRATIVE_IMAGE_EXCLUSIONS = "OUTPUT EXCLUSIONS: no unrequested visible text, typography, subtitles, captions, labels, logos, watermarks, rulers, calibration grids, technical diagrams or interface overlays.".freeze

  attr_reader :config, :logger

  def initialize(config: HappyHorse::Config.default, logger: HappyHorse::NullLogger.new)
    @config = config
    @logger = logger
  end

  def self.normalize_video_duration(value)
    requested = Float(value)
    requested = 5.0 unless requested.finite? && requested.positive?
    VALID_VIDEO_DURATIONS.min_by { |allowed| (allowed - requested).abs }
  rescue ArgumentError, TypeError
    5
  end

  # ── Envío: texto → video ────────────────────────────────────────────────────

  def submit_t2v(prompt:, resolution: "720P", ratio: "16:9", duration: 5, negative_prompt: nil)
    validate_resolution!(resolution)
    validate_ratio!(ratio)

    model_name = config.video_model.to_s
    model_id = if model_name == "happyhorse-1.1"
                 "wan2.1-t2v-turbo"
               else
                 model_name.end_with?("-t2v") ? model_name : "#{model_name}-t2v"
               end

    payload = {
      model: model_id,
      input: { prompt: prompt, negative_prompt: merged_negative_prompt(negative_prompt) },
      parameters: { resolution: resolution, ratio: ratio, duration: self.class.normalize_video_duration(duration) },
    }

    submit(payload)
  end

  # ── Envío: imagen (first frame) → video ─────────────────────────────────────
  # DashScope I2V API espera `input.img_url` como campo plano (no un array media).
  # Ref: https://help.aliyun.com/zh/model-studio/legacy-image-to-video-api-reference

  def submit_i2v(prompt:, first_frame_url:, resolution: "720P", duration: 5, negative_prompt: nil)
    validate_resolution!(resolution)
    raise ArgumentError, "first_frame_url is required for i2v" if first_frame_url.to_s.empty?
    provider_image = provider_reference_input!(first_frame_url, label: "first_frame_url")

    model_name = config.video_model.to_s
    model_id = if model_name == "happyhorse-1.1"
                 "wan2.1-i2v-turbo"
               else
                 model_name.end_with?("-i2v") ? model_name : "#{model_name}-i2v"
               end

    payload = {
      model: model_id,
      input: {
        prompt: prompt,
        img_url: provider_image,
        negative_prompt: merged_negative_prompt(negative_prompt)
      },
      parameters: {
        resolution: resolution,
        duration: self.class.normalize_video_duration(duration),
        prompt_extend: false
      },
    }

    submit(payload)
  end

  # ── Envío: imagen referencia → video (Reference-to-Video) ──────────────────
  # wan2.7-r2v: el sujeto/personaje de ref_image_url se mantiene visualmente
  # consistente en todo el clip. El prompt describe la ACCIÓN de la escena,
  # no el personaje (que ya viene anclado por la imagen referencia).

  def submit_r2v(prompt:, ref_image_url:, resolution: "720P", duration: 5, negative_prompt: nil)
    validate_resolution!(resolution)
    raise ArgumentError, "ref_image_url is required for r2v" if ref_image_url.to_s.empty?
    provider_image = provider_reference_input!(ref_image_url, label: "ref_image_url")

    payload = {
      model: "wan2.7-r2v",
      input: {
        prompt: prompt,
        # La API wan2.7-r2v requiere input.media (array de objetos) para la imagen referencia,
        # NO input.ref_images. El campo type: "reference_image" ancla el sujeto visualmente.
        media: [{ url: provider_image, type: "reference_image" }],
        negative_prompt: merged_negative_prompt(negative_prompt)
      },
      parameters: {
        resolution: resolution,
        duration: self.class.normalize_video_duration(duration),
        prompt_extend: false
      }
    }

    submit(payload)
  end

  # ── Envío: texto → imagen (wan2.7-image-pro) ────────────────────────────────
  # wan2.7-image-pro usa el endpoint multimodal-generation/generation.
  # La respuesta es SÍNCRONA: no hay task_id ni polling — la imagen llega
  # directamente en output.choices[0].message.content[0].image
  # Devuelve un PollResult sintético (succeeded?, image_url) para que
  # submit_with_retries pueda tratarlo igual que una respuesta de video.

  def submit_t2i(prompt:, size: "1280*720", model: "wan2.7-image-pro", reference_image_urls: nil)
    references = Array(reference_image_urls).filter_map { |url| StableMedia.provider_input(url) }.uniq.first(9)
    content = references.map { |url| { image: url } }
    reference_instruction = if references.any?
                              "Use images 1-#{references.size} as strict canonical references. Preserve each referenced subject/object's identity, design, materials, colors and relative scale exactly. A reference crop or apparent pixel size never authorizes changing physical scale; infer scale from environmental anchors, same-class peers and the written scale contract. "
                            else
                              ""
                            end
    exclusions = narrative_image_exclusions(prompt)
    content << { text: "#{reference_instruction}#{prompt}#{" #{exclusions}" unless exclusions.empty?}" }
    payload = {
      model: model,
      input: {
        messages: [
          {
            role: "user",
            content: content
          }
        ]
      },
      parameters: {
        n: 1,
        size: size,
        watermark: false,
        thinking_mode: true
      }
    }
    uri = URI("https://#{config.host}#{MULTIMODAL_PATH}")
    # IMPORTANTE: wan2.7-image-pro es síncrono — NO enviar X-DashScope-Async
    response = with_retries("submit_t2i(#{model})") { http_post_sync(uri, payload) }
    body = safe_parse_json(response.body)

    unless response.is_a?(Net::HTTPSuccess)
      raise HappyHorse::Error, "DashScope T2I error #{response.code}: #{body['message'] || response.body[0, 300]}"
    end

    # Respuesta síncrona — extraemos la URL de imagen directamente
    img_url = body.dig("output", "choices", 0, "message", "content", 0, "image")
    raise HappyHorse::Error, "T2I did not return an image: #{body.inspect[0, 300]}" if img_url.to_s.empty?

    logger.info("T2I imagen generada: #{img_url[0, 80]}...")

    # Devolvemos un PollResult sintético con status SUCCEEDED e image_url
    HappyHorse::PollResult.new(
      task_id:    body["request_id"],
      status:     "SUCCEEDED",
      video_url:  nil,
      error_message: nil,
      submit_time: nil,
      end_time:   nil,
      raw:        body
    )
  end

  # DashScope returns short-lived signed OSS URLs. Reusing an expired URL as
  # an image input makes an otherwise valid regeneration fail with the opaque
  # provider error `url error, please check url`. Discard only references that
  # are provably expired; ordinary remote URLs and data URLs remain accepted.
  def usable_reference_url?(value, now: Time.now)
    StableMedia.data_uri?(value) || StableMedia.local_available?(value) || StableMedia.usable_remote?(value, now: now)
  end
  #
  # Bloqueante — pensado para un worker de background (Sidekiq), NO en el
  # hilo de una request HTTP de Rails. Para uso no bloqueante, usar #poll_once
  # dentro de un job que se reencola a sí mismo.

  def poll_until_done(task_id, on_tick: nil)
    elapsed = 0
    tick    = 0

    loop do
      result = poll_once(task_id)
      on_tick&.call(result, elapsed)

      return result if result.terminal?

      raise HappyHorse::TaskTimeoutError, "task #{task_id} exceeded #{MAX_POLL_SECONDS}s" if elapsed >= MAX_POLL_SECONDS

      wait = POLL_SCHEDULE[tick] || POLL_SCHEDULE.last
      sleep(wait)
      elapsed += wait
      tick += 1
    end
  end

  # Una sola consulta de estado — apto para un Sidekiq job que se reencola
  # con `perform_in(wait_seconds, ...)`. Reintenta transitoriamente (429/5xx)
  # con backoff antes de propagar el error.

  def poll_once(task_id)
    uri = URI("https://#{config.host}#{format(TASK_PATH, task_id: task_id)}")
    response = with_retries("poll(#{task_id})") { http_get(uri) }
    body = safe_parse_json(response.body)

    output = body.dig("output") || {}
    HappyHorse::PollResult.new(
      task_id:       task_id,
      status:        output["task_status"],
      video_url:     output.dig("video_url"),
      error_message: output["message"] || body["message"],
      submit_time:   output["submit_time"],
      end_time:      output["end_time"],
      raw:           body
    )
  end

  # ── Descarga del video resultante a disco (para luego subir a OSS) ─────────
  #
  # Verifica que el archivo descargado no esté vacío/truncado antes de
  # devolver la ruta — evita que un vídeo de 0 bytes se cuele silenciosamente
  # en el montaje final (Editor#assemble reventaría más tarde con un error
  # de ffmpeg mucho más difícil de diagnosticar).

  def download(video_url, to:)
    uri = URI(video_url)
    FileUtils.mkdir_p(File.dirname(to))

    bytes_written = 0
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      request = Net::HTTP::Get.new(uri)
      http.request(request) do |response|
        raise HappyHorse::Error, "download failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        File.open(to, "wb") do |f|
          response.read_body { |chunk| f.write(chunk); bytes_written += chunk.bytesize }
        end
      end
    end

    if bytes_written < 1024
      File.delete(to) if File.exist?(to)
      raise HappyHorse::DownloadVerificationError, "descarga sospechosamente pequeña (#{bytes_written} bytes): #{video_url}"
    end

    logger.info("descargado #{to} (#{(bytes_written / 1024.0 / 1024.0).round(2)} MB)")
    to
  end

  # ── Retry helper de alto nivel (SDD §9.3) ──────────────────────────────────
  #
  # Encapsula la política de reintentos para un shot: 1 reintento en fallo
  # genérico, 1 reintento con prompt reescrito si el fallo es de política
  # de contenido, y luego needs_review (el llamador decide el fallback).

  def submit_with_retries(prompt:, mode:, first_frame_url: nil, ref_image_url: nil,
                           resolution: "720P", ratio: "16:9", duration: 5,
                           negative_prompt: nil, reference_image_urls: nil,
                           max_retries: 2, on_tick: nil)
    attempt = 0
    current_prompt = prompt

    begin
      attempt += 1

      if mode.to_sym == :t2i
        # T2I es síncrono: submit_t2i ya devuelve un PollResult con status SUCCEEDED
        result = submit_t2i(prompt: current_prompt, reference_image_urls: reference_image_urls)
        logger.info("T2I completado síncronamente (intento #{attempt})")
        return result
      end

      provider_duration = self.class.normalize_video_duration(duration)
      requested_duration = begin
        Float(duration)
      rescue ArgumentError, TypeError
        nil
      end
      if requested_duration != provider_duration
        logger.info(
          "Adjusted editorial duration #{duration.inspect}s to supported provider duration " \
          "#{provider_duration}s; the editor will restore the planned timing"
        )
      end

      job = case mode.to_sym
            when :t2v then submit_t2v(prompt: current_prompt, resolution: resolution, ratio: ratio, duration: provider_duration, negative_prompt: negative_prompt)
            when :i2v then submit_i2v(prompt: current_prompt, first_frame_url: first_frame_url, resolution: resolution, duration: provider_duration, negative_prompt: negative_prompt)
            when :r2v then submit_r2v(prompt: current_prompt, ref_image_url: ref_image_url || first_frame_url, resolution: resolution, duration: provider_duration, negative_prompt: negative_prompt)
            else raise ArgumentError, "mode must be :t2v, :i2v, :r2v or :t2i"
            end
      logger.info("submit #{mode} → task_id=#{job.task_id} (intento #{attempt})")

      result = poll_until_done(job.task_id, on_tick: on_tick)
      raise HappyHorse::TaskFailedError, result.error_message.to_s if result.failed?

      result
    rescue HappyHorse::TaskFailedError, HappyHorse::TaskTimeoutError => e
      logger.warn("shot failed (attempt #{attempt}/#{max_retries + 1}): #{e.message}")
      terminal_failure = terminal_request_failure?(e)
      if attempt <= max_retries && !terminal_failure
        current_prompt = sanitize_prompt(current_prompt) if content_policy_failure?(e)
        retry
      end
      logger.warn("provider rejected a non-retryable request; skipping duplicate retries") if terminal_failure
      raise
    end
  end

  # ── Envío por lotes con concurrencia acotada ────────────────────────────────
  #
  # Varios shots de una misma escena pueden ir en paralelo sin saturar la
  # cuota de DashScope. `shots` es un array de hashes con al menos
  # {id:, prompt:, mode:, duration:, resolution:, first_frame_url:}.
  # Devuelve un hash {shot_id => PollResult | Exception}, preservando el
  # orden de entrada de `shots` en el hash resultante.
  #
  # yield(shot, result_or_error) si se da un bloque, útil para actualizar un
  # registro (Shot#update!, video_jobs[], progress bar, etc.) tan pronto
  # como cada shot termina, sin esperar a que termine el lote completo.

  def submit_batch(shots, max_concurrent: 3)
    results = {}
    mutex   = Mutex.new
    queue   = shots.dup

    workers = [max_concurrent, shots.size].min.clamp(1, 8)
    threads = Array.new(workers) do
      Thread.new do
        loop do
          shot = mutex.synchronize { queue.shift }
          break unless shot

          result =
            begin
              submit_with_retries(
                prompt:           shot[:prompt] || shot["prompt"],
                mode:             shot[:mode]   || shot["mode"] || :t2v,
                first_frame_url:  shot[:first_frame_url] || shot["first_frame_url"],
                ref_image_url:    shot[:ref_image_url] || shot["ref_image_url"],
                negative_prompt:  shot[:negative_prompt] || shot["negative_prompt"],
                reference_image_urls: shot[:reference_image_urls] || shot["reference_image_urls"],
                resolution:       shot[:resolution] || shot["resolution"] || "720P",
                duration:         shot[:duration]   || shot["duration"]   || 5
              )
            rescue HappyHorse::Error, ArgumentError => e
              e
            end

          mutex.synchronize { results[shot[:id] || shot["id"]] = result }
          yield(shot, result) if block_given?
        end
      end
    end
    threads.each(&:join)
    results
  end

  private

  def narrative_image_exclusions(prompt)
    text = prompt.to_s
    return "" if text.match?(/ABSOLUTE .*CALIBRATION SHEET|QA-ONLY|measurement grid|technical orthographic/i)
    return "" if text.match?(/(?:sign|screen|page|letter|title card)\s+(?:reads?|says?|shows?)|explicit visible text|diegetic text|text overlay|caption reads?/i)

    NARRATIVE_IMAGE_EXCLUSIONS
  end

  def merged_negative_prompt(custom)
    ([DEFAULT_NEGATIVE_PROMPT] + custom.to_s.split(",")).map(&:strip).reject(&:empty?).uniq.join(", ")
  end

  def provider_reference_input!(value, label:)
    StableMedia.provider_input(value) ||
      raise(ArgumentError, "#{label} is expired or has no durable local copy")
  end

  # Heurística simple; en producción esto delega a QwenRouter (modelo barato)
  # para reescribir el prompt eliminando términos problemáticos (SDD §9.3).
  def content_policy_failure?(error)
    msg = error.message.to_s.downcase
    msg.include?("policy") || msg.include?("sensitive") || msg.include?("risk_control")
  end

  # Provider-side schema/parameter failures are deterministic. Repeating the
  # exact request only wastes latency and quota; prompt/policy failures retain
  # the existing retry and sanitization behavior.
  def terminal_request_failure?(error)
    return false if error.is_a?(HappyHorse::TaskTimeoutError)

    message = error.message.to_s.downcase
    message.match?(/duration.*must be.*(?:3|4|5)/) ||
      message.match?(/invalid (?:parameter|request|resolution|aspect ratio)/) ||
      message.match?(/parameter.*(?:invalid|unsupported)/)
  end

  def sanitize_prompt(prompt)
    prompt.gsub(/\b(violence|gore|weapon|blood)\b/i, "").squeeze(" ").strip
  end

  def submit(payload)
    uri = URI("https://#{config.host}#{SYNTHESIS_PATH}")
    response = with_retries("submit(#{payload[:model]})") { http_post(uri, payload) }
    body = safe_parse_json(response.body)

    unless response.is_a?(Net::HTTPSuccess)
      raise HappyHorse::Error, "DashScope error #{response.code}: #{body['message'] || response.body[0, 300]}"
    end

    HappyHorse::SubmitResult.new(
      task_id:    body.dig("output", "task_id"),
      request_id: body["request_id"],
      raw:        body
    )
  end

  # Cualquier fallo de parseo se convierte SIEMPRE en HappyHorse::Error —
  # nunca dejamos escapar un JSON::ParserError crudo, porque eso rompería
  # el contrato de #submit_batch (que solo rescata HappyHorse::Error por
  # shot) y tumbaría el hilo entero en vez de degradar ese shot a fallback.
  # Casos reales que esto cubre: proxies corporativos, balanceadores o
  # gateways que devuelven HTML/texto plano en vez de JSON ante un 502/504.
  def safe_parse_json(raw_body)
    JSON.parse(raw_body)
  rescue JSON::ParserError
    raise HappyHorse::Error, "Respuesta no-JSON de DashScope: #{raw_body.to_s[0, 300]}"
  end

  # Backoff exponencial + jitter compartido para submit y poll — evita
  # martillar DashScope con reintentos sincronizados cuando varios shots
  # fallan a la vez dentro de #submit_batch.
  def with_retries(label, max_retries: MAX_SUBMIT_RETRIES)
    attempt = 0
    begin
      attempt += 1
      response = yield
      raise HappyHorse::TransientHttpError, "HTTP #{response.code}" if response.code.to_i == 429 || response.code.to_i >= 500
      response
    rescue HappyHorse::TransientHttpError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
      if attempt <= max_retries
        wait = (2**attempt) * 0.5 + rand * 0.3
        logger.warn("#{label}: #{e.message} — reintentando en #{wait.round(1)}s (#{attempt}/#{max_retries})")
        sleep(wait)
        retry
      end
      raise HappyHorse::Error, "#{label} failed after #{attempt} attempts: #{e.message}"
    end
  end

  def http_post(uri, payload)
    http = build_http(uri)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"]      = "application/json"
    request["Authorization"]     = "Bearer #{config.api_key}"
    request["X-DashScope-Async"] = "enable"
    request.body = JSON.generate(payload)
    http.request(request)
  end

  # Versión síncrona: omite X-DashScope-Async (requerido para wan2.7-image-pro
  # que sólo acepta llamadas síncronas y rechaza el header async con 403).
  def http_post_sync(uri, payload)
    http = build_http(uri)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"]  = "application/json"
    request["Authorization"] = "Bearer #{config.api_key}"
    request.body = JSON.generate(payload)
    http.request(request)
  end

  def http_get(uri)
    http = build_http(uri)
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{config.api_key}"
    http.request(request)
  end

  def build_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = config.read_timeout
    http.open_timeout = config.open_timeout
    http
  end

  def validate_resolution!(value)
    raise ArgumentError, "invalid resolution: #{value.inspect}" unless VALID_RESOLUTIONS.include?(value.to_s)
  end

  def validate_ratio!(value)
    raise ArgumentError, "invalid aspect ratio: #{value.inspect}" unless VALID_RATIOS.include?(value.to_s)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Ejemplo de integración con Sidekiq (referencia — no ejecuta nada aquí)
#
# class VideoSynthesisJob
#   include Sidekiq::Job
#
#   def perform(shot_id, task_id = nil)
#     shot   = Shot.find(shot_id)
#     client = HappyHorseClient.new(logger: Rails.logger)
#
#     if task_id.nil?
#       job = shot.mode.to_sym == :i2v ?
#         client.submit_i2v(prompt: shot.visual_prompt, first_frame_url: shot.first_frame_url,
#                            resolution: shot.resolution, duration: shot.duration) :
#         client.submit_t2v(prompt: shot.visual_prompt, resolution: shot.resolution,
#                            duration: shot.duration)
#       shot.update!(dashscope_task_id: job.task_id, status: "RUNNING")
#       return self.class.perform_in(5.seconds, shot_id, job.task_id)
#     end
#
#     result = client.poll_once(task_id)
#     case
#     when result.succeeded?
#       path = client.download(result.video_url, to: Rails.root.join("tmp", "shots", "#{shot_id}.mp4"))
#       UploadShotToOssJob.perform_later(shot_id, path)
#       shot.update!(status: "SUCCEEDED")
#     when result.failed?
#       shot.increment!(:retries)
#       shot.retries <= 2 ? self.class.perform_in(2.seconds, shot_id) : shot.update!(status: "needs_review")
#     else
#       self.class.perform_in(10.seconds, shot_id, task_id)
#     end
#   end
# end
# =============================================================================

if __FILE__ == $PROGRAM_NAME
  # Smoke test manual: ruby happy_horse_client.rb "prompt de prueba"
  prompt = ARGV.join(" ")
  abort "Uso: ruby happy_horse_client.rb \"prompt\"" if prompt.strip.empty?

  client = HappyHorseClient.new(logger: HappyHorse::StdoutLogger.new)
  puts "▶ Submitting t2v..."
  job = client.submit_t2v(prompt: prompt, duration: 5)
  puts "  task_id: #{job.task_id}"

  puts "▶ Polling..."
  result = client.poll_until_done(job.task_id) { |r, elapsed| puts "  [#{elapsed}s] #{r.status}" }

  if result.succeeded?
    puts "✓ Video ready: #{result.video_url}"
  else
    puts "✗ Failed: #{result.error_message}"
  end
end
