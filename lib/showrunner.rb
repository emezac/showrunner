# frozen_string_literal: true
# =============================================================================
# showrunner.rb — AI Showrunner DSL + pipeline ejecutable end-to-end
#
# Ruby DSL → manifest interno → pipeline en Ruby (Screenwriter, Storyboarder,
# VideoSynth, Editor) → HappyHorse (vía happy_horse_client.rb) → QwenRouter
# (vía qwen_router.rb) → ffmpeg.
#
# Cambios respecto a la v1 (SDD borrador):
#   · Ya NO delega a un showrunner_engine.py inexistente — el pipeline corre
#     íntegramente en Ruby, reusando el patrón de comic_ai.rb/video_sketch.rb
#     (DSL declarativo + Builder) pero ejecutando de verdad, no solo
#     compilando un manifest para otro proceso.
#   · Clasificación, arquitectura de historia y guion técnico llaman a
#     QwenRouter con presupuesto previo. El storyboard se compila de forma
#     determinista para no perder intención durante otra reescritura.
#   · Fallos de un shot individual no tumban la pasada completa: se
#     sustituyen por un still-frame de fallback (SDD §9.3) para que el
#     pipeline siempre entregue un corte completo.
#   · `dry_run: true` corre todo el pipeline SIN red (ni Qwen ni HappyHorse):
#     usa plantillas locales deterministas. Pensado para ensayar el demo de
#     3 minutos sin quemar presupuesto de tokens/créditos de vídeo antes de
#     la grabación final (mitigación de riesgo, SDD §12).
#
# IMPORTANTE (product framing): la estrategia de transmutación narrativa
# (StoryEngine, internamente inspirada en myth_compiler.rb) es un detalle
# interno. El manifest solo expone claves "story"/"screenplay", nunca
# "myth"/"dna" — ver StoryEngine y ShowrunnerEngine#to_manifest.
#
# Requisitos: Ruby 3.x, ffmpeg en PATH, y en el entorno:
#   QWEN_TOKEN (o DASHSCOPE_API_KEY)
#
# Uso básico:
#   require_relative "showrunner"
#
#   result = Showrunner.produce(
#     prompt:          "Un contrabandista descubre que su carga tiene alma propia",
#     output:          "drama_#{SecureRandom.uuid}.mp4",
#     target_duration: 75,
#     resolution:      "720P",
#     token_budget:    18_000,
#     quality:         "high"
#   )
#
#   result.info
#   result.dry_run                 # inspecciona el manifest sin gastar nada
#   result.render!(verbose: true)  # ejecuta el pipeline completo
#
# Uso CLI:
#   ruby showrunner.rb "Un contrabandista descubre que su carga tiene alma propia"
#   ruby showrunner.rb "..." --seed 482913 --duration 60 --render
#   ruby showrunner.rb "..." --dry-run          # sin red, para ensayar
# =============================================================================

require "json"
require "digest"
require "active_support/security_utils"
require "tempfile"
require "securerandom"
require "fileutils"
require "shellwords"
require "open3"

require_relative "qwen_router"
require_relative "happy_horse_client"
require_relative "../app/services/edit_decision_list"
require_relative "../app/services/screenplay_planner"
require_relative "../app/services/production_bible"
require_relative "../app/services/continuity_planner"
require_relative "../app/services/storyboard_prompt_compiler"
require_relative "../app/services/screenplay_evaluator"
require_relative "../app/services/script_consistency_validator"
require_relative "../app/services/continuity_plate_planner"

# ─────────────────────────────────────────────────────────────────────────────
# DOTENV LOADER — carga .env sin depender de la gema `dotenv`
#
# QwenRouter::Config.default y HappyHorse::Config.default solo leen
# variables YA presentes en ENV — nunca leían el archivo .env por sí solos.
# Esto carga `.env` del directorio actual (donde ejecutas `ruby
# showrunner.rb`) y, si no existe ahí, del directorio donde vive este
# archivo. Nunca sobreescribe una variable que ya esté exportada en el
# shell — el entorno real siempre gana sobre el .env.
# ─────────────────────────────────────────────────────────────────────────────

module DotenvLoader
  def self.load!(path)
    return false unless File.exist?(path)
    # `.env` is project source and may contain accented prompt values. Read it
    # explicitly as UTF-8 so test/worker processes running under the minimal C
    # locale do not crash before the pipeline starts.
    File.readlines(path, encoding: "UTF-8").each do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")
      key, value = line.split("=", 2)
      next unless key && value
      key   = key.strip
      value = value.strip.gsub(/\A(["'])(.*)\1\z/, '\2')
      ENV[key] ||= value
    end
    true
  end

  # Busca .env en: directorio de trabajo actual → directorio de este script.
  # Devuelve la ruta cargada, o nil si no encontró ninguno.
  def self.autoload!
    candidates = [File.join(Dir.pwd, ".env"), File.join(__dir__, ".env")].uniq
    found = candidates.find { |p| load!(p) }
    found
  end
end

DotenvLoader.autoload!

# ─────────────────────────────────────────────────────────────────────────────
# FFMPEG RUNNER — ejecuta ffmpeg SIN silenciar errores y con diagnóstico útil
#
# Bug real encontrado en macOS: los builds de Homebrew de ffmpeg suelen
# compilarse SIN --enable-libfontconfig, así que `drawtext` sin `fontfile=`
# explícito falla con "Cannot find a valid font...". El código original
# mandaba stderr a /dev/null, así que ese fallo quedaba invisible hasta que
# el paso siguiente (xfade/concat) se topaba con archivos inexistentes.
# Esta clase centraliza TODAS las invocaciones a ffmpeg del pipeline para
# que un fallo real siempre sea audible y traiga el motivo.
# ─────────────────────────────────────────────────────────────────────────────

module FfmpegRunner
  class Error < StandardError; end

  def self.run!(args, label:)
    _stdout, stderr, status = Open3.capture3(*args)
    unless status.success?
      raise Error, "ffmpeg (#{label}) failed (exit code #{status.exitstatus}):\n#{stderr.lines.last(20).join}"
    end
    stderr
  end

  # Busca una fuente TrueType/OTF instalada — necesario para drawtext en
  # builds de ffmpeg sin fontconfig (típico en macOS/Homebrew). Si no
  # encuentra ninguna, drawtext se omite en vez de fallar (el clip de
  # fallback igual se genera, solo sin el texto de aviso).
  CANDIDATE_FONTS = [
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf",
    "/mnt/c/Windows/Fonts/arialbd.ttf",
  ].freeze

  def self.system_font
    @system_font ||= CANDIDATE_FONTS.find { |p| File.exist?(p) }
  end

  # Algunos builds de ffmpeg (p.ej. Homebrew sin --enable-libfreetype) no
  # compilan el filtro drawtext en absoluto — no es solo falta de fuente,
  # el filtro ni existe. Lo detectamos una vez y lo cacheamos.
  def self.drawtext_available?
    return @drawtext_available unless @drawtext_available.nil?
    stdout, _stderr, _status = Open3.capture3("ffmpeg", "-hide_banner", "-filters")
    @drawtext_available = stdout.include?("drawtext")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# VALIDACIÓN
# ─────────────────────────────────────────────────────────────────────────────

module ShowrunnerValidation
  VALID_RESOLUTIONS  = %w[480P 720P 1080P].freeze
  VALID_VIDEO_MODELS = %i[happyhorse_1_1].freeze

  def self.resolution!(value)
    v = value.to_s
    raise ArgumentError, "invalid resolution: #{value.inspect} (use #{VALID_RESOLUTIONS.join(', ')})" unless VALID_RESOLUTIONS.include?(v)
    v
  end

  def self.token_budget!(value)
    v = value.to_i
    raise ArgumentError, "token_budget debe ser > 0" unless v.positive?
    v
  end

  def self.prompt!(value)
    v = value.to_s.strip
    raise ArgumentError, "prompt no puede estar vacío" if v.empty?
    raise ArgumentError, "prompt demasiado largo (máx 2000 chars)" if v.length > 2000
    v
  end

  def self.video_model!(value)
    v = value.to_sym
    raise ArgumentError, "invalid video_model: #{value.inspect}" unless VALID_VIDEO_MODELS.include?(v)
    v
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# CATÁLOGO — historias base y dominios destino (SDD §4.3: 8–10 para el demo)
# ─────────────────────────────────────────────────────────────────────────────

module StoryCatalog
  BASE_STORIES = [
    { id: "bs_001", genes: %i[forbidden_love sacrifice betrayal],        tone: :tragic,  archetype: :doomed_lovers },
    { id: "bs_002", genes: %i[rise_to_power corruption betrayal],        tone: :dark,    archetype: :reluctant_heir },
    { id: "bs_003", genes: %i[revenge identity_crisis truth_revelation], tone: :dark,    archetype: :avenger },
    { id: "bs_004", genes: %i[mentor_death transformation awakening],   tone: :hopeful, archetype: :chosen_one },
    { id: "bs_005", genes: %i[exile return redemption],                 tone: :epic,    archetype: :exiled_heir },
    { id: "bs_006", genes: %i[loyalty_test power_struggle sacrifice],   tone: :epic,    archetype: :loyal_general },
    { id: "bs_007", genes: %i[forbidden_knowledge corruption exile],    tone: :dark,    archetype: :seeker },
    { id: "bs_008", genes: %i[doomed_romance inheritance betrayal],     tone: :tragic,  archetype: :heir_in_love },
  ].freeze

  def self.compatible_with(tone)
    pool = BASE_STORIES.select { |s| s[:tone] == tone }
    pool = BASE_STORIES if pool.empty?
    pool
  end
end

module DomainCatalog
  DOMAINS = {
    space_opera:        %i[epic tragic dark],
    cyberpunk_megacity: %i[dark tragic],
    medieval_europe:    %i[epic tragic hopeful],
    corporate_dystopia: %i[dark],
    wild_west:          %i[dark epic],
    feudal_japan:       %i[epic tragic],
    post_apocalyptic:   %i[dark epic],
    mythology_greek:    %i[epic tragic],
    mythology_nordic:   %i[epic tragic dark],
    steampunk_empire:   %i[hopeful epic],
    horror_gothic:      %i[dark tragic],
    political_thriller: %i[dark],
  }.freeze

  def self.compatible_with(tone)
    pool = DOMAINS.select { |_k, tones| tones.include?(tone) }.keys
    pool = DOMAINS.keys if pool.empty?
    pool
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# ENTITY BIBLE — descriptores fijos de protagonista/carga (fix brutal #2 y #4
# del feedback de continuidad: "el personaje cambia demasiado" / "la caja
# debería ser un personaje"). No confiamos en que el LLM mantenga estos
# rasgos consistentes a través de llamadas independientes de guion,
# storyboard y compresión — los generamos UNA vez, determinísticamente a
# partir del seed, y los inyectamos en Ruby en cada shot más adelante
# (ConsistencyEnforcer), sin importar qué haya escrito el modelo.
# ─────────────────────────────────────────────────────────────────────────────

module EntityBible
  PROTAGONIST_AGES   = [34, 38, 42, 47, 51].freeze
  PROTAGONIST_HAIR   = ["cabello largo canoso", "cabello corto oscuro", "cabello rapado", "cabello castaño trenzado"].freeze
  PROTAGONIST_FACE   = ["barba completa entrecana", "rostro afeitado con cicatriz en la ceja", "barba corta oscura", "cicatriz vertical en el ojo izquierdo"].freeze
  PROTAGONIST_COAT   = ["abrigo de cuero gastado", "capa azul oscuro raída", "chaqueta militar remendada", "poncho de lana gris"].freeze

  CARGO_MATERIAL = ["caja de madera tallada con runas plateadas", "cofre de hierro oxidado con remaches", "baúl de cedro sellado con cadenas", "contenedor metálico abollado con símbolos grabados"].freeze
  CARGO_GLOW     = ["luz azul palpitante entre las rendijas", "resplandor rojizo intermitente", "vapor tenue y frío escapando de las juntas", "brillo dorado pulsante como un latido"].freeze

  # Devuelve [protagonist_bible, cargo_bible] — dos frases cortas y fijas
  # que se repiten LITERALMENTE en cada shot del corto, sin importar la
  # escena o el modelo que redactó el visual_prompt original.
  def self.build(seed:, archetype:, domain:)
    rng = Random.new(seed)
    protagonist = "#{archetype.to_s.tr('_', ' ')} de #{PROTAGONIST_AGES.sample(random: rng)} años, " \
                  "#{PROTAGONIST_HAIR.sample(random: rng)}, #{PROTAGONIST_FACE.sample(random: rng)}, " \
                  "#{PROTAGONIST_COAT.sample(random: rng)}"
    cargo = "#{CARGO_MATERIAL.sample(random: rng)}, #{CARGO_GLOW.sample(random: rng)}"
    [protagonist, cargo]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# NARRATIVE BEATS — curva emocional obligatoria + cámara/ritmo por beat (fix
# brutal #3, #5, #10, #11, #12: "todo mantiene el mismo nivel emocional",
# "falta un clímax", "pocos cambios de ritmo", "revela demasiado poco").
# Igual que con EntityBible, no confiamos en que el LLM produzca una curva
# dramática por sí solo — la estructura se IMPONE en código, y el prompt del
# guionista solo tiene que rellenarla.
# ─────────────────────────────────────────────────────────────────────────────

module NarrativeBeats
  CURVE = %w[mystery curiosity escalation danger climax revelation aftermath].freeze

  # Orden de importancia narrativa — usado cuando hay MENOS escenas que
  # beats (piezas cortas de demo): "climax" y "revelation" nunca deben
  # sacrificarse por recorte (eso es justamente lo que el feedback marcó
  # como "falta un clímax"); "mystery" es lo segundo más protegido porque
  # sin insinuación inicial la revelación no revela nada.
  PRIORITY = %w[climax revelation mystery danger aftermath curiosity escalation].freeze

  # Reparte la curva sobre n escenas:
  #  · n >= CURVE.size: repite beats intermedios para rellenar, manteniendo
  #    siempre mystery al inicio y aftermath al final.
  #  · n < CURVE.size: en vez de muestrear parejo (lo que en piezas muy
  #    cortas puede saltarse el clímax por completo), se seleccionan los n
  #    beats más importantes por PRIORITY y se reordenan cronológicamente.
  def self.assign(n_scenes)
    return ["climax"] if n_scenes <= 1
    return CURVE.dup if n_scenes == CURVE.size

    if n_scenes > CURVE.size
      stretched = [CURVE.first]
      middle = CURVE[1..-2]
      (n_scenes - 2).times { |i| stretched << middle[i % middle.size] }
      stretched << CURVE.last
      stretched
    else
      chosen = PRIORITY.first(n_scenes)
      chosen.sort_by { |beat| CURVE.index(beat) }
    end
  end

  CAMERA_BY_BEAT = {
    "mystery"    => %w[slow_push_in close_up_detail static_wide],
    "curiosity"  => %w[slow_pan tracking_shot close_up],
    "escalation" => %w[handheld tracking_shot dutch_angle],
    "danger"     => %w[handheld whip_pan close_up],
    "climax"     => %w[handheld close_up dutch_angle],
    "revelation" => %w[slow_push_in overhead close_up_detail],
    "aftermath"  => %w[static_wide slow_pull_back],
  }.freeze

  # Duración de transición xfade por beat — cortes más rápidos y bruscos en
  # tensión alta, más lentos y contemplativos en misterio/desenlace. Esto
  # es lo que le da ritmo de montaje a la pieza en vez de un xfade uniforme.
  TRANSITION_BY_BEAT = {
    "mystery"    => 0.8, "curiosity" => 0.6, "escalation" => 0.4,
    "danger"     => 0.25, "climax"    => 0.2, "revelation" => 0.5, "aftermath" => 0.9,
  }.freeze

  # Nunca repite la cámara anterior si hay alternativa en el pool del beat —
  # así se garantiza variedad de plano shot a shot (fix "todos los planos
  # tienen prácticamente la misma intensidad").
  def self.camera_for(beat, previous_camera, rng)
    pool = CAMERA_BY_BEAT.fetch(beat, %w[static_wide close_up tracking_shot])
    candidates = pool.reject { |c| c == previous_camera }
    candidates = pool if candidates.empty?
    candidates.sample(random: rng)
  end

  def self.transition_for(beat)
    TRANSITION_BY_BEAT.fetch(beat, 0.5)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# STORY ENGINE — selección oculta (nunca expuesta al usuario/jueces)
# ─────────────────────────────────────────────────────────────────────────────

module StoryEngine
  Selection = Struct.new(:base_story, :domain, :tone, :seed,
                         :protagonist_bible, :cargo_bible, keyword_init: true)

  def self.select!(prompt:, seed: nil, tone: nil, force_story: nil, force_domain: nil)
    seed ||= Digest::SHA256.hexdigest(prompt).to_i(16) % 1_000_000
    rng    = Random.new(seed)
    tone ||= infer_tone_offline(prompt)

    story  = force_story  || StoryCatalog.compatible_with(tone).sample(random: rng)
    domain = force_domain || DomainCatalog.compatible_with(tone).sample(random: rng)
    story  = StoryCatalog::BASE_STORIES.find { |s| s[:id] == story } if story.is_a?(String)

    protagonist_bible, cargo_bible = EntityBible.build(seed: seed, archetype: story[:archetype], domain: domain)

    Selection.new(base_story: story, domain: domain, tone: tone, seed: seed,
                  protagonist_bible: protagonist_bible, cargo_bible: cargo_bible)
  end

  # Clasificación real (Stage 1, SDD §6): una llamada barata a Qwen. Se usa
  # cuando hay presupuesto y red; si falla o se agota el budget, cae a
  # #infer_tone_offline para que el pipeline nunca se bloquee por esto solo
  # (es la etapa más barata y la menos crítica para "quedarse sin tokens").
  def self.classify_tone!(prompt, ledger:, config: QwenRouter::Config.default)
    system = "Clasificas el tono narrativo dominante de un prompt de historia. " \
             "Responde SOLO JSON: {\"tone\": uno de [tragic, dark, hopeful, epic]}."
    parsed, = QwenRouter.call_json(system: system, user: prompt, stage: :classify,
                                    max_tokens: 40, ledger: ledger, config: config)
    tone = parsed["tone"].to_s.to_sym
    %i[tragic dark hopeful epic].include?(tone) ? tone : infer_tone_offline(prompt)
  rescue QwenRouter::Error
    infer_tone_offline(prompt)
  end

  def self.select_faithful!(prompt:, seed: nil, tone: nil, ledger: nil, config: QwenRouter::Config.default)
    seed ||= Digest::SHA256.hexdigest(prompt).to_i(16) % 1_000_000
    tone ||= infer_tone_offline(prompt)
    
    # Qwen call to extract core elements from the user's initial prompt with high fidelity
    system = "You are an assistant that extracts the core elements of a screenplay prompt. " \
             "Extract: 1) the main setting/world as a single word or 2-word domain name, " \
             "2) a detailed physical description of the protagonist (if the prompt contains explicit physical/visual details, extract them in full detail; otherwise, summarize the character in 2-3 detailed sentences), and " \
             "3) a detailed description of the central focus object/cargo/relic (if present, extract the details in full; otherwise, a 1-2 sentence description). " \
             "Respond ONLY with a valid JSON object matching this schema exactly: " \
             "{\"domain\": string, \"protagonist\": string, \"cargo\": string}."
             
    parsed = nil
    begin
      parsed, = QwenRouter.call_json(
        system: system,
        user: prompt,
        stage: :classify,
        max_tokens: 1000,
        ledger: ledger,
        config: config
      )
    rescue StandardError
      parsed = {
        "domain" => "unspecified_setting",
        "protagonist" => "the main character",
        "cargo" => "the mysterious focus object"
      }
    end

    domain_str = (parsed["domain"] || "unspecified_setting").to_s.downcase.gsub(/[^a-z0-9_]/, "_").gsub(/_+/, "_")
    protagonist_bible = parsed["protagonist"] || "the main character"
    cargo_bible = parsed["cargo"] || "the mysterious focus object"

    base_story = {
      id: "faithful_prompt",
      archetype: :faithful_protagonist,
      genes: [:custom_prompt]
    }

    Selection.new(
      base_story: base_story,
      domain: domain_str.to_sym,
      tone: tone,
      seed: seed,
      protagonist_bible: protagonist_bible,
      cargo_bible: cargo_bible
    )
  end

  # Heurística barata y determinista — fallback local para que el DSL nunca
  # bloquee por falta de red/presupuesto en la etapa de clasificación.
  def self.infer_tone_offline(prompt)
    p = prompt.downcase
    return :dark    if p =~ /traici|corrup|venganza|oscur/
    return :tragic  if p =~ /amor|prohibid|sacrifici|muerte/
    return :hopeful if p =~ /esperanza|renace|despert/
    :epic
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# STORY ARCHITECT — Stage 3a: causal outline and scene cards before shot design
# ─────────────────────────────────────────────────────────────────────────────

module StoryArchitect
  MIN_OUTPUT_TOKENS = 2_400
  TOKENS_PER_SCENE = 420
  MAX_OUTPUT_TOKENS = 6_000
  REPAIR_MIN_OUTPUT_TOKENS = 1_800
  REPAIR_TOKENS_PER_SCENE = 320
  REPAIR_MAX_OUTPUT_TOKENS = 4_800

  def self.generate!(selection:, prompt:, shape:, ledger:, config:, adaptation_mode: "faithful")
    system = <<~SYS
      Eres arquitecto narrativo para cortometrajes de cualquier género.
      Responde ÚNICAMENTE JSON válido con este esquema:
      {
        "title": string,
        "story_outline": {
          "premise": string, "structure": string,
          "central_question": string, "resolution": string
        },
        "scene_cards": [{
          "id": string, "heading": string, "beat": string,
          "objective": string, "conflict": string, "turn": string,
          "outcome": string, "continuity_in": object,
          "continuity_out": object,
          "dialogue": [{"character": string, "line": string}]
        }]
      }
      Diseña aproximadamente #{shape[:scenes]} escenas para
      #{shape[:target_duration].round(2)} segundos. Todavía NO diseñes planos,
      cámaras ni prompts visuales. Cada resultado de escena debe causar o
      condicionar la siguiente. Elige una estructura apropiada al prompt; no
      impongas misterio, ciencia ficción, violencia, objetos ni personajes.
      Si hay diálogo, mantenlo breve y filmable dentro del tiempo disponible.
    SYS
    context = if adaptation_mode == "faithful"
                "Adapta literalmente el dominio, sujetos, relaciones y conflicto del usuario."
              else
                "Dominio=#{selection.domain}; tono=#{selection.tone}; genes=#{selection.base_story[:genes].join(', ')}"
              end
    output_tokens = architecture_output_tokens(shape[:scenes])
    parsed, result = QwenRouter.call_json(
      system: system,
      user: "Prompt: #{prompt}\nModo: #{adaptation_mode}. #{context}",
      stage: :story_architecture,
      max_tokens: output_tokens,
      ledger: ledger,
      config: config
    )

    architecture, normalization_error = normalize_response_safely(parsed)
    return [architecture, result] if valid?(architecture)

    repaired, repair_result = repair_response(
      parsed: parsed,
      prompt: prompt,
      shape: shape,
      ledger: ledger,
      config: config,
      adaptation_mode: adaptation_mode
    )
    return [repaired, repair_result] if valid?(repaired)

    keys = parsed.is_a?(Hash) ? parsed.keys.first(12).join(", ") : parsed.class.name
    normalization_detail = if normalization_error
                             "; normalization error: #{normalization_error.class}: #{normalization_error.message}"
                           else
                             ""
                           end
    raise QwenRouter::MalformedResponse,
      "story architecture is missing scene_cards after schema normalization and repair " \
      "(received: #{keys}#{normalization_detail})"
  end

  def self.architecture_output_tokens(scene_count)
    [[scene_count.to_i * TOKENS_PER_SCENE, MIN_OUTPUT_TOKENS].max, MAX_OUTPUT_TOKENS].min
  end

  def self.valid?(architecture)
    architecture.is_a?(Hash) && Array(architecture["scene_cards"]).any?
  end

  # Qwen occasionally honors the requested content but uses a nearby schema,
  # such as `scenes`, `cards` or `sceneCards`. Recover those responses without
  # spending another request or discarding useful narrative work.
  def self.normalize_response(parsed)
    root = parsed.is_a?(Array) ? { "scene_cards" => parsed } : parsed
    return nil unless root.is_a?(Hash)

    cards = scene_card_candidates(root).find { |candidate| scene_array?(candidate) }
    cards ||= find_nested_scene_array(root)
    return nil unless scene_array?(cards)

    outline = first_hash(
      root["story_outline"], root["storyOutline"], root["outline"],
      hash_path(root, "story", "outline"), hash_path(root, "architecture", "story_outline")
    )
    {
      "title" => first_present(root["title"], root["story_title"], hash_path(root, "story", "title"), "Untitled"),
      "story_outline" => outline,
      "scene_cards" => cards.each_with_index.map { |card, index| normalize_card(card, index) }
    }.compact
  end

  def self.normalize_response_safely(parsed)
    [normalize_response(parsed), nil]
  rescue StandardError => e
    [nil, e]
  end

  def self.repair_response(parsed:, prompt:, shape:, ledger:, config:, adaptation_mode:)
    scene_count = [shape[:scenes].to_i, 1].max
    max_tokens = [
      [REPAIR_MIN_OUTPUT_TOKENS, scene_count * REPAIR_TOKENS_PER_SCENE].max,
      REPAIR_MAX_OUTPUT_TOKENS
    ].min
    system = <<~SYS
      You repair narrative architecture JSON for a short-film production pipeline.
      Return ONLY one valid JSON object with title, story_outline and a non-empty
      scene_cards array. Preserve every usable fact, character, location, event,
      causal relationship and ordering from the source response and user prompt.
      Do not add shots, camera directions, new genres, characters or objects.
      Each scene card may contain id, heading, beat, objective, conflict, turn,
      outcome, continuity_in, continuity_out and dialogue.
    SYS
    user = <<~USR
      User prompt (authoritative, #{adaptation_mode} mode):
      #{prompt}

      Expected scene count: approximately #{scene_count}.
      Response that violated the schema:
      #{JSON.generate(parsed).first(16_000)}
    USR
    repaired, result = QwenRouter.call_json(
      system: system,
      user: user,
      stage: :story_architecture_repair,
      max_tokens: max_tokens,
      ledger: ledger,
      config: config
    )
    normalized, = normalize_response_safely(repaired)
    [normalized, result]
  rescue QwenRouter::Error, JSON::GeneratorError
    [nil, nil]
  end

  def self.scene_card_candidates(root)
    [
      root["scene_cards"], root["sceneCards"], root["cards"], root["scenes"],
      hash_path(root, "story", "scene_cards"), hash_path(root, "story", "scenes"),
      hash_path(root, "architecture", "scene_cards"), hash_path(root, "architecture", "scenes"),
      hash_path(root, "story_architecture", "scene_cards"), hash_path(root, "story_architecture", "scenes")
    ]
  end

  # Hash#dig raises TypeError when an intermediate Qwen value is an Array and
  # the next path component is a String. Model output is untrusted, so traverse
  # only hashes and treat every other shape as an absent optional path.
  def self.hash_path(value, *keys)
    keys.reduce(value) do |current, key|
      break nil unless current.is_a?(Hash)

      current.key?(key) ? current[key] : current[key.to_sym]
    end
  end

  def self.find_nested_scene_array(value, depth = 0)
    return nil if depth > 4
    return value if scene_array?(value)

    children = value.is_a?(Hash) ? value.values : (value.is_a?(Array) ? value : [])
    children.each do |child|
      found = find_nested_scene_array(child, depth + 1)
      return found if found
    end
    nil
  end

  def self.scene_array?(value)
    return false unless value.is_a?(Array) && value.any? && value.all? { |item| item.is_a?(Hash) }

    scene_keys = %w[id scene_id heading title name beat objective goal conflict obstacle turn outcome action summary shots continuity_in continuity_out]
    value.any? { |item| (item.keys.map(&:to_s) & scene_keys).size >= 2 }
  end

  def self.normalize_card(card, index)
    source = card["scene"].is_a?(Hash) ? card["scene"] : card
    aliases = {
      "id" => %w[id scene_id sceneId],
      "heading" => %w[heading title name scene_heading],
      "beat" => %w[beat narrative_beat purpose],
      "objective" => %w[objective goal intent],
      "conflict" => %w[conflict obstacle resistance tension],
      "turn" => %w[turn turning_point reversal change],
      "outcome" => %w[outcome result resolution],
      "continuity_in" => %w[continuity_in continuityIn entry_state],
      "continuity_out" => %w[continuity_out continuityOut exit_state],
      "dialogue" => %w[dialogue dialog lines]
    }
    normalized = aliases.each_with_object({}) do |(target, candidates), memo|
      value = candidates.lazy.map { |key| source[key] }.find { |candidate| present_value?(candidate) }
      memo[target] = value if present_value?(value)
    end
    normalized["id"] ||= "scene_#{format('%02d', index + 1)}"
    normalized["heading"] ||= "SCENE #{index + 1}"
    normalized["action"] = source["action"] if present_value?(source["action"])
    normalized["summary"] = source["summary"] if present_value?(source["summary"])
    normalized["shots"] = source["shots"] if source["shots"].is_a?(Array)
    normalized
  end

  def self.first_hash(*values)
    values.find { |value| value.is_a?(Hash) }
  end

  def self.first_present(*values)
    values.find { |value| present_value?(value) }
  end

  def self.present_value?(value)
    !(value.nil? || (value.respond_to?(:empty?) && value.empty?))
  end

end

# ─────────────────────────────────────────────────────────────────────────────
# SCREENWRITER — Stage 3b: scene cards become an explicit technical shot plan
# ─────────────────────────────────────────────────────────────────────────────

module Screenwriter
  DEFAULT_SHOT_DURATION = 5

  # Reparte target_duration en (scenes × shots) sin desbordar max_scenes.
  def self.plan_shape(target_duration:, shot_duration: DEFAULT_SHOT_DURATION, max_scenes: nil)
    max_scenes = max_scenes.to_i if max_scenes.is_a?(String)
    total_shots = [(target_duration.to_f / shot_duration).ceil, 1].max
    scenes      = [(total_shots / 2.0).ceil, 1].max
    scenes      = [scenes, max_scenes].min if max_scenes && max_scenes > 0
    shots_per_scene = [(total_shots.to_f / scenes).ceil, 1].max
    {
      scenes: scenes,
      shots_per_scene: shots_per_scene,
      shot_duration: shot_duration,
      target_duration: target_duration.to_f
    }
  end

  def self.generate!(selection:, prompt:, target_duration:, max_scenes:, ledger:, config: QwenRouter::Config.default, adaptation_mode: "faithful")
    parsed_custom = parse_scenes_from_prompt(prompt)
    if parsed_custom
      shape = plan_shape(target_duration: target_duration, max_scenes: max_scenes)
      custom_shape = shape.merge(scenes: parsed_custom["scenes"].size)
      return [normalize_screenplay(parsed_custom, custom_shape, seed: selection.seed), nil]
    end

    shape = plan_shape(target_duration: target_duration, max_scenes: max_scenes)
    beats = NarrativeBeats.assign(shape[:scenes])
    architecture, = StoryArchitect.generate!(
      selection: selection,
      prompt: prompt,
      shape: shape,
      ledger: ledger,
      config: config,
      adaptation_mode: adaptation_mode
    )

    system = <<~SYS
      Eres un arquitecto narrativo y guionista técnico para cortometrajes de
      cualquier género. Escribes ÚNICAMENTE JSON válido, sin explicación ni
      markdown. Diseña primero la causalidad de cada escena y después su
      cobertura visual. Esquema exacto:
      {
        "title": string,
        "story_outline": {
          "premise": string, "structure": string,
          "central_question": string, "resolution": string
        },
        "scenes": [
          { "id": string, "heading": string, "action": string, "beat": string,
            "objective": string, "conflict": string, "turn": string,
            "outcome": string,
            "continuity_in": object, "continuity_out": object,
            "dialogue": [ {"character": string, "line": string} ],
            "shots": [ {
              "id": string, "duration": int, "camera": string,
              "editorial_role": "establishing|action|dialogue|reaction|insert|transition|resolution",
              "purpose": string, "story_event": string,
              "entry_state": object, "exit_state": object,
              "blocking": object, "visual_prompt": string,
              "transition_out": {"type": "cut|fade|dissolve|match_cut|dip_to_black", "duration": number, "reason": string}
            } ] }
        ]
      }

      Produce aproximadamente #{shape[:scenes]} escenas y
      #{shape[:scenes] * shape[:shots_per_scene]} planos en total. Distribuye
      los planos según la necesidad dramática: una escena puede necesitar más
      cobertura que otra. La duración total final debe poder ajustarse a
      #{target_duration.to_f.round(2)} segundos.

      REGLAS NARRATIVAS:
        · Cada escena tiene un objetivo, una resistencia concreta, un giro y
          un resultado visible diferente al estado de entrada.
        · Cada plano comunica un único evento atómico y declara para qué existe.
        · entry_state de un plano debe ser compatible con exit_state del anterior.
        · Reserva reacciones e insertos solo cuando añadan información.
        · Selecciona la estructura apropiada al género y al prompt. No impongas
          misterio, revelaciones, ciencia ficción ni objetos que no existan.
        · Preserva geografía, eje, dirección de movimiento y miradas.
        · Usa cortes directos dentro de una acción; usa fundidos únicamente
          cuando exista una razón temporal, espacial o emocional.
        · Antes de redactar planos, verifica cada acción contra identidad,
          proporciones, escala relativa, attachments, articulación, geografía
          y estado persistente declarados por el usuario.
        · Una instrucción de cámara nunca puede cambiar una verdad física. Si
          "parecer más grande" contradice la escala, conserva la escala y usa
          solo prominencia compositiva con referencias dimensionales visibles.
        · Si una figura está fijada o montada y el texto dice que camina sin
          describir antes su liberación, conserva el attachment y convierte la
          aproximación aparente en movimiento de cámara o del soporte.
        · Cambios reales de rostro, cuerpo, vestuario, material, attachment o
          tamaño requieren una variante canónica explícita; no los improvises.
      No reproduzcas texto con copyright — solo estructura y prosa original.

      REGLA DE VARIEDAD VISUAL EN SHOTS:
      Cada "shot" dentro de una escena debe tener un "visual_prompt" completamente diferente y progresivo.
      NO repitas la misma descripción entre shots de la misma escena. Cada toma debe capturar una acción, detalle, composición o ángulo distinto (ej. toma 1: el personaje camina con cautela buscando la caja; toma N.2: primer plano detallado de sus manos enguantadas tocando el frío metal de la caja; toma N.3: la reacción de asombro reflejada en el rostro iluminado del personaje). La repetición de descripciones visuales es un error de dirección grave.

      INSTRUCCIÓN DE DETECCIÓN Y ADAPTACIÓN:
      Si el prompt del usuario describe de manera estructurada escenas específicas, secuencias de tomas (ej. 'Toma 1', 'Toma 2', 'Toma 3' o similares), diálogos o instrucciones de cámara específicas, DEBES detectarlas y mapearlas/estructurarlas directamente en el JSON del screenplay respetando fielmente el contenido, orden, descripciones visuales y tipos de planos de dichas tomas, adaptando únicamente el formato al esquema JSON requerido.
      En este caso, ignora la cantidad aproximada de escenas y tomas. Prioriza la estructura exacta descrita por el usuario (ej. si describen 3 tomas en una sola escena, genera exactamente 1 escena con 3 shots).
      Además, si el prompt trata de un tema no de ciencia ficción o si estás en modo 'faithful', NO uses plantillas ni metáforas genéricas de ciencia ficción (como contenedores espaciales, esclusas o levers de anulación). Adapta la narrativa exclusivamente al contexto provisto por el usuario (ej. si es futbolín, la historia y las acciones deben girar en torno al futbolista y el balón).

      INSTRUCCIÓN DE ADAPTACIÓN:
      #{adaptation_mode == 'faithful' ? 
        'Apégate ESTRICTAMENTE al prompt del usuario. Conserva los personajes, la ambientación, la tecnología/magia, y el conflicto del prompt original sin transmutarlos o mezclarlos con otros géneros.' :
        'Transmuta creativamente el prompt del usuario en la historia base y dominio de ciencia ficción indicados abajo.'
      }
    SYS

    adaptation_context = if adaptation_mode == "faithful"
                           "No agregues personajes, objetos, tecnologías, conflictos ni géneros ajenos al texto."
                         else
                           <<~CONTEXT
                             Dominio destino: #{selection.domain}
                             Tono: #{selection.tone}
                             Arquetipo: #{selection.base_story[:archetype]}
                             Genes narrativos: #{selection.base_story[:genes].join(', ')}
                           CONTEXT
                         end
    user = <<~USR
      Prompt del usuario: #{prompt}
      Modo de adaptación: #{adaptation_mode}
      #{adaptation_context}
      ARQUITECTURA APROBADA — conserva exactamente su causalidad, objetivos,
      giros, resultados, diálogos y orden de escenas; tu tarea es convertirla
      en acciones y planos filmables:
      #{JSON.generate(architecture)}
    USR

    parsed, result = QwenRouter.call_json(
      system: system, user: user, stage: :scriptwrite,
      max_tokens: [2_000, shape[:scenes] * shape[:shots_per_scene] * 180].max,
      ledger: ledger, config: config
    )
    parsed = normalize_generated_response(parsed)
    unless parsed.is_a?(Hash) && Array(parsed["scenes"]).any?
      raise QwenRouter::MalformedResponse,
        "screenplay has an invalid or empty scene collection: #{parsed.inspect[0, 240]}"
    end
    apply_architecture!(parsed, architecture)
    [normalize_screenplay(parsed, shape, beats: beats, seed: selection.seed), result]
  end

  # Qwen may return scenes as an array, a hash keyed by scene id, inside a
  # screenplay/data wrapper, or mixed with separate top-level JSON objects.
  # Convert all supported shapes to one strict, non-empty array of hashes before
  # any code indexes fields by String.
  def self.normalize_generated_response(parsed)
    roots = parsed.is_a?(Array) ? parsed.select { |item| item.is_a?(Hash) } : [parsed].select { |item| item.is_a?(Hash) }
    return nil if roots.empty?

    scenes = find_generated_scenes(parsed)
    return nil unless scenes&.any?

    title = roots.lazy.filter_map do |root|
      first_present_value(root["title"], root["screenplay_title"], StoryArchitect.hash_path(root, "screenplay", "title"))
    end.first
    outline = roots.lazy.filter_map do |root|
      first_hash_value(
        root["story_outline"], root["outline"],
        StoryArchitect.hash_path(root, "screenplay", "story_outline"),
        StoryArchitect.hash_path(root, "story", "outline")
      )
    end.first

    {
      "title" => title || "Untitled",
      "story_outline" => outline,
      "scenes" => scenes.filter_map.with_index { |scene, index| normalize_generated_scene(scene, index) }
    }.compact
  end

  def self.find_generated_scenes(value, depth = 0)
    return nil if depth > 5

    collection = coerce_hash_collection(value)
    matching_scenes = collection.select { |item| generated_scene?(item) }
    return matching_scenes if matching_scenes.any?

    children = value.is_a?(Hash) ? value.values : (value.is_a?(Array) ? value : [])
    children.each do |child|
      found = find_generated_scenes(child, depth + 1)
      return found if found&.any?
    end
    nil
  end

  def self.coerce_hash_collection(value)
    case value
    when Array
      value.flatten.select { |item| item.is_a?(Hash) }
    when Hash
      return [value] if generated_scene?(value)

      values = value.values
      values.all? { |item| item.is_a?(Hash) } ? values : []
    else
      []
    end
  end

  def self.generated_scene?(value)
    return false unless value.is_a?(Hash)

    source = value["scene"].is_a?(Hash) ? value["scene"] : value
    keys = source.keys.map(&:to_s)
    (keys & %w[heading scene_heading objective conflict turn outcome shots takes coverage]).any? ||
      (keys.include?("action") && (keys & %w[camera visual_prompt prompt]).empty?)
  end

  def self.normalize_generated_scene(raw_scene, index)
    source = stringify_generated_keys(raw_scene)
    source = source["scene"] if source["scene"].is_a?(Hash)
    return nil unless source.is_a?(Hash)

    scene = source.dup
    scene["id"] = first_present_value(source["id"], source["scene_id"], source["sceneId"], "scene_#{format('%02d', index + 1)}")
    scene["heading"] = first_present_value(source["heading"], source["scene_heading"], source["title"], source["name"], "SCENE #{index + 1}")
    scene["action"] = first_present_value(source["action"], source["description"], source["summary"], source["story_event"], "")
    scene["dialogue"] = first_present_value(source["dialogue"], source["dialog"], source["lines"], [])
    shots = first_present_value(source["shots"], source["takes"], source["coverage"], source["shot_list"])
    scene["shots"] = coerce_shots(shots).filter_map.with_index do |shot, shot_index|
      normalize_generated_shot(shot, shot_index)
    end
    scene
  end

  def self.coerce_shots(value)
    case value
    when Array
      value.flatten.select { |item| item.is_a?(Hash) }
    when Hash
      shot_values = value.values
      shot_values.all? { |item| item.is_a?(Hash) } ? shot_values : [value]
    else
      []
    end
  end

  def self.normalize_generated_shot(raw_shot, index)
    source = stringify_generated_keys(raw_shot)
    source = source["shot"] if source["shot"].is_a?(Hash)
    return nil unless source.is_a?(Hash)

    shot = source.dup
    shot["id"] = first_present_value(source["id"], source["shot_id"], source["shotId"], (index + 1).to_s)
    shot["visual_prompt"] = first_present_value(
      source["visual_prompt"], source["prompt"], source["description"],
      source["action"], source["story_event"], source["event"], ""
    )
    shot["story_event"] ||= first_present_value(source["event"], source["action"], shot["visual_prompt"])
    shot["camera"] ||= first_present_value(source["camera"], source["framing"], source["shot_type"])
    shot
  end

  def self.stringify_generated_keys(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, item), output| output[key.to_s] = stringify_generated_keys(item) }
    when Array
      value.map { |item| stringify_generated_keys(item) }
    else
      value
    end
  end

  def self.first_present_value(*values)
    values.find { |value| !(value.nil? || (value.respond_to?(:empty?) && value.empty?)) }
  end

  def self.first_hash_value(*values)
    values.find { |value| value.is_a?(Hash) }
  end

  def self.apply_architecture!(parsed, architecture)
    parsed["title"] ||= architecture["title"]
    parsed["story_outline"] ||= architecture["story_outline"]
    cards = Array(architecture["scene_cards"])
    Array(parsed["scenes"]).select { |scene| scene.is_a?(Hash) }.each_with_index do |scene, index|
      card = cards.find { |candidate| candidate["id"].to_s == scene["id"].to_s } || cards[index]
      next unless card.is_a?(Hash)

      %w[id heading beat objective conflict turn outcome continuity_in continuity_out dialogue].each do |field|
        scene[field] = card[field] if card.key?(field)
      end
    end
    parsed
  end

  def self.parse_scenes_from_prompt(prompt)
    lines = prompt.to_s.split("\n")
    scenes = []
    current_scene = nil
    current_shot = nil
    pending_character = nil
    global_style_directives = []
    skipping_profile_section = false
    source_profile_lines = []
    source_character_lines = []
    source_location_lines = []
    current_profile_kind = nil

    profile_pattern = /character|protagonist|hero|héroe|actor|perfil|profile|description|descripción|locacion|location|setting|ambiente|esquema|instrucción/i
    scene_pattern = /\A(?:##\s+(?!#)|(?:ESCENA|SCENE)\s+\d+\s*[:.\-]?\s*|(?:INT\.?|EXT\.?|INT\.?\s*\/\s*EXT\.?)\s+)(.+)\z/i
    shot_pattern = /\A(?:###\s+(?!#)|(?:TOMA|SHOT|PLANO)\s*\d*\s*[:.\-]?\s*)(.+)\z/i
    camera_pattern = /\A(?:c[aá]mara|camera|encuadre|framing)\s*:\s*(.+)\z/i
    duration_pattern = /(?:duraci[oó]n\s*:\s*)?(\d+(?:\.\d+)?)\s*(?:s|seg|secs?|seconds?)\b/i
    dialogue_pattern = /\A([\p{L}][\p{L}\d _\-]{1,30})\s*:\s*(.+)\z/u

    lines.each do |line|
      line_stripped = line.strip
      next if line_stripped.empty?

      if (match = line_stripped.match(/\A\[(Cinematic Genre|Director Style|Camera Direction|Color Palette & Grading)\]\s*:\s*(.+)\z/i))
        global_style_directives << "#{match[1]}: #{match[2]}"
      elsif line_stripped.match?(/\A\[(Target Audience|Brain Dump \/ Unstructured Draft|Narrative Context)\]\s*:/i)
        # Planning context must not be appended to the final shot as an action.
        next
      elsif (match = line_stripped.match(scene_pattern))
        title = match[1].to_s.strip
        title = line_stripped if line_stripped.match?(/\A(?:INT|EXT)/i)
        if title =~ profile_pattern
          skipping_profile_section = true
          current_scene = nil
          current_shot = nil
          source_profile_lines << title
          current_profile_kind = title.match?(/locacion|location|setting|ambiente/i) ? :locations : :characters
          (current_profile_kind == :locations ? source_location_lines : source_character_lines) << title
          next
        end
        skipping_profile_section = false

        current_scene = {
          "heading" => title.upcase,
          "action" => "",
          "dialogue" => [],
          "shots" => []
        }
        scenes << current_scene
        current_shot = nil
        pending_character = nil
      elsif skipping_profile_section
        # Keep identity/location reference material out of dramatic action, but
        # never discard it: the asset profiler needs this source-of-truth block.
        source_profile_lines << line_stripped.sub(/\A#+\s*/, "")
        target = current_profile_kind == :locations ? source_location_lines : source_character_lines
        target << line_stripped.sub(/\A#+\s*/, "")
        next
      elsif (match = line_stripped.match(shot_pattern))
        title = match[1].to_s.strip
        if current_scene.nil?
          current_scene = {
            "heading" => "INTRO",
            "action" => "",
            "dialogue" => [],
            "shots" => []
          }
          scenes << current_scene
        end
        current_shot = {
          "title" => title,
          "description_lines" => [],
          "camera" => title.sub(duration_pattern, "").strip.presence,
          "duration" => title[duration_pattern, 1]&.to_f
        }
        current_scene["shots"] << current_shot
        pending_character = nil
      elsif current_scene && (match = line_stripped.match(camera_pattern))
        if current_shot
          current_shot["camera"] = match[1].strip
        else
          current_scene["camera"] = match[1].strip
        end
      elsif current_scene && line_stripped.match?(/\A(?:duraci[oó]n|duration)\s*:/i)
        seconds = line_stripped[duration_pattern, 1]&.to_f
        current_shot["duration"] = seconds if current_shot && seconds
      elsif current_scene && (match = line_stripped.match(dialogue_pattern)) &&
            !match[1].match?(/camera|c[aá]mara|action|acci[oó]n|duration|duraci[oó]n/i)
        current_scene["dialogue"] << { "character" => match[1].strip.upcase, "line" => match[2].strip }
        pending_character = nil
      elsif current_scene && pending_character
        current_scene["dialogue"] << { "character" => pending_character, "line" => line_stripped }
        pending_character = nil
      elsif current_scene && line_stripped.match?(/\A[\p{Lu}][\p{Lu}\d _\-]{1,30}\z/u) &&
            !line_stripped.match?(/ACTION|ACCI[ÓO]N|CAMERA|C[ÁA]MARA|DURATION|DURACI[ÓO]N/)
        pending_character = line_stripped
      else
        if current_shot
          current_shot["description_lines"] << line_stripped.sub(/\A(?:acci[oó]n|action)\s*:\s*/i, "")
        elsif current_scene
          action_line = line_stripped.sub(/\A(?:acci[oó]n|action)\s*:\s*/i, "")
          current_scene["action"] = [current_scene["action"], action_line].reject(&:empty?).join("\n")
        end
      end
    end

    return nil if scenes.empty?
    scenes.each { |scene| scene["style_directives"] = global_style_directives.dup } if global_style_directives.any?

    # Post-process scenes to map to screenplay structure
    processed_scenes = scenes.each_with_index.map do |scene, sc_idx|
      if scene["shots"].empty?
        visual_prompt = scene["action"].presence || scene["heading"]
        scene["shots"] = [{
          "id" => "#{sc_idx + 1}.1",
          "duration" => scene["duration"] || 5,
          "beat" => "action",
          "camera" => scene["camera"] || "wide",
          "editorial_role" => "establishing",
          "story_event" => visual_prompt,
          "visual_prompt" => visual_prompt
        }]
        scene["action"] = visual_prompt
      else
        scene["shots"] = scene["shots"].each_with_index.map do |shot, sh_idx|
          desc = shot["description_lines"].join(" ").strip
          desc = shot["title"] if desc.empty?
          {
            "id" => "#{sc_idx + 1}.#{sh_idx + 1}",
            "duration" => shot["duration"] || 5,
            "beat" => "action",
            "camera" => shot["camera"].presence || scene["camera"].presence || "cinematic",
            "editorial_role" => sh_idx.zero? ? "establishing" : "action",
            "story_event" => desc,
            "visual_prompt" => desc
          }
        end
        # Populate scene action by combining shot prompts if it is empty
        scene["action"] = scene["action"].presence || scene["shots"].map { |s| s["visual_prompt"] }.join(" ")
      end
      scene
    end

    {
      "title" => "Custom Adaptation",
      "scenes" => processed_scenes,
      "source_profiles" => {
        "characters" => source_character_lines.join("\n").presence,
        "locations" => source_location_lines.join("\n").presence,
        "all" => source_profile_lines.join("\n").presence
      }.compact
    }
  end

  def self.generate_offline(selection:, prompt:, target_duration:, max_scenes:)
    parsed_custom = parse_scenes_from_prompt(prompt)
    if parsed_custom
      shape = plan_shape(target_duration: target_duration, max_scenes: max_scenes)
      custom_shape = shape.merge(scenes: parsed_custom["scenes"].size)
      return normalize_screenplay(parsed_custom, custom_shape, seed: selection.seed)
    end

    shape = plan_shape(target_duration: target_duration, max_scenes: max_scenes)
    generic_curve = %w[setup development complication decision resolution]
    beats = (0...shape[:scenes]).map do |index|
      generic_curve[((index.to_f / [shape[:scenes] - 1, 1].max) * (generic_curve.size - 1)).round]
    end

    # Extract clean title from prompt
    cleaned_prompt = prompt.to_s.strip.gsub(/[^\w\s-]/, "")
    short_title = cleaned_prompt.split[0..4].join(" ")
    title = short_title.present? ? short_title.capitalize : "Untitled short film"
    story_units = source_story_units(prompt)
    scene_sources = distribute_story_units(story_units, shape[:scenes])
    premise = story_units.join(" ")[0, 600]
    scenes = (1..shape[:scenes]).map do |i|
      beat = beats[i - 1]
      source_event = scene_sources[i - 1]
      action_desc = source_event

      {
        "id" => i,
        "heading" => "SCENE #{i} - #{beat.upcase}",
        "beat" => beat,
        "action" => action_desc,
        "objective" => "Make this source event visible without changing its meaning: #{source_event}",
        "conflict" => "Preserve the resistance or limitation stated in this source event",
        "turn" => "Complete the explicit change described by the source event",
        "outcome" => i == shape[:scenes] ? source_event : "The resulting state leads directly to the next source event",
        "dialogue" => [],
        "shots" => (1..shape[:shots_per_scene]).map do |j|
          role = if j == 1
                   "establishing"
                 elsif j == shape[:shots_per_scene]
                   "resolution"
                 else
                   "action"
                 end
          event = case role
                  when "establishing" then "Establish the exact subjects, setting and starting positions from the premise"
                  when "resolution" then "Hold on the new visible state caused by this scene"
                  else "Show one atomic action that advances this scene's objective"
                  end
          {
            "id" => "#{i}.#{j}",
            "duration" => shape[:shot_duration],
            "beat" => beat,
            "editorial_role" => role,
            "purpose" => event,
            "story_event" => event,
            "camera" => j == 1 ? "wide" : (role == "resolution" ? "close_up" : "medium"),
            "visual_prompt" => "#{event}. SOURCE-LOCKED EVENT: #{source_event}"
          }
        end,
      }
    end
    normalize_screenplay(
      {
        "title" => title,
        "story_outline" => {
          "premise" => premise,
          "structure" => "Source-order deterministic recovery",
          "resolution" => story_units.last
        },
        "scenes" => scenes
      },
      shape,
      beats: beats,
      seed: selection.seed
    )
  end

  def self.source_story_units(prompt)
    clean = prompt.to_s.gsub(/\s+/, " ").strip
    units = clean.split(/(?<=[.!?])\s+/).map(&:strip).reject(&:empty?)
    units = [clean] if units.empty? && clean.present?
    units.presence || ["Preserve the user's supplied story premise"]
  end

  def self.distribute_story_units(units, scene_count)
    count = [scene_count.to_i, 1].max
    Array.new(count) do |index|
      first = (index * units.size.to_f / count).floor
      last_exclusive = ((index + 1) * units.size.to_f / count).floor
      last_exclusive = [last_exclusive, first + 1].max
      selected = units[first...last_exclusive].to_a
      selected = [units[[first, units.size - 1].min]] if selected.empty?
      selected.compact.join(" ")
    end
  end

  # Normaliza respuestas tolerantes sin destruir decisiones explícitas. Beats,
  # cámaras y duraciones entregados por el usuario/modelo se conservan; los
  # fallbacks deterministas solo completan campos ausentes. ScreenplayPlanner
  # convierte después el resultado al contrato narrativo/editorial v3.
  def self.normalize_screenplay(parsed, shape, beats: nil, seed: nil)
    scenes = Array(parsed["scenes"]).first(shape[:scenes])
    fallback_beats = beats.presence || NarrativeBeats.assign(scenes.size)

    rng = Random.new(seed || 0)
    previous_camera = nil

    scenes.each_with_index do |scene, i|
      scene["beat"] = scene["beat"].presence || fallback_beats[i] || "development"
      scene["shots"] = Array(scene["shots"]).map do |shot|
        shot["duration"] ||= shape[:shot_duration]
        shot["mode"] ||= "t2v"
        shot["beat"] = shot["beat"].presence || scene["beat"]
        shot["camera"] = shot["camera"].presence || NarrativeBeats.camera_for(scene["beat"], previous_camera, rng)
        previous_camera    = shot["camera"]
        shot
      end
    end
    screenplay = {
      "title" => parsed["title"] || "Untitled",
      "story_outline" => parsed["story_outline"],
      "source_profiles" => parsed["source_profiles"],
      "scenes" => scenes
    }
    ScreenplayPlanner.upgrade!(
      screenplay,
      target_duration: shape[:target_duration] || scenes.sum { |scene| Array(scene["shots"]).sum { |shot| shot["duration"].to_f } },
      max_scenes: shape[:scenes],
      seed: seed
    )
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# STORYBOARDER — Stage 4: compila intención estructurada sin pérdida semántica
# ─────────────────────────────────────────────────────────────────────────────

module Storyboarder
  # Conserva la firma histórica [screenplay, result] para que callers antiguos
  # sigan funcionando. Ya no consume tokens ni permite que otro LLM resuma y
  # elimine causalidad, blocking o estados físicos.
  def self.compress!(screenplay, ledger:, config: QwenRouter::Config.default)
    [StoryboardPromptCompiler.compile!(screenplay), nil]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# CONSISTENCY ENFORCER — fix brutal final de continuidad visual (#2 y #4 del
# feedback). Se ejecuta DESPUÉS del compilador de storyboard. No es una
# sugerencia al modelo: garantiza en código que cada prompt contiene los
# contratos canónicos de las entidades realmente presentes en ese plano.
# ─────────────────────────────────────────────────────────────────────────────

module ConsistencyEnforcer
  MAX_TOTAL_PROMPT_CHARS = 2400

  # for_video: false → modo T2I: prompt rico con descripción completa del personaje
  #                    para generar la imagen base de la escena con el personaje correcto.
  # for_video: true  → modo I2V/R2V: el prompt SOLO describe la acción y la locación.
  #                    El personaje viene de la imagen referencia (asset o base frame),
  #                    NO se repite en el prompt (duplicarlo confunde al modelo).
  def self.apply!(screenplay, selection, assets = nil, for_video: false, rich_prompt: false, production_bible: nil)
    if production_bible.present?
      ScriptConsistencyValidator.reconcile!(screenplay: screenplay, production_bible: production_bible)
      StoryboardPromptCompiler.compile!(screenplay)
      ContinuityPlanner.plan!(screenplay, production_bible)
      return apply_production_contract!(screenplay, production_bible, for_video: for_video)
    end

    if for_video
      # ── Modo I2V / R2V ─────────────────────────────────────────────────────
      # El personaje ya está anclado visualmente en la imagen referencia.
      # El prompt solo debe dar la acción de la escena y la locación.
      locations = assets&.dig("locations") || []

      screenplay["scenes"].each do |scene|
        heading = scene["heading"].to_s
        loc_asset = locations.find do |l|
          loc_name = l["name"].to_s.downcase
          heading.downcase.include?(loc_name) || loc_name.include?(heading.downcase) ||
            (loc_name.split - %w[the a an of and in at on]).any? { |w| w.length > 2 && heading.downcase.include?(w) }
        end || locations.first

        loc_hint = loc_asset ? "at #{loc_asset['name']}" : "on #{selection.domain.to_s.tr('_', ' ').capitalize}"

        scene["shots"].each do |shot|
          next if ActiveRecord::Type::Boolean.new.cast(shot["locked"])
          base = strip_consistency_suffix(shot["visual_prompt"].to_s)
          # Solo acción + locación + restricciones físicas. Sin descripción del personaje.
          shot["visual_prompt"] = truncate("#{base}, #{loc_hint}, natural motion, grounded physics, consistent style")
        end
      end
      screenplay
    else
      # ── Modo T2I ────────────────────────────────────────────────────────────
      # Prompt rico: descripción completa del personaje para que la imagen base
      # lo muestre exactamente como el asset visual aprobado.
      use_assets = assets && (assets["characters"].present? || assets["locations"].present?)

      if use_assets
        characters = assets["characters"] || []
        locations  = assets["locations"]  || []

        screenplay["scenes"].each do |scene|
          heading = scene["heading"].to_s
          loc_asset = locations.find do |l|
            loc_name = l["name"].to_s.downcase
            heading.downcase.include?(loc_name) || loc_name.include?(heading.downcase) ||
              (loc_name.split - %w[the a an of and in at on]).any? { |w| w.length > 2 && heading.downcase.include?(w) }
          end

          loc_desc = if loc_asset
                       parts = []
                       parts << "lighting: #{loc_asset['lighting']}" if loc_asset["lighting"].present?
                       parts << "atmosphere: #{loc_asset['atmosphere']}" if loc_asset["atmosphere"].present?
                       desc = parts.any? ? " (#{parts.join(', ')})" : ""
                       "at #{loc_asset['name']}#{desc}"
                     elsif locations.any?
                       first_loc = locations.first
                       parts = []
                       parts << "lighting: #{first_loc['lighting']}" if first_loc["lighting"].present?
                       parts << "atmosphere: #{first_loc['atmosphere']}" if first_loc["atmosphere"].present?
                       desc = parts.any? ? " (#{parts.join(', ')})" : ""
                       "at #{first_loc['name']}#{desc}"
                     else
                       "on #{selection.domain.to_s.tr('_', ' ').capitalize}"
                     end

          scene["shots"].each do |shot|
            next if ActiveRecord::Type::Boolean.new.cast(shot["locked"])
            search_text = [
              shot["visual_prompt"],
              scene["action"],
              (scene["dialogue"] || []).map { |d| "#{d['character']} #{d['line']}" }
            ].flatten.compact.join(" ").downcase

            involved_chars = characters.select do |c|
              name = c["name"].to_s.downcase
              next true if search_text.include?(name)
              words = name.split - %w[the a an of and to in on with player character protagonist hero héroe personaje]
              next true if words.any? { |w| w.length > 2 && search_text.include?(w) }
              is_proto = (c == characters.first)
              if is_proto
                synonyms = %w[hero héroe protagonist protagonista main character he him his él su autor creador]
                next true if synonyms.any? { |syn| search_text.include?(syn) }
              end
              false
            end
            involved_chars = [characters.first] if involved_chars.empty? && characters.any?

            # Descripción completa del personaje para T2I — estilo, físico, vestuario
            char_desc = if involved_chars.any?
                          involved_chars.map do |c|
                            style = c["style"].presence || "realistic figurine render"
                            "#{c['name']}: #{c['physical_description']}, #{style}"
                          end.join(" and ")
                        else
                          "#{selection.base_story[:archetype].to_s.tr('_', ' ').capitalize}: #{selection.protagonist_bible}"
                        end

            base = strip_consistency_suffix(shot["visual_prompt"].to_s)
            shot["visual_prompt"] = truncate("#{base}, featuring #{char_desc}, #{loc_desc}")
          end
        end
      else
        # Sin assets canónicos no inventamos un protagonista u objeto desde
        # una plantilla de dominio: en modo fiel eso contaminaría historias
        # humanas, documentales o abstractas. Solo fijamos lo ya establecido.
        screenplay["scenes"].each do |scene|
          scene["shots"].each do |shot|
            next if ActiveRecord::Type::Boolean.new.cast(shot["locked"])
            base = strip_consistency_suffix(shot["visual_prompt"].to_s)
            shot["visual_prompt"] = truncate(
              "#{base} | CONTINUITY LOCK: preserve the same established subjects, wardrobe, props, scale, materials and geography; physically plausible motion"
            )
          end
        end
      end
      screenplay
    end
  end

  # Generic structured consistency path. The production bible is inferred from
  # the current project, so this works for humans, creatures, products, props,
  # vehicles and arbitrary locations without story-specific prompt fragments.
  def self.apply_production_contract!(screenplay, production_bible, for_video: false)
    scale_rules = Array(production_bible["scale_anchors"]).map { |item| "#{item['entity_id']}: #{item['rule']}" }

    screenplay["scenes"].each do |scene|
      scene["shots"].each do |shot|
        next if ActiveRecord::Type::Boolean.new.cast(shot["locked"])

        continuity = shot["continuity"] || {}
        entity_ids = Array(continuity["required_entity_ids"])
        canon = ProductionBible.prompt_contract(production_bible, entity_ids)
        physics = Array(continuity["physical_constraints"]).join("; ")
        direction = continuity["screen_direction"].presence || "preserve established axis"
        previous = continuity["continues_from"]
        base = strip_consistency_suffix(shot["visual_prompt"].to_s)
        attachment_override = attachment_override_for(base, physics)

        sections = []
        sections << "HARD CONSISTENCY — NON-NEGOTIABLE: canonical identity, body proportions, wardrobe, materials, colors, relative physical scale, attachments, spatial topology and persistent state never change unless an explicit canonical variant is declared"
        sections << "ABSOLUTE SCALE — FIRST PRIORITY: #{bounded_section(scale_rules.join('; '), 360)}" if scale_rules.present?
        sections << "ATTACHMENT OVERRIDE — FIRST PRIORITY: #{attachment_override}" if attachment_override.present?
        sections << "ACTION: #{bounded_section(base, 380)}"
        sections << "CANON LOCK: #{bounded_section(canon, 620)}" if canon.present?
        sections << "PHYSICS LOCK: #{bounded_section(physics, 250)}" if physics.present?
        sections << "CONTINUITY: #{bounded_section("begin from shot #{previous}'s final state; #{direction}", 150)}" if previous.present?
        sections << "CONTINUITY: #{bounded_section("establish the canonical state; #{direction}", 150)}" unless previous.present?
        sections << if for_video
                      "VIDEO RULE: preserve the approved keyframe/reference exactly; one continuous physically plausible action; no redesign"
                    else
                      "KEYFRAME RULE: exact approved entity designs and relative scale; neutral motion instant; no redesign"
                    end
        sections << "CINEMATIC FREEDOM: lens, framing, lighting, depth of field and camera motion are free only when every hard consistency lock remains visibly true"
        shot["visual_prompt"] = bounded_section(sections.join(" | "), MAX_TOTAL_PROMPT_CHARS)
        shot["negative_prompt"] = ProductionBible.negative_prompt(production_bible, entity_ids)
      end
    end

    screenplay
  end

  # Elimina sufijos de iteraciones anteriores del ConsistencyEnforcer
  # para que no se acumulen en renders sucesivos.
  def self.strip_consistency_suffix(text)
    base = text.strip
    base = base.split(/\s*\|\s*CANON LOCK:/i, 2).first if base.match?(/\|\s*CANON LOCK:/i)
    if base.match?(/\A(?:HARD CONSISTENCY|ABSOLUTE SCALE)\b/i) && base.match?(/(?:\A|\|)\s*ACTION:/i)
      base = base[/(?:\A|\|)\s*ACTION:\s*(.*?)(?=\s*\|\s*[A-Z][A-Z _-]+:|\z)/im, 1].to_s
    end
    base = base.sub(/\AACTION:\s*/i, "")
    base = base.sub(/\s*,\s*featuring\s+.*\z/i, "")
    base = base.sub(/\s+featuring\s+.*\z/i, "")
    base = base.sub(/,\s*natural motion.*\z/i, "")
    base = base.sub(/,\s*grounded physics.*\z/i, "")
    base = base.strip.sub(/[.\s]+\z/, "")
    base
  end

  def self.attachment_override_for(action, physics)
    fixed = physics.to_s.match?(/\b(?:fixed|attached|mounted|embedded|fastened|anchored)\b/i)
    locomotion = action.to_s.match?(/\b(?:walk(?:s|ing)?|run(?:s|ning)?|advance(?:s|d)?|moves?\s+toward|step(?:s|ping)?)\b/i)
    released = action.to_s.match?(/\b(?:detach(?:es|ed)?|remove(?:s|d)?|release(?:s|d)?|breaks?\s+free|unfasten(?:s|ed)?)\b/i)
    return unless fixed && locomotion && !released

    "The subject remains mechanically mounted at the declared anchor. Preserve visible source-defined agency through rotation around the attachment, translation only along the support axis, expressive strain and reaction; support and camera motion may reinforce the approach. Do not depict independent walking across the surface, free detachment or a scale change."
  end

  def self.truncate(text)
    return text if text.length <= MAX_TOTAL_PROMPT_CHARS
    text[0, MAX_TOTAL_PROMPT_CHARS].sub(/,\s*[^,]*\z/, "")
  end

  def self.bounded_section(value, max_chars)
    text = value.to_s.gsub(/\s+/, " ").strip
    return text if text.length <= max_chars

    text[0, max_chars].sub(/\s+\S*\z/, "").strip
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# VIDEO SYNTH — Stage 5: HappyHorse por shot, con fallback still-frame
# ─────────────────────────────────────────────────────────────────────────────

module VideoSynth
  MAX_AUTOMATIC_REPAIRS_PER_SHOT = 1

  # Devuelve [video_jobs, shot_paths, quality_report] — shot_paths siempre tiene una entrada
  # por shot (o el .mp4 real, o un still-frame de fallback) para que el
  # Editor jamás reciba una lista incompleta (SDD §9.3: "pipeline still
  # produces a complete cut").
  def self.run!(screenplay, client:, workdir:, resolution:, assets: nil, production_bible: nil,
                quality_evaluator: nil, prior_quality_report: nil, prior_video_jobs: nil,
                allow_legacy_task_recovery: false, max_concurrent: 3, auto_repair: true, &block)
    all_shots = screenplay["scenes"].flat_map { |scene| scene["shots"].map { |s| s.merge("scene_heading" => scene["heading"]) } }

    video_jobs  = []
    shot_paths  = {}

    # Resolve the correct canonical character per shot. The first character is
    # only a backwards-compatible fallback for manifests without entity IDs.
    fallback_character = assets&.dig("characters", 0).to_h
    char_asset_url = Array(
      fallback_character["stable_reference_images"].presence ||
      fallback_character["reference_images"] || fallback_character[:reference_images]
    ).find { |url| StableMedia.reference?(url) }.to_s
    stable_character = fallback_character["stable_image_url"].to_s
    char_asset_url = stable_character if char_asset_url.empty? && StableMedia.reference?(stable_character)
    char_asset_url = fallback_character["image_url"].to_s if char_asset_url.empty? &&
      !ScaleContractResolver::TECHNICAL_REFERENCE_PATTERN.match?(fallback_character["visual_prompt"].to_s)
    char_asset_url = nil unless StableMedia.reference?(char_asset_url)
    entity_index = if production_bible && defined?(ProductionBible)
                     ProductionBible.entity_index(production_bible)
                   else
                     {}
                   end

    shot_inputs = all_shots.map do |s|
        stable_base_image = s["stable_image_url"].to_s
        base_image = StableMedia.reference?(stable_base_image) ? stable_base_image : s["image_url"].to_s
        required_ids = Array(s.dig("continuity", "required_entity_ids"))
        shot_character = required_ids.filter_map { |id| entity_index[id] }.find do |entity|
          !%w[prop location].include?(entity["type"])
        end
        shot_character_ref = ProductionBible.narrative_reference_images(shot_character || {}).find do |url|
          StableMedia.reference?(url)
        end
        shot_character_ref ||= char_asset_url

        # Jerarquía de modos — CONSISTENCIA GLOBAL DE PERSONAJE PRIMERO:
        # 1. :r2v — hay asset de personaje aprobado: TODOS los shots se anclan a la
        #    MISMA imagen de referencia (wan2.7-r2v mantiene el sujeto idéntico en
        #    cada clip; el prompt aporta solo la acción/escena). Las imágenes de
        #    storyboard por shot se generan con llamadas T2I independientes y
        #    DIVERGEN entre sí — usarlas como first frame (i2v) fija un personaje
        #    distinto en cada clip, que era la causa directa de la inconsistencia
        #    de personajes entre escenas.
        # 2. :i2v — no hay asset de personaje pero el shot trae imagen base propia.
        # 3. :t2v — sin imágenes disponibles (fallback puro texto).
        strategy = s.dig("continuity", "render_strategy")
        # A shot keyframe anchors the complete composition (all characters,
        # props, scale and location). Use subject-only R2V for a single-character
        # shot where identity is more important than multi-entity composition.
        mode = if strategy == "keyframe_i2v" && StableMedia.reference?(base_image)
                 :i2v
               elsif strategy == "character_r2v" && shot_character_ref
                 :r2v
               elsif StableMedia.reference?(base_image)
                 :i2v
               elsif shot_character_ref
                 :r2v
               else
                 :t2v
               end

      editorial_duration = s["duration"]
      provider_duration = HappyHorseClient.normalize_video_duration(editorial_duration)

      {
          id:              s["id"],
          prompt:          s["visual_prompt"],
          mode:            mode,
          first_frame_url: (mode == :i2v) ? base_image : nil,
          ref_image_url:   (mode == :r2v) ? shot_character_ref : nil,
          negative_prompt: s["negative_prompt"].presence ||
            (ProductionBible.negative_prompt(production_bible, s.dig("continuity", "required_entity_ids")) if production_bible && defined?(ProductionBible)),
          render_strategy: strategy,
          duration:        provider_duration,
          editorial_duration: editorial_duration,
          provider_duration: provider_duration,
          resolution:      resolution
      }
    end

    recovered_ids = restore_prior_task_clips!(
      client: client, workdir: workdir, shot_inputs: shot_inputs,
      prior_video_jobs: prior_video_jobs,
      allow_legacy_task_recovery: allow_legacy_task_recovery
    )
    legacy_reaudit = false
    expected_evaluator_version = defined?(VideoConsistencyEvaluator::VERSION) ? VideoConsistencyEvaluator::VERSION : nil
    if quality_evaluator && recovered_ids.any? && prior_quality_report.present? &&
        expected_evaluator_version.present? && prior_quality_report["evaluator_version"] != expected_evaluator_version
      recovered_set = recovered_ids.map(&:to_s)
      recovered_paths = shot_inputs.filter_map do |input|
        next unless recovered_set.include?(input[:id].to_s)

        [input[:id], cached_clip_path(workdir, input[:id])]
      end.to_h
      prior_quality_report = quality_evaluator.call(
        screenplay: screenplay,
        shot_paths: recovered_paths,
        production_bible: production_bible
      )
      legacy_reaudit = true
    end

    prior_rows = Array(prior_quality_report&.dig("shots")).index_by { |row| row["shot_id"].to_s }
    pending_inputs = []
    reused_ids = []

    shot_inputs.each do |input|
      shot = all_shots.find { |candidate| candidate["id"].to_s == input[:id].to_s }
      path = cached_clip_path(workdir, input[:id])
      prior_row = prior_rows[input[:id].to_s]
      if reusable_prior_clip?(prior_row) && valid_cached_clip?(path, input)
        shot_paths[input[:id]] = path
        reused_ids << input[:id].to_s
        video_jobs << {
          shot_id: shot["id"], task_id: nil, status: "REUSED_APPROVED_CLIP",
          render_mode: input[:mode].to_s, render_strategy: input[:render_strategy],
          editorial_duration: input[:editorial_duration], provider_duration: input[:provider_duration]
        }
      else
        pending_inputs << input
      end
    end

    client.submit_batch(
      pending_inputs,
      max_concurrent: max_concurrent
    ) do |shot_input, result_or_error|
      shot = all_shots.find { |s| s["id"] == shot_input[:id] }
      path = cached_clip_path(workdir, shot["id"])

      if result_or_error.is_a?(HappyHorse::PollResult) && result_or_error.succeeded?
        client.download(result_or_error.video_url, to: path)
        write_clip_contract!(workdir, shot_input)
        video_jobs << {
          shot_id: shot["id"], task_id: result_or_error.task_id, status: "SUCCEEDED",
          render_mode: shot_input[:mode].to_s, render_strategy: shot_input[:render_strategy],
          editorial_duration: shot_input[:editorial_duration], provider_duration: shot_input[:provider_duration],
          clip_contract_digest: clip_contract_digest(shot_input)
        }
        shot_paths[shot["id"]] = path
      else
        client.logger.warn("shot #{shot['id']} sin vídeo — usando still-frame de fallback")
        fallback_still!(path, shot: shot, duration: shot["duration"])
        video_jobs << {
          shot_id: shot["id"], task_id: nil, status: "needs_review",
          render_mode: shot_input[:mode].to_s, render_strategy: shot_input[:render_strategy],
          editorial_duration: shot_input[:editorial_duration], provider_duration: shot_input[:provider_duration]
        }
        shot_paths[shot["id"]] = path
      end
      yield(shot_input, result_or_error) if block_given?
    end

    quality_report = { "status" => "not_measured", "reason" => "quality evaluator not configured" }
    if quality_evaluator
      quality_report = quality_evaluator.call(
        screenplay: screenplay,
        shot_paths: shot_paths,
        production_bible: production_bible
      )
      failed_ids = Array(quality_report["failed_shot_ids"]).map(&:to_s)
      report_by_id = Array(quality_report["shots"]).index_by { |row| row["shot_id"].to_s }
      repair_counts = Hash.new(0)

      failed_ids.each do |shot_id|
        next unless auto_repair
        next if repair_counts[shot_id] >= MAX_AUTOMATIC_REPAIRS_PER_SHOT
        input = shot_inputs.find { |candidate| candidate[:id].to_s == shot_id }
        next unless input

        report_row = report_by_id[shot_id].to_h
        issues = (Array(report_row["issues"]) + Array(report_row["hard_failures"])).uniq.join("; ")
        corrected = input.merge(
          prompt: "#{input[:prompt]} | VIDEO CONTINUITY CORRECTION: #{issues}; preserve the canonical keyframe/reference and physical constraints exactly"
        )
        begin
          result = client.submit_with_retries(
            prompt: corrected[:prompt],
            mode: corrected[:mode],
            first_frame_url: corrected[:first_frame_url],
            ref_image_url: corrected[:ref_image_url],
            negative_prompt: corrected[:negative_prompt],
            resolution: corrected[:resolution],
            duration: corrected[:duration]
          )
          next unless result.succeeded?

          client.download(result.video_url, to: shot_paths[shot_id])
          write_clip_contract!(workdir, input)
          repair_counts[shot_id] += 1
          video_jobs << {
            shot_id: shot_id,
            task_id: result.task_id,
            status: "SUCCEEDED_AFTER_CONSISTENCY_REPAIR",
            render_mode: corrected[:mode].to_s,
            render_strategy: corrected[:render_strategy],
            editorial_duration: corrected[:editorial_duration],
            provider_duration: corrected[:provider_duration],
            clip_contract_digest: clip_contract_digest(input)
          }
        rescue HappyHorse::Error => e
          client.logger.warn("consistency repair failed for shot #{shot_id}: #{e.message}")
        end
      end

      if failed_ids.any? && auto_repair
        quality_report = quality_evaluator.call(
          screenplay: screenplay,
          shot_paths: shot_paths,
          production_bible: production_bible
        )
        quality_report["automatic_repairs_attempted"] = failed_ids
        quality_report["automatic_repair_attempt_counts"] = repair_counts
        quality_report["automatic_repair_limit_per_shot"] = MAX_AUTOMATIC_REPAIRS_PER_SHOT
      elsif failed_ids.any?
        quality_report["automatic_repairs_attempted"] = []
        quality_report["repair_policy"] = "disabled_by_full_control"
      end
      quality_report["reused_approved_shot_ids"] = reused_ids
      quality_report["restored_provider_task_shot_ids"] = recovered_ids
      quality_report["legacy_clip_reaudit_performed"] = legacy_reaudit
      quality_report["newly_rendered_shot_ids"] = pending_inputs.map { |input| input[:id].to_s }
    end

    ordered_paths = all_shots.map { |s| shot_paths[s["id"]] }
    [video_jobs, ordered_paths, quality_report]
  end

  def self.cached_clip_path(workdir, shot_id)
    FileUtils.mkdir_p(workdir)
    File.join(workdir, "shot_#{shot_id.to_s.tr('.', '_')}.mp4")
  end

  def self.clip_contract_path(workdir, shot_id)
    File.join(workdir, "shot_#{shot_id.to_s.tr('.', '_')}.contract.json")
  end

  def self.clip_contract_digest(input)
    payload = input.slice(
      :id, :prompt, :mode, :first_frame_url, :ref_image_url, :negative_prompt,
      :render_strategy, :duration, :editorial_duration, :provider_duration, :resolution
    )
    Digest::SHA256.hexdigest(JSON.generate(payload))
  end

  def self.write_clip_contract!(workdir, input)
    File.write(
      clip_contract_path(workdir, input[:id]),
      JSON.generate(
        "contract_digest" => clip_contract_digest(input),
        "written_at" => Time.now.utc.iso8601
      )
    )
  end

  def self.valid_cached_clip?(path, input)
    return false unless File.file?(path) && File.size(path).positive?

    metadata = JSON.parse(File.read(clip_contract_path(File.dirname(path), input[:id])))
    ActiveSupport::SecurityUtils.secure_compare(
      metadata["contract_digest"].to_s,
      clip_contract_digest(input)
    )
  rescue Errno::ENOENT, JSON::ParserError, ArgumentError
    false
  end

  def self.reusable_prior_clip?(row)
    source = row.to_h
    return true if ActiveRecord::Type::Boolean.new.cast(source["pass"])
    return true if source["audit_status"] == "unavailable"

    issues = Array(source["issues"])
    issues.any? && issues.all? { |issue| issue.to_s.start_with?("video vision audit unavailable:") }
  end

  def self.restore_prior_task_clips!(client:, workdir:, shot_inputs:, prior_video_jobs:,
                                     allow_legacy_task_recovery: false)
    jobs_by_shot = Array(prior_video_jobs).reverse_each.each_with_object({}) do |job, index|
      source = job.to_h.with_indifferent_access
      index[source["shot_id"].to_s] ||= source if source["task_id"].present?
    end

    shot_inputs.filter_map do |input|
      path = cached_clip_path(workdir, input[:id])
      next input[:id].to_s if valid_cached_clip?(path, input)

      job = jobs_by_shot[input[:id].to_s]
      next unless job
      digest_matches = job["clip_contract_digest"].present? &&
        ActiveSupport::SecurityUtils.secure_compare(
          job["clip_contract_digest"].to_s,
          clip_contract_digest(input)
        )
      next unless digest_matches || allow_legacy_task_recovery

      result = client.poll_once(job["task_id"])
      next unless result.succeeded? && result.video_url.present?

      client.download(result.video_url, to: path)
      write_clip_contract!(workdir, input)
      input[:id].to_s
    rescue HappyHorse::Error, StandardError => e
      client.logger.warn("could not restore prior clip #{input[:id]} from provider task: #{e.message}")
      nil
    end
  end


  # Still-frame fallback. Production media must never contain diagnostic
  # labels; state and errors belong in the UI/manifest, not burned into frames.
  def self.fallback_still!(path, shot:, duration:)
    stable_image = shot["stable_image_url"].to_s
    image_url = StableMedia.reference?(stable_image) ? stable_image : shot["image_url"].to_s
    temp_image_path = nil
    persistent_image_path = StableMedia.public_file_path(image_url) if StableMedia.local_available?(image_url)

    if persistent_image_path
      temp_image_path = persistent_image_path
    elsif image_url.start_with?("http")
      begin
        require "open-uri"
        require "tempfile"

        ext = File.extname(URI.parse(image_url).path)
        ext = ".png" if ext.empty?

        temp_file = Tempfile.new(["fallback_still_#{shot['id']}", ext])
        temp_file.binmode

        # Download image
        URI.open(image_url, open_timeout: 10, read_timeout: 10) do |stream|
          temp_file.write(stream.read)
        end
        temp_file.close
        temp_image_path = temp_file.path
      rescue => e
        client.logger.warn("Failed to download fallback image for shot #{shot['id']}: #{e.message}") rescue nil
      end
    end

    if temp_image_path && File.exist?(temp_image_path)
      # Generate video clip from downloaded static image
      cmd = ["ffmpeg", "-y", "-loop", "1", "-i", temp_image_path, "-t", duration.to_s, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", "scale=1280:720", path]
      begin
        FfmpegRunner.run!(cmd, label: "fallback_still_image shot #{shot['id']}")
        return path
      rescue => e
        # If failed, log and let it go to colored solid background fallback
        Rails.logger.warn("Failed to generate fallback video from image for shot #{shot['id']}: #{e.message}") rescue nil
      ensure
        File.delete(temp_image_path) if temp_image_path && temp_image_path != persistent_image_path && File.exist?(temp_image_path)
      end
    end

    # Last-resort clean slate. Never burn "under review", shot IDs or any
    # technical legend into a deliverable.
    base_cmd = ["ffmpeg", "-y", "-f", "lavfi", "-i", "color=c=0x1a1a24:s=1280x720:d=#{duration}"]
    plain_cmd = base_cmd + ["-c:v", "libx264", "-pix_fmt", "yuv420p", path]
    FfmpegRunner.run!(plain_cmd, label: "fallback_still shot #{shot['id']} (clean frame)")
    path
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# EDITOR — Stage 6: montaje con ffmpeg (concat + crossfade + música/voz)
# ─────────────────────────────────────────────────────────────────────────────

module Editor
  DEFAULT_TRANSITION_DURATION = 0.5
  MAX_EDITORIAL_SLOWDOWN = 1.5

  # Grade de color único (fix brutal #6 del feedback: "cada clip tiene una
  # iluminación distinta" / "intentaría unificar todo"). HappyHorse genera
  # cada shot de forma independiente, así que sin esto el corte final se ve
  # como una sucesión de clips sueltos con contraste/saturación propios en
  # vez de una sola película. Se aplica al MISMO paso de normalización que
  # ya existía (que hasta ahora solo igualaba tamaño/fps, no color).
  UNIFIED_GRADE = "eq=contrast=1.08:brightness=0.00:saturation=0.92,curves=preset=darker".freeze

  # `beats`, si se da, es un array paralelo a shot_paths con el "beat"
  # narrativo de cada shot — se usa para variar el ritmo del montaje (fix
  # brutal #10/#11: "pocos cambios de ritmo" / "flujo bastante lineal").
  # Cortes rápidos y bruscos en tensión alta, transiciones lentas y
  # contemplativas en misterio/desenlace, en vez de un xfade uniforme.
  def self.assemble!(shot_paths:, output:, beats: nil, edl: nil, music_track: nil, voice_track: nil,
                     soundtrack_style: nil, require_audio: false,
                     transition_duration: DEFAULT_TRANSITION_DURATION)
    raise ArgumentError, "no hay clips para montar" if shot_paths.compact.empty?
    validate_edl!(edl, shot_paths) if edl
    target_durations = Array(edl&.dig("entries")).map { |entry| positive_duration(entry["source_out"]) }
    target_durations = nil if target_durations.empty? || target_durations.none?

    if shot_paths.size == 1
      graded = File.join(File.dirname(shot_paths.first), "graded_single.mp4")
      video_input = grade_single_clip(shot_paths.first, graded, target_duration: target_durations&.first)
    else
      transitions = Array(edl&.dig("entries")).map { |entry| entry["transition_out"] }
      video_input = xfade_chain(
        shot_paths,
        beats,
        transitions: transitions.presence,
        target_durations: target_durations
      )
    end

    planned_duration = edl&.dig("planned_duration").to_f
    audio_duration = planned_duration.positive? ? planned_duration : probe_duration(video_input)
    generated_music = music_track.blank? && soundtrack_style.present? && soundtrack_style.to_s != "none"
    cmd = ["ffmpeg", "-y", "-i", video_input]
    filter_complex = nil

    if music_track || generated_music || voice_track
      cmd += ["-stream_loop", "-1", "-i", music_track] if music_track
      cmd += ["-f", "lavfi", "-i", soundtrack_source(soundtrack_style, audio_duration)] if generated_music
      cmd += ["-i", voice_track] if voice_track
      filter_complex = build_audio_filter(has_music: music_track.present? || generated_music, has_voice: voice_track.present?)
    end

    if filter_complex
      cmd += ["-filter_complex", filter_complex, "-map", "0:v", "-map", "[aout]"]
    else
      cmd += ["-map", "0:v"]
      cmd += ["-map", "0:a?"]
    end

    cmd += ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest"]
    cmd += ["-t", planned_duration.to_s] if planned_duration.positive?
    cmd += ["-movflags", "+faststart", output]

    FfmpegRunner.run!(cmd, label: "montaje final")
    if require_audio && !audio_stream?(output)
      raise FfmpegRunner::Error, "Final assembly requires audio, but ffprobe found no audio stream"
    end
    output
  end

  def self.soundtrack_source(style, duration)
    frequencies = {
      "epic_orchestral" => [55.0, 82.41, 110.0],
      "cyberpunk_synths" => [48.99, 73.42, 146.83],
      "traditional_japanese" => [65.41, 98.0, 130.81],
      "ambient" => [43.65, 65.41, 87.31]
    }.fetch(style.to_s, [43.65, 65.41, 87.31])
    expression = frequencies.each_with_index.map do |frequency, index|
      amplitude = index.zero? ? 0.035 : 0.018
      "#{amplitude}*sin(2*PI*#{frequency}*t)"
    end.join("+")
    "aevalsrc=#{expression}:s=48000:d=#{[duration.to_f, 0.1].max.round(3)}"
  end

  def self.audio_stream?(path)
    output, _error, status = Open3.capture3(
      "ffprobe", "-v", "error", "-select_streams", "a",
      "-show_entries", "stream=index", "-of", "csv=p=0", path.to_s
    )
    status.success? && output.to_s.strip.present?
  end

  # Cuando hay >1 clip, primero los re-encodea a un formato común (evita el
  # típico fallo de concat por streams con distinto fps/resolución/pix_fmt
  # que HappyHorse podría devolver entre shots) y los concatena con xfade
  # encadenado. Devuelve la ruta de un mp4 intermedio.
  def self.xfade_chain(shot_paths, beats = nil, transitions: nil, target_durations: nil)
    dir = File.dirname(shot_paths.first)
    beats ||= Array.new(shot_paths.size) # nil beats → transición default en transition_for

    normalized = shot_paths.each_with_index.map do |path, i|
      raise FfmpegRunner::Error, "clip de entrada no existe: #{path}" unless File.exist?(path)
      norm_path = File.join(dir, "norm_#{i}.mp4")
      source_duration = probe_duration(path)
      target_duration = target_durations&.[](i)
      command = ["ffmpeg", "-y", "-i", path,
                 "-vf", editorial_filter(source_duration: source_duration, target_duration: target_duration)]
      command += ["-t", target_duration.to_s] if target_duration
      command += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", norm_path]
      FfmpegRunner.run!(
        command,
        label: "normalizar+grade clip #{i} (#{File.basename(path)})"
      )
      norm_path
    end

    durations = normalized.map { |p| probe_duration(p) }
    inputs_args = normalized.flat_map { |p| ["-i", p] }

    filters = normalized.each_index.map { |index| "[#{index}:v]settb=AVTB,setpts=PTS-STARTPTS[src#{index}]" }
    cumulative = durations.first
    prev_label = "[src0]"
    normalized[1..].each_with_index do |_p, idx|
      i = idx + 1
      out_label = i == normalized.size - 1 ? "[vout]" : "[v#{i}]"
      spec = transitions && transitions[idx]
      type = spec&.dig("type").to_s

      if %w[cut match_cut].include?(type)
        filters << "#{prev_label}[src#{i}]concat=n=2:v=1:a=0#{out_label}"
        cumulative += durations[i]
      else
        requested = spec&.dig("duration").to_f
        requested = NarrativeBeats.transition_for(beats[i] || beats[idx]) unless requested.positive?
        max_transition = [durations[i - 1] - 0.1, durations[i] - 0.1].min
        trans = [[requested, max_transition].min, 0.04].max
        offset = [cumulative - trans, 0].max
        filters << "#{prev_label}[src#{i}]xfade=transition=#{ffmpeg_transition(type)}:duration=#{trans.round(3)}:offset=#{offset.round(3)}#{out_label}"
        cumulative += durations[i] - trans
      end
      prev_label = out_label
    end
    filter = filters.join(";")

    combined = File.join(dir, "combined.mp4")
    FfmpegRunner.run!(
      ["ffmpeg", "-y", *inputs_args, "-filter_complex", filter, "-map", "[vout]",
       "-c:v", "libx264", "-pix_fmt", "yuv420p", combined],
      label: "xfade combine"
    )
    combined
  end

  # Aplica el mismo grade unificado al caso de un único clip (antes se
  # devolvía el clip crudo de HappyHorse sin pasar por normalización/color).
  def self.grade_single_clip(path, out_path, target_duration: nil)
    raise FfmpegRunner::Error, "clip de entrada no existe: #{path}" unless File.exist?(path)
    target_duration = positive_duration(target_duration)
    command = ["ffmpeg", "-y", "-i", path,
               "-vf", editorial_filter(source_duration: probe_duration(path), target_duration: target_duration)]
    command += ["-t", target_duration.to_s] if target_duration
    command += ["-c:v", "libx264", "-pix_fmt", "yuv420p", out_path]
    FfmpegRunner.run!(
      command,
      label: "grade single clip"
    )
    out_path
  end

  def self.probe_duration(path)
    out = `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 #{Shellwords.escape(path)}`
    out.to_f.nonzero? || 5.0
  end

  def self.editorial_filter(source_duration:, target_duration: nil)
    filters = [
      "scale=1280:720:force_original_aspect_ratio=decrease",
      "pad=1280:720:(ow-iw)/2:(oh-ih)/2",
      "fps=24",
      UNIFIED_GRADE
    ]
    target_duration = positive_duration(target_duration)
    return filters.join(",") unless target_duration && source_duration.to_f.positive?

    motion_ratio = [target_duration / source_duration.to_f, MAX_EDITORIAL_SLOWDOWN].min
    filters << "setpts=#{motion_ratio.round(6)}*PTS"
    motion_duration = source_duration.to_f * motion_ratio
    if target_duration > motion_duration + 0.01
      filters << "tpad=stop_mode=clone:stop_duration=#{(target_duration - motion_duration).round(6)}"
    end
    filters.join(",")
  end

  def self.positive_duration(value)
    number = Float(value)
    number.positive? ? number : nil
  rescue ArgumentError, TypeError
    nil
  end

  def self.ffmpeg_transition(type)
    {
      "dip_to_black" => "fadeblack",
      "wipe_left" => "wipeleft",
      "wipe_right" => "wiperight",
      "dissolve" => "dissolve",
      "fade" => "fade"
    }.fetch(type.to_s, "fade")
  end

  def self.validate_edl!(edl, shot_paths)
    entries = Array(edl["entries"])
    return if entries.empty? # Legacy manifest: caller may pass an empty edit hash.
    return if entries.size == shot_paths.size

    raise ArgumentError, "EDL has #{entries.size} clips but renderer produced #{shot_paths.size}"
  end

  # Ducking de música bajo voz — mismo modelo conceptual que
  # video_sketch's audio_track(duck_when_voice:), llevado a un filtro
  # ffmpeg directo en vez de generarse desde un manifest JSON.
  def self.build_audio_filter(has_music:, has_voice:)
    if has_music && has_voice
      "[1:a]volume=0.7[music];[2:a]asplit=2[voice_main][voice_sc];" \
      "[music][voice_sc]sidechaincompress=threshold=0.02:ratio=8:attack=5:release=200[duckedmusic];" \
      "[duckedmusic][voice_main]amix=inputs=2:duration=longest[aout]"
    elsif has_music
      "[1:a]volume=0.7[aout]"
    elsif has_voice
      "[1:a]volume=1.0[aout]"
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# MOTOR — colecciona configuración, ejecuta el pipeline, mantiene el ledger
# ─────────────────────────────────────────────────────────────────────────────

class ShowrunnerEngine
  attr_accessor :screenplay
  attr_reader :config, :selection, :token_ledger, :video_jobs, :video_consistency_report

  def initialize(config:, qwen_config: nil, happyhorse_logger: HappyHorse::StdoutLogger.new, progress_callback: nil)
    @config       = config
    @selection    = nil
    @screenplay   = nil
    @video_jobs   = []
    @video_consistency_report = { "status" => "not_measured" }
    @scene_overrides = {}
    @token_ledger = { tokens_used: 0, tokens_remaining: config[:token_budget], video_credits_used: 0, calls: [] }
    @qwen_config  = qwen_config
    @happyhorse_logger = happyhorse_logger
    @progress_callback = progress_callback
  end

  def resolve_story!(tone: nil)
    if @config[:adaptation_mode] == "faithful"
      @selection = StoryEngine.select_faithful!(
        prompt:       @config[:prompt],
        seed:         @config[:seed],
        tone:         tone,
        ledger:       @token_ledger,
        config:       @qwen_config || QwenRouter::Config.default
      )
    else
      @selection = StoryEngine.select!(
        prompt:       @config[:prompt],
        seed:         @config[:seed],
        tone:         tone,
        force_story:  @config[:force_story],
        force_domain: @config[:force_domain]
      )
    end
  end

  # Rendering an approved project must not spend tokens re-extracting a story
  # selection that is already part of its persisted production manifest.
  def restore_selection!(story)
    source = story.to_h.with_indifferent_access
    base_story_id = source["base_story_id"].presence || "faithful_prompt"
    base_story = StoryCatalog::BASE_STORIES.find { |candidate| candidate[:id].to_s == base_story_id.to_s }
    base_story ||= {
      id: base_story_id,
      archetype: :faithful_protagonist,
      genes: Array(source["preserved_genes"]).map(&:to_sym).presence || [:custom_prompt]
    }

    @selection = StoryEngine::Selection.new(
      base_story: base_story,
      domain: (source["domain"].presence || "unspecified_setting").to_s.to_sym,
      tone: (source["tone"].presence || StoryEngine.infer_tone_offline(@config[:prompt])).to_s.to_sym,
      seed: @config[:seed] || Digest::SHA256.hexdigest(@config[:prompt].to_s).to_i(16) % 1_000_000,
      protagonist_bible: source["protagonist_bible"].presence || "the main character",
      cargo_bible: source["cargo_bible"].presence || "the central story object"
    )
    self
  end

  def apply_overrides(max_scenes: nil, shot_duration: nil, voice_track: nil, music_track: nil,
                      soundtrack_style: nil, audio_required: nil)
    @scene_overrides[:max_scenes]    = max_scenes    if max_scenes
    @scene_overrides[:shot_duration] = shot_duration if shot_duration
    @scene_overrides[:voice_track]   = voice_track   if voice_track
    @scene_overrides[:music_track]   = music_track   if music_track
    @scene_overrides[:soundtrack_style] = soundtrack_style if soundtrack_style
    @scene_overrides[:audio_required] = audio_required unless audio_required.nil?
  end

  # ── Fases separadas (plan y render) ──────────────────────────────────────────

  def plan!(verbose: false)
    dry = @config[:dry_run]

    resolve_story! unless @selection
    unless @config[:force_story]
      begin
        tone = StoryEngine.classify_tone!(@config[:prompt], ledger: @token_ledger, config: qwen_config)
        resolve_story!(tone: tone) if tone != @selection.tone
      rescue StandardError => e
        log(verbose, "⚠ Tone classification failed: #{e.message} — using offline inference")
      end
    end
    log(verbose, "Story/domain: #{@selection.base_story[:id]} -> #{@selection.domain} (tone: #{@selection.tone})")

    @screenplay =
      begin
        screenplay, _r = Screenwriter.generate!(
          selection: @selection, prompt: @config[:prompt],
          target_duration: @config[:target_duration], max_scenes: @scene_overrides[:max_scenes],
          ledger: @token_ledger, config: qwen_config, adaptation_mode: @config[:adaptation_mode]
        )
        screenplay, = Storyboarder.compress!(screenplay, ledger: @token_ledger, config: qwen_config)
        screenplay
      rescue StandardError => e
        log(verbose, "⚠ Qwen failed/out of budget (#{e.class}: #{e.message}) — using offline backup screenplay")
        Screenwriter.generate_offline(selection: @selection, prompt: @config[:prompt],
                                       target_duration: @config[:target_duration],
                                       max_scenes: @scene_overrides[:max_scenes])
      end

    structured_prompt = Screenwriter.parse_scenes_from_prompt(@config[:prompt]).present?
    @screenplay = ScreenplayPlanner.upgrade!(
      @screenplay,
      target_duration: @config[:target_duration],
      max_scenes: structured_prompt ? nil : @scene_overrides[:max_scenes],
      seed: @config[:seed]
    )
    @screenplay, = Storyboarder.compress!(@screenplay, ledger: @token_ledger, config: qwen_config)
    screenplay_quality = ScreenplayEvaluator.evaluate(@screenplay, target_duration: @config[:target_duration])
    raise "Screenplay preflight rejected #{screenplay_quality['critical_count']} structural issue(s)" unless screenplay_quality["ready_for_storyboard"]

    # Fix brutal de continuidad (SIEMPRE, dry-run u online): sin importar
    # qué haya sobrevivido a la generación/compresión, cada shot termina con
    # los mismos rasgos fijos de protagonista y carga.
    is_rich = structured_prompt || @config[:prompt].to_s.strip.length > 800
    @screenplay = ConsistencyEnforcer.apply!(@screenplay, @selection, rich_prompt: is_rich)

    n_shots = @screenplay["scenes"].sum { |s| s["shots"].size }
    log(verbose, "Screenplay: \"#{@screenplay['title']}\" — #{@screenplay['scenes'].size} scenes / #{n_shots} shots")
    self
  end

  def render!(verbose: false, workdir: nil, assets: nil, production_bible: nil, quality_evaluator: nil,
              prior_video_quality_report: nil, prior_video_jobs: nil,
              allow_legacy_task_recovery: false, allow_visual_qa_override: false, auto_repair: true)
    workdir ||= Dir.mktmpdir("showrunner_")
    dry = @config[:dry_run]

    raise "The screenplay must be planned and generated before rendering" unless @screenplay

    n_shots = @screenplay["scenes"].sum { |s| s["shots"].size }
    log(verbose, "Video: rendering #{n_shots} shots")

    shot_paths =
      if dry
        @screenplay["scenes"].flat_map do |scene|
          scene["shots"].map do |s|
            path = File.join(workdir, "shot_#{s['id'].tr('.', '_')}.mp4")
            VideoSynth.fallback_still!(path, shot: s, duration: s["duration"])
          end
        end
      else
        client = HappyHorseClient.new(config: happyhorse_config, logger: @happyhorse_logger)
        @video_jobs, paths, @video_consistency_report = VideoSynth.run!(
          @screenplay, client: client, workdir: workdir,
          resolution: @config[:resolution], assets: assets, production_bible: production_bible,
          quality_evaluator: quality_evaluator,
          prior_quality_report: prior_video_quality_report,
          prior_video_jobs: prior_video_jobs,
          allow_legacy_task_recovery: allow_legacy_task_recovery,
          auto_repair: auto_repair
        ) do |shot_input, result_or_error|
          if result_or_error.is_a?(HappyHorse::PollResult) && result_or_error.succeeded?
            log(verbose, "Render completed for Shot #{shot_input[:id]}")
          else
            reason =
              if result_or_error.respond_to?(:message)
                result_or_error.message
              elsif result_or_error.respond_to?(:error_message)
                result_or_error.error_message
              else
                "provider did not return a video"
              end
            log(verbose, "Render failed for Shot #{shot_input[:id]}; using continuity fallback: #{reason}")
          end
        end
        paths
      end
    log(verbose, "Video: #{shot_paths.size} clips (#{@video_jobs.count { |j| j[:status] == 'needs_review' }} in fallback)")

    music_track = @scene_overrides[:music_track]
    voice_track = @scene_overrides[:voice_track]

    log(verbose, "Editing: merging and applying transitions")
    beats = @screenplay["scenes"].flat_map { |scene| scene["shots"].map { |s| s["beat"] } }
    Editor.assemble!(
      shot_paths: shot_paths, output: @config[:output], beats: beats,
      edl: @screenplay["edit_decision_list"],
      music_track: music_track, voice_track: voice_track,
      soundtrack_style: @scene_overrides[:soundtrack_style],
      require_audio: @scene_overrides[:audio_required] == true
    )
    log(verbose, "Finalizing: saving files")
    write_ledger_sidecar!

    # Always assemble and checkpoint a complete cut before enforcing the final
    # video gate. A strict failure can then be explicitly accepted without
    # paying to render every clip again. An authorization supplied for this
    # exact render is still audited and recorded; it only changes block vs warn.
    strict_consistency = ENV.fetch("CONSISTENCY_STRICT", "true") != "false"
    enforce_video_consistency_gate!(
      dry: dry,
      quality_evaluator_present: quality_evaluator.present?,
      strict_consistency: strict_consistency,
      allow_visual_qa_override: allow_visual_qa_override,
      verbose: verbose
    )
    self
  ensure
    FileUtils.remove_entry(workdir) if workdir && Dir.exist?(workdir) && !@config[:keep_workdir]
  end

  # ── Pipeline completo ────────────────────────────────────────────────────

  def run!(verbose: false, workdir: nil)
    plan!(verbose: verbose)
    render!(verbose: verbose, workdir: workdir)
    self
  end

  def to_manifest
    resolve_story! unless @selection
    {
      version: "3.0",
      request: {
        prompt: @config[:prompt], target_duration: @config[:target_duration],
        resolution: @config[:resolution], token_budget: @config[:token_budget],
        video_model: @config[:video_model].to_s.tr("_", "-"), seed: @selection.seed,
      },
      story: {
        base_story_id:      @selection.base_story[:id],
        domain:             @selection.domain.to_s,
        preserved_genes:    @selection.base_story[:genes],
        tone:               @selection.tone.to_s,
        # These descriptors are audit inputs, not creative overrides. Keeping
        # them in faithful mode makes source-to-asset drift observable.
        protagonist_bible:  @selection.protagonist_bible,
        cargo_bible:        @selection.cargo_bible
      },
      scene_overrides: @scene_overrides,
      screenplay: @screenplay,
      screenplay_quality_report: (@screenplay && ScreenplayEvaluator.evaluate(@screenplay, target_duration: @config[:target_duration])),
      edit_decision_list: @screenplay&.dig("edit_decision_list"),
      video_jobs: @video_jobs,
      video_consistency_report: @video_consistency_report,
      edit: {
        transitions: @screenplay&.dig("edit_decision_list", "entries")&.map { |entry| entry.dig("transition_out", "type") }&.uniq || [],
        edl_version: @screenplay&.dig("edit_decision_list", "version"),
        planned_duration: @screenplay&.dig("edit_decision_list", "planned_duration"),
        music_track: @scene_overrides[:music_track],
        soundtrack_style: @scene_overrides[:soundtrack_style],
        audio_required: @scene_overrides[:audio_required],
        audio_present: (@config[:output].present? && File.file?(@config[:output]) ? Editor.audio_stream?(@config[:output]) : false),
        voice_track: @scene_overrides[:voice_track], captions: false,
        captions_reason: "per-shot caption timing is not configured"
      },
      budget_ledger: @token_ledger,
    }
  end

  private

  def qwen_config       = @qwen_config       ||= QwenRouter::Config.default
  def happyhorse_config = @happyhorse_config ||= HappyHorse::Config.default

  def log(verbose, msg)
    puts("  ▶ #{msg}") if verbose
    @progress_callback&.call(msg)
  end

  def enforce_video_consistency_gate!(dry:, quality_evaluator_present:, strict_consistency:,
                                      allow_visual_qa_override:, verbose: false)
    failed_video_shots = Array(@video_consistency_report["failed_shot_ids"])
    unavailable_video_shots = Array(@video_consistency_report["audit_unavailable_shot_ids"])
    repairs_attempted = Array(@video_consistency_report["automatic_repairs_attempted"])
    gate_error = if !dry && quality_evaluator_present && strict_consistency && @video_consistency_report["status"] != "measured"
                   detail = unavailable_video_shots.any? ? " for shots #{unavailable_video_shots.join(', ')}" : ""
                   "Video consistency gate was unavailable#{detail}: #{@video_consistency_report['reason']}"
                 elsif strict_consistency && @video_consistency_report["status"] == "measured" && failed_video_shots.any?
                   if repairs_attempted.any?
                     "Video consistency gate rejected shots after automatic repair: #{failed_video_shots.join(', ')}"
                   elsif @video_consistency_report["repair_policy"] == "disabled_by_full_control"
                     "Video consistency gate rejected shots in Full Control; automatic clip repair was not run: #{failed_video_shots.join(', ')}"
                   else
                     "Video consistency gate rejected shots: #{failed_video_shots.join(', ')}"
                   end
                 end
    return unless gate_error

    if allow_visual_qa_override
      @video_consistency_report["override_applied"] = true
      @video_consistency_report["override_scope"] = "current_final_cut"
      @video_consistency_report["warnings"] = Array(@video_consistency_report["warnings"]) + [gate_error]
      log(verbose, "Final video visual risk explicitly accepted: #{gate_error}")
    else
      raise gate_error
    end
  end

  def write_ledger_sidecar!
    path = "#{@config[:output]}.ledger.json"
    File.write(
      path,
      JSON.pretty_generate(
        budget_ledger: @token_ledger,
        video_jobs: @video_jobs,
        edit_decision_list: @screenplay&.dig("edit_decision_list")
      )
    )
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# BUILDER — superficie pública del DSL
# ─────────────────────────────────────────────────────────────────────────────

module Showrunner
  VERSION = "3.0.0"

  def self.produce(prompt:, output: "drama_#{SecureRandom.uuid}.mp4",
                    target_duration: 75, resolution: "720P",
                    token_budget: 18_000, video_model: :happyhorse_1_1,
                    quality: "high", dry_run: false, &block)
    prompt = ShowrunnerValidation.prompt!(prompt)
    ShowrunnerValidation.resolution!(resolution)
    ShowrunnerValidation.token_budget!(token_budget)
    ShowrunnerValidation.video_model!(video_model)

    config = {
      prompt: prompt, output: File.expand_path(output),
      target_duration: target_duration.to_i, resolution: resolution.to_s,
      token_budget: token_budget.to_i, video_model: video_model.to_sym,
      quality: quality.to_s, dry_run: dry_run, seed: nil,
      force_story: nil, force_domain: nil, keep_workdir: false,
      adaptation_mode: "faithful",
    }

    engine  = ShowrunnerEngine.new(config: config)
    builder = Builder.new(engine: engine, config: config)
    builder.instance_eval(&block) if block

    BuildResult.new(engine: engine, config: config)
  end

  class Builder
    def initialize(engine:, config:)
      @engine = engine
      @config = config
    end

    def seed(value)          = (@config[:seed] = value.to_i; self)
    def force_story(id)      = (@config[:force_story] = id.to_s; self)
    def force_domain(key)    = (@config[:force_domain] = key.to_sym; self)
    def max_scenes(n)        = (@engine.apply_overrides(max_scenes: n.to_i); self)
    def shot_duration(secs)  = (@engine.apply_overrides(shot_duration: secs.to_f); self)
    def voice_track(path)    = (@engine.apply_overrides(voice_track: File.expand_path(path)); self)
    def music_track(path)    = (@engine.apply_overrides(music_track: File.expand_path(path)); self)
    def keep_workdir!        = (@config[:keep_workdir] = true; self)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# BUILD RESULT
# ─────────────────────────────────────────────────────────────────────────────

class ShowrunnerBuildResult
  def initialize(engine:, config:)
    @engine = engine
    @config = config
  end

  def manifest = @engine.to_manifest

  def info
    m = manifest
    puts "┌─ AI Showrunner v#{Showrunner::VERSION} #{'(dry-run)' if @config[:dry_run]} ─────────────"
    puts "│ Prompt      : #{@config[:prompt][0, 60]}#{'…' if @config[:prompt].length > 60}"
    puts "│ Duration    : #{@config[:target_duration]}s  ·  Resolution: #{@config[:resolution]}"
    puts "│ Token budget: #{@config[:token_budget]}"
    puts "│ Seed        : #{m[:request][:seed]}  (reproducible)"
    puts "│ Output      : #{@config[:output]}"
    puts "└──────────────────────────────────────────────────────────────────"
    self
  end

  def dry_run
    puts JSON.pretty_generate(manifest)
    self
  end

  def preview!(output: "showrunner_preview.html")
    File.write(output, "<pre>#{JSON.pretty_generate(manifest).gsub('<', '&lt;')}</pre>")
    puts "✓  Preview: #{output}"
    output
  end

  # Ejecuta el pipeline completo EN RUBY (sin subprocess a python).
  def render!(verbose: false)
    puts "\n▶  AI Showrunner — running pipeline#{' (dry-run, offline)' if @config[:dry_run]}"
    @engine.run!(verbose: verbose)
    puts "✓  Pipeline completed: #{@config[:output]}"
    puts "   Token ledger      : #{@config[:output]}.ledger.json"
    true
  rescue StandardError => e
    warn "✗  Pipeline failed: #{e.class} — #{e.message}"
    warn e.backtrace.first(6).join("\n") if verbose
    false
  end
end

BuildResult = ShowrunnerBuildResult
Showrunner.const_set(:BuildResult, ShowrunnerBuildResult) unless Showrunner.const_defined?(:BuildResult)

# ─────────────────────────────────────────────────────────────────────────────
# USO CLI
# ─────────────────────────────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  require "optparse"

  options = { duration: 75, resolution: "720P", token_budget: 18_000, seed: nil, render: false, dry_run: false }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby showrunner.rb PROMPT [options]"
    opts.on("--duration N", Integer, "Target duration in seconds (default 75)") { |v| options[:duration] = v }
    opts.on("--resolution RES", "480P|720P|1080P (default 720P)")                 { |v| options[:resolution] = v }
    opts.on("--token-budget N", Integer, "Token budget (default 18000)")          { |v| options[:token_budget] = v }
    opts.on("--seed N", Integer, "Fix the story/domain selection")                { |v| options[:seed] = v }
    opts.on("--render", "Run the complete pipeline (requires network + ffmpeg)")  { options[:render] = true }
    opts.on("--dry-run", "Run the complete pipeline offline with local data")    { options[:dry_run] = true }
  end
  parser.parse!

  prompt = ARGV.join(" ").strip
  if prompt.empty?
    puts parser.banner
    exit 1
  end

  result = Showrunner.produce(
    prompt: prompt, target_duration: options[:duration], resolution: options[:resolution],
    token_budget: options[:token_budget], dry_run: options[:dry_run]
  ) { seed(options[:seed]) if options[:seed] }

  result.info

  if options[:render] || options[:dry_run]
    result.render!(verbose: true)
  else
    result.preview!
    puts "\n💡  Run without network or token usage: --dry-run"
    puts "💡  Run the complete pipeline:          --render"
  end
end
