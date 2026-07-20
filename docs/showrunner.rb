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
#   · Clasificación de tono, guion y compresión de storyboard llaman a
#     QwenRouter de verdad, con presupuesto de tokens aplicado ANTES de cada
#     llamada (no solo registrado después).
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
require "tempfile"
require "securerandom"
require "fileutils"
require "shellwords"
require "open3"

require_relative "qwen_router"
require_relative "happy_horse_client"

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
    File.readlines(path).each do |line|
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
      raise Error, "ffmpeg (#{label}) falló (código #{status.exitstatus}):\n#{stderr.lines.last(20).join}"
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
    raise ArgumentError, "resolution inválida: #{value.inspect} (usa #{VALID_RESOLUTIONS.join(', ')})" unless VALID_RESOLUTIONS.include?(v)
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
    raise ArgumentError, "video_model inválido: #{value.inspect}" unless VALID_VIDEO_MODELS.include?(v)
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
# SCREENWRITER — Stage 3 (SDD §6): un único qwen call por todas las escenas
# ─────────────────────────────────────────────────────────────────────────────

module Screenwriter
  DEFAULT_SHOT_DURATION = 5

  # Reparte target_duration en (scenes × shots) sin desbordar max_scenes.
  def self.plan_shape(target_duration:, shot_duration: DEFAULT_SHOT_DURATION, max_scenes: nil)
    total_shots = [(target_duration.to_f / shot_duration).ceil, 1].max
    scenes      = [(total_shots / 2.0).ceil, 1].max
    scenes      = [scenes, max_scenes].min if max_scenes
    shots_per_scene = [(total_shots.to_f / scenes).ceil, 1].max
    { scenes: scenes, shots_per_scene: shots_per_scene, shot_duration: shot_duration }
  end

  def self.generate!(selection:, prompt:, target_duration:, max_scenes:, ledger:, config: QwenRouter::Config.default)
    shape = plan_shape(target_duration: target_duration, max_scenes: max_scenes)
    beats = NarrativeBeats.assign(shape[:scenes])

    system = <<~SYS
      Eres el guionista de un drama corto. Escribes ÚNICAMENTE en JSON válido,
      sin explicación ni markdown. Esquema exacto:
      {
        "title": string,
        "scenes": [
          { "id": int, "heading": string, "action": string, "beat": string,
            "dialogue": [ {"character": string, "line": string} ],
            "shots": [ {"id": string, "duration": int, "camera": string,
                        "visual_prompt": string} ] }
        ]
      }
      Debes producir exactamente #{shape[:scenes]} escenas, cada una con
      #{shape[:shots_per_scene]} shots de #{shape[:shot_duration]}s.

      CURVA EMOCIONAL OBLIGATORIA — la escena N debe tener "beat" =
      "#{beats.each_with_index.map { |b, i| "#{b}" }.join('", escena ')}"
      en orden: #{beats.map.with_index { |b, i| "escena #{i + 1}=#{b}" }.join(', ')}.
      Reglas de contenido por beat (no te saltes ninguna):
        · mystery: insinúa sin revelar qué es la carga.
        · curiosity/escalation: el protagonista investiga, sube la tensión.
        · danger: aparece una amenaza externa concreta (facción, rival, entorno).
        · climax: el protagonista toma una decisión irreversible.
        · revelation: ÚNICA escena donde se muestra qué es la carga realmente.
        · aftermath: consecuencia emocional de la decisión, sin nueva información.
      No reproduzcas texto con copyright — solo estructura y prosa original.
    SYS

    user = <<~USR
      Prompt del usuario: #{prompt}
      Dominio destino: #{selection.domain}
      Tono: #{selection.tone}
      Arquetipo protagonista: #{selection.base_story[:archetype]}
      Genes narrativos a preservar: #{selection.base_story[:genes].join(', ')}
      Descriptor fijo de protagonista (mantenlo coherente en cada action/dialogue): #{selection.protagonist_bible}
      Descriptor fijo de la carga (debe reaparecer en casi todas las escenas): #{selection.cargo_bible}
    USR

    parsed, result = QwenRouter.call_json(
      system: system, user: user, stage: :scriptwrite,
      max_tokens: 1400, ledger: ledger, config: config
    )
    unless parsed.is_a?(Hash) && parsed["scenes"]
      raise QwenRouter::MalformedResponse, "guion sin la forma esperada (falta \"scenes\"): #{parsed.inspect[0, 200]}"
    end
    [normalize_screenplay(parsed, shape, beats: beats, seed: selection.seed), result]
  end

  # Camino offline determinista — usado en dry_run y como fallback si
  # QwenRouter agota reintentos: garantiza que el pipeline SIEMPRE produce
  # un screenplay con la forma correcta, aunque sea genérico.
  BEAT_ACTION_TEMPLATES = {
    "mystery"    => "recibe una carga que %{cargo} sin saber aún qué contiene.",
    "curiosity"  => "examina la carga de cerca; algo en su interior no encaja.",
    "escalation" => "no logra sacarse la carga de la cabeza — algo ahí dentro reacciona a su presencia.",
    "danger"     => "es interceptado por quienes también quieren la carga.",
    "climax"     => "debe decidir, sin vuelta atrás, qué hacer con lo que lleva.",
    "revelation" => "descubre finalmente qué — o quién — hay dentro de la carga.",
    "aftermath"  => "asume las consecuencias de su decisión.",
  }.freeze

  def self.generate_offline(selection:, prompt:, target_duration:, max_scenes:)
    shape = plan_shape(target_duration: target_duration, max_scenes: max_scenes)
    beats = NarrativeBeats.assign(shape[:scenes])
    archetype_label = selection.base_story[:archetype].to_s.tr("_", " ").capitalize

    scenes = (1..shape[:scenes]).map do |i|
      beat = beats[i - 1]
      action_tpl = BEAT_ACTION_TEMPLATES.fetch(beat, "avanza en su travesía con la carga.")
      {
        "id" => i,
        "heading" => "ESCENA #{i} — #{selection.domain.to_s.upcase.tr('_', ' ')} (#{beat.upcase})",
        "beat" => beat,
        "action" => "#{archetype_label} #{format(action_tpl, cargo: selection.cargo_bible)}",
        "dialogue" => [{ "character" => "PROTAGONISTA", "line" => "No hay vuelta atrás." }],
        "shots" => (1..shape[:shots_per_scene]).map do |j|
          {
            "id" => "#{i}.#{j}",
            "duration" => shape[:shot_duration],
            "beat" => beat,
            "visual_prompt" => "#{selection.domain} #{beat} moment, #{selection.tone} tone, cinematic lighting",
          }
        end,
      }
    end
    normalize_screenplay({ "title" => prompt[0, 60], "scenes" => scenes }, shape, beats: beats, seed: selection.seed)
  end

  # `beats`/`seed` son opcionales para no romper llamadas externas viejas,
  # pero SIEMPRE que estén disponibles se usan para: (a) fijar el "beat" de
  # cada escena/shot (ignorando lo que el LLM haya puesto, ya que su
  # cumplimiento de instrucciones estructurales no es fiable shot a shot), y
  # (b) reasignar la cámara determinísticamente vía NarrativeBeats.camera_for
  # para garantizar variedad real (nunca dos planos iguales seguidos), en vez
  # de confiar en que el modelo varíe la cámara por su cuenta.
  def self.normalize_screenplay(parsed, shape, beats: nil, seed: nil)
    scenes = Array(parsed["scenes"]).first(shape[:scenes])
    beats ||= scenes.map { |s| s["beat"] }.compact
    beats = NarrativeBeats.assign(scenes.size) if beats.size != scenes.size

    rng = Random.new(seed || 0)
    previous_camera = nil

    scenes.each_with_index do |scene, i|
      scene["beat"] = beats[i]
      scene["shots"] = Array(scene["shots"]).map do |shot|
        shot["duration"] ||= shape[:shot_duration]
        shot["mode"]     ||= "t2v" # sin pipeline de imagen-referencia (roadmap SDD semana 3)
        shot["beat"]       = beats[i]
        shot["camera"]     = NarrativeBeats.camera_for(beats[i], previous_camera, rng)
        previous_camera    = shot["camera"]
        shot
      end
    end
    { "title" => parsed["title"] || "Sin título", "scenes" => scenes }
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# STORYBOARDER — Stage 4: comprime visual_prompt a ≤40 tokens, EN LOTE
# ─────────────────────────────────────────────────────────────────────────────

module Storyboarder
  MAX_PROMPT_TOKENS = 40

  # Una única llamada para todos los shots (SDD §10: "batch, don't loop").
  def self.compress!(screenplay, ledger:, config: QwenRouter::Config.default)
    shots = screenplay["scenes"].flat_map { |s| s["shots"] }
    return screenplay if shots.empty?

    system = <<~SYS
      Comprimes prompts visuales para generación de vídeo. Para cada shot,
      produce un visual_prompt de máximo #{MAX_PROMPT_TOKENS} tokens, denso
      en detalles visuales (composición, iluminación, movimiento de cámara),
      sin diálogo ni texto en pantalla. NO elimines los descriptores fijos de
      apariencia de personaje/objeto que ya vengan en el texto de entrada
      (edad, cicatrices, ropa, material/runas de la carga) — son continuidad
      visual obligatoria, no relleno. Ajusta la iluminación/intensidad al
      "beat" indicado (mystery=sombras/insinuación, danger/climax=contraste
      duro, aftermath=luz plana y fría). Responde SOLO JSON:
      {"shots": [{"id": string, "visual_prompt": string}]}
    SYS
    user = JSON.generate(shots.map { |s| { id: s["id"], action: s["visual_prompt"], camera: s["camera"], beat: s["beat"] } })

    parsed, result = QwenRouter.call_json(
      system: system, user: user, stage: :storyboard,
      max_tokens: [shots.size * MAX_PROMPT_TOKENS, 200].max, ledger: ledger, config: config
    )

    # Tolerante a la forma: el modelo debería devolver {"shots": [...]},
    # pero si QwenRouter tuvo que recuperar varios objetos JSON sueltos
    # (NDJSON-like) devuelve directamente un Array — lo aceptamos igual.
    compressed_list =
      case parsed
      when Hash  then Array(parsed["shots"])
      when Array then parsed
      else []
      end
    compressed_by_id = compressed_list.each_with_object({}) do |s, h|
      h[s["id"]] = s["visual_prompt"] if s.is_a?(Hash) && s["id"]
    end

    screenplay["scenes"].each do |scene|
      scene["shots"].each { |shot| shot["visual_prompt"] = compressed_by_id[shot["id"]] || shot["visual_prompt"] }
    end
    [screenplay, result]
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# CONSISTENCY ENFORCER — fix brutal final de continuidad visual (#2 y #4 del
# feedback). Se ejecuta DESPUÉS de Storyboarder.compress!, es decir después
# del paso donde más se pierde continuidad (la compresión reescribe todo el
# texto). No es una sugerencia al modelo: es una garantía en código de que
# cada visual_prompt que llega a HappyHorse contiene, LITERALMENTE, los
# mismos rasgos de protagonista y carga en todos los shots del corto.
# ─────────────────────────────────────────────────────────────────────────────

module ConsistencyEnforcer
  # ~4 chars/token, dejando margen bajo el límite de Storyboarder::MAX_PROMPT_TOKENS
  # para que al truncar no le comamos parte de los descriptores fijos.
  MAX_TOTAL_PROMPT_CHARS = 220

  def self.apply!(screenplay, selection)
    fixed = [selection.protagonist_bible, selection.cargo_bible].compact.join(", ")

    screenplay["scenes"].each do |scene|
      scene["shots"].each do |shot|
        base = shot["visual_prompt"].to_s.strip.sub(/[.\s]+\z/, "")
        shot["visual_prompt"] = truncate("#{base}, #{fixed}")
      end
    end
    screenplay
  end

  def self.truncate(text)
    return text if text.length <= MAX_TOTAL_PROMPT_CHARS
    text[0, MAX_TOTAL_PROMPT_CHARS].sub(/,\s*[^,]*\z/, "")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# VIDEO SYNTH — Stage 5: HappyHorse por shot, con fallback still-frame
# ─────────────────────────────────────────────────────────────────────────────

module VideoSynth
  # Devuelve [video_jobs, shot_paths] — shot_paths siempre tiene una entrada
  # por shot (o el .mp4 real, o un still-frame de fallback) para que el
  # Editor jamás reciba una lista incompleta (SDD §9.3: "pipeline still
  # produces a complete cut").
  def self.run!(screenplay, client:, workdir:, resolution:, max_concurrent: 3)
    all_shots = screenplay["scenes"].flat_map { |scene| scene["shots"].map { |s| s.merge("scene_heading" => scene["heading"]) } }

    video_jobs  = []
    shot_paths  = {}

    client.submit_batch(
      all_shots.map { |s| { id: s["id"], prompt: s["visual_prompt"], mode: s["mode"], duration: s["duration"], resolution: resolution } },
      max_concurrent: max_concurrent
    ) do |shot_input, result_or_error|
      shot = all_shots.find { |s| s["id"] == shot_input[:id] }
      path = File.join(workdir, "shot_#{shot['id'].to_s.tr('.', '_')}.mp4")

      if result_or_error.is_a?(HappyHorse::PollResult) && result_or_error.succeeded?
        client.download(result_or_error.video_url, to: path)
        video_jobs << { shot_id: shot["id"], task_id: result_or_error.task_id, status: "SUCCEEDED" }
        shot_paths[shot["id"]] = path
      else
        client.logger.warn("shot #{shot['id']} sin vídeo — usando still-frame de fallback")
        fallback_still!(path, shot: shot, duration: shot["duration"])
        video_jobs << { shot_id: shot["id"], task_id: nil, status: "needs_review" }
        shot_paths[shot["id"]] = path
      end
    end

    ordered_paths = all_shots.map { |s| shot_paths[s["id"]] }
    [video_jobs, ordered_paths]
  end

  # Still-frame de fallback vía ffmpeg lavfi — así el corte SIEMPRE se
  # completa aunque HappyHorse falle en algún shot (SDD §9.3). Nunca deja
  # que un problema de fuentes/filtros tumbe el pipeline: si drawtext no
  # existe en este build de ffmpeg, o si el intento con texto falla por
  # cualquier otro motivo, se reintenta sin texto (clip de color liso).
  def self.fallback_still!(path, shot:, duration:)
    label = "ESCENA #{shot['id']} — EN REVISION".gsub("'", "").gsub(":", "")
    base_cmd = ["ffmpeg", "-y", "-f", "lavfi", "-i", "color=c=0x101018:s=1280x720:d=#{duration}"]
    plain_cmd = base_cmd + ["-c:v", "libx264", "-pix_fmt", "yuv420p", path]

    if FfmpegRunner.drawtext_available?
      font = FfmpegRunner.system_font
      draw = "drawtext=#{"fontfile=#{font}:" if font}text='#{label}':fontcolor=white:fontsize=36:x=(w-text_w)/2:y=(h-text_h)/2"
      begin
        FfmpegRunner.run!(base_cmd + ["-vf", draw, "-c:v", "libx264", "-pix_fmt", "yuv420p", path],
                           label: "fallback_still shot #{shot['id']}")
        return path
      rescue FfmpegRunner::Error
        # Filtro existe pero falló igual (fuente rota, locale, lo que sea) —
        # degradamos a clip de color liso en vez de tumbar el pipeline.
      end
    end

    FfmpegRunner.run!(plain_cmd, label: "fallback_still shot #{shot['id']} (sin texto)")
    path
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# EDITOR — Stage 6: montaje con ffmpeg (concat + crossfade + música/voz)
# ─────────────────────────────────────────────────────────────────────────────

module Editor
  DEFAULT_TRANSITION_DURATION = 0.5

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
  def self.assemble!(shot_paths:, output:, beats: nil, music_track: nil, voice_track: nil, transition_duration: DEFAULT_TRANSITION_DURATION)
    raise ArgumentError, "no hay clips para montar" if shot_paths.compact.empty?

    if shot_paths.size == 1
      graded = File.join(File.dirname(shot_paths.first), "graded_single.mp4")
      video_input = grade_single_clip(shot_paths.first, graded)
    else
      video_input = xfade_chain(shot_paths, beats)
    end

    cmd = ["ffmpeg", "-y", "-i", video_input]
    filter_complex = nil

    if music_track || voice_track
      cmd += ["-i", music_track] if music_track
      cmd += ["-i", voice_track] if voice_track
      filter_complex = build_audio_filter(has_music: !music_track.nil?, has_voice: !voice_track.nil?)
    end

    if filter_complex
      cmd += ["-filter_complex", filter_complex, "-map", "0:v", "-map", "[aout]"]
    else
      cmd += ["-map", "0:v"]
      cmd += ["-map", "0:a?"]
    end

    cmd += ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest", "-movflags", "+faststart", output]

    FfmpegRunner.run!(cmd, label: "montaje final")
    output
  end

  # Cuando hay >1 clip, primero los re-encodea a un formato común (evita el
  # típico fallo de concat por streams con distinto fps/resolución/pix_fmt
  # que HappyHorse podría devolver entre shots) y los concatena con xfade
  # encadenado. Devuelve la ruta de un mp4 intermedio.
  def self.xfade_chain(shot_paths, beats = nil)
    dir = File.dirname(shot_paths.first)
    beats ||= Array.new(shot_paths.size) # nil beats → transición default en transition_for

    normalized = shot_paths.each_with_index.map do |path, i|
      raise FfmpegRunner::Error, "clip de entrada no existe: #{path}" unless File.exist?(path)
      norm_path = File.join(dir, "norm_#{i}.mp4")
      FfmpegRunner.run!(
        ["ffmpeg", "-y", "-i", path,
         "-vf", "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,fps=24,#{UNIFIED_GRADE}",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", norm_path],
        label: "normalizar+grade clip #{i} (#{File.basename(path)})"
      )
      norm_path
    end

    durations = normalized.map { |p| probe_duration(p) }
    inputs_args = normalized.flat_map { |p| ["-i", p] }

    filter = +""
    cumulative = durations.first
    prev_label = "[0:v]"
    normalized[1..].each_with_index do |_p, idx|
      i = idx + 1
      out_label = i == normalized.size - 1 ? "[vout]" : "[v#{i}]"
      # Duración de transición según el beat del clip ENTRANTE (i): así el
      # corte se acelera justo cuando la tensión sube, en vez de mantener el
      # mismo xfade uniforme durante toda la pieza.
      trans = NarrativeBeats.transition_for(beats[i] || beats[idx])
      offset = [cumulative - trans, 0].max
      filter << "#{prev_label}[#{i}:v]xfade=transition=fade:duration=#{trans}:offset=#{offset.round(2)}#{out_label};"
      cumulative += durations[i] - trans
      prev_label = out_label
    end
    filter.sub!(/;\z/, "")

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
  def self.grade_single_clip(path, out_path)
    raise FfmpegRunner::Error, "clip de entrada no existe: #{path}" unless File.exist?(path)
    FfmpegRunner.run!(
      ["ffmpeg", "-y", "-i", path,
       "-vf", "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,fps=24,#{UNIFIED_GRADE}",
       "-c:v", "libx264", "-pix_fmt", "yuv420p", out_path],
      label: "grade single clip"
    )
    out_path
  end

  def self.probe_duration(path)
    out = `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 #{Shellwords.escape(path)}`
    out.to_f.nonzero? || 5.0
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
  attr_reader :config, :selection, :token_ledger, :screenplay, :video_jobs

  def initialize(config:, qwen_config: nil, happyhorse_logger: HappyHorse::StdoutLogger.new)
    @config       = config
    @selection    = nil
    @screenplay   = nil
    @video_jobs   = []
    @scene_overrides = {}
    @token_ledger = { tokens_used: 0, tokens_remaining: config[:token_budget], video_credits_used: 0, calls: [] }
    @qwen_config  = qwen_config
    @happyhorse_logger = happyhorse_logger
  end

  def resolve_story!(tone: nil)
    @selection = StoryEngine.select!(
      prompt:       @config[:prompt],
      seed:         @config[:seed],
      tone:         tone,
      force_story:  @config[:force_story],
      force_domain: @config[:force_domain]
    )
  end

  def apply_overrides(max_scenes: nil, shot_duration: nil, voice_track: nil, music_track: nil)
    @scene_overrides[:max_scenes]    = max_scenes    if max_scenes
    @scene_overrides[:shot_duration] = shot_duration if shot_duration
    @scene_overrides[:voice_track]   = voice_track   if voice_track
    @scene_overrides[:music_track]   = music_track   if music_track
  end

  # ── Pipeline completo ────────────────────────────────────────────────────

  def run!(verbose: false, workdir: nil)
    workdir ||= Dir.mktmpdir("showrunner_")
    dry = @config[:dry_run]

    resolve_story! unless @selection
    unless dry || @config[:force_story]
      tone = StoryEngine.classify_tone!(@config[:prompt], ledger: @token_ledger, config: qwen_config)
      resolve_story!(tone: tone) if tone != @selection.tone
    end
    log(verbose, "Historia/dominio: #{@selection.base_story[:id]} → #{@selection.domain} (tono: #{@selection.tone})")

    @screenplay =
      if dry
        Screenwriter.generate_offline(selection: @selection, prompt: @config[:prompt],
                                       target_duration: @config[:target_duration],
                                       max_scenes: @scene_overrides[:max_scenes])
      else
        begin
          screenplay, _r = Screenwriter.generate!(
            selection: @selection, prompt: @config[:prompt],
            target_duration: @config[:target_duration], max_scenes: @scene_overrides[:max_scenes],
            ledger: @token_ledger, config: qwen_config
          )
          screenplay, _r = Storyboarder.compress!(screenplay, ledger: @token_ledger, config: qwen_config)
          screenplay
        rescue QwenRouter::BudgetExceeded, QwenRouter::Error, JSON::ParserError => e
          log(verbose, "⚠ Qwen falló/agotó presupuesto (#{e.class}: #{e.message}) — usando guion offline de respaldo")
          Screenwriter.generate_offline(selection: @selection, prompt: @config[:prompt],
                                         target_duration: @config[:target_duration],
                                         max_scenes: @scene_overrides[:max_scenes])
        end
      end

    # Fix brutal de continuidad (SIEMPRE, dry-run u online): sin importar
    # qué haya sobrevivido a la generación/compresión, cada shot termina con
    # los mismos rasgos fijos de protagonista y carga.
    @screenplay = ConsistencyEnforcer.apply!(@screenplay, @selection)

    n_shots = @screenplay["scenes"].sum { |s| s["shots"].size }
    log(verbose, "Guion: \"#{@screenplay['title']}\" — #{@screenplay['scenes'].size} escenas / #{n_shots} shots")

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
        @video_jobs, paths = VideoSynth.run!(@screenplay, client: client, workdir: workdir, resolution: @config[:resolution])
        paths
      end
    log(verbose, "Vídeo: #{shot_paths.size} clips (#{@video_jobs.count { |j| j[:status] == 'needs_review' }} en fallback)")

    beats = @screenplay["scenes"].flat_map { |scene| scene["shots"].map { |s| s["beat"] } }
    Editor.assemble!(
      shot_paths: shot_paths, output: @config[:output], beats: beats,
      music_track: @scene_overrides[:music_track], voice_track: @scene_overrides[:voice_track]
    )
    log(verbose, "✓ Montaje final: #{@config[:output]}")

    write_ledger_sidecar!
    self
  ensure
    FileUtils.remove_entry(workdir) if workdir && Dir.exist?(workdir) && !@config[:keep_workdir]
  end

  def to_manifest
    resolve_story! unless @selection
    {
      version: "1.0",
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
        protagonist_bible:  @selection.protagonist_bible,
        cargo_bible:        @selection.cargo_bible,
      },
      scene_overrides: @scene_overrides,
      screenplay: @screenplay,
      video_jobs: @video_jobs,
      edit: {
        transitions: %w[fade], music_track: @scene_overrides[:music_track],
        voice_track: @scene_overrides[:voice_track], captions: true,
      },
      budget_ledger: @token_ledger,
    }
  end

  private

  def qwen_config       = @qwen_config       ||= QwenRouter::Config.default
  def happyhorse_config = @happyhorse_config ||= HappyHorse::Config.default

  def log(verbose, msg) = (puts("  ▶ #{msg}") if verbose)

  def write_ledger_sidecar!
    path = "#{@config[:output]}.ledger.json"
    File.write(path, JSON.pretty_generate(budget_ledger: @token_ledger, video_jobs: @video_jobs))
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# BUILDER — superficie pública del DSL
# ─────────────────────────────────────────────────────────────────────────────

module Showrunner
  VERSION = "2.0.0"

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
    puts "│ Duración    : #{@config[:target_duration]}s  ·  Resolución: #{@config[:resolution]}"
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
    puts "\n▶  AI Showrunner — ejecutando pipeline#{' (dry-run, sin red)' if @config[:dry_run]}"
    @engine.run!(verbose: verbose)
    puts "✓  Pipeline completado: #{@config[:output]}"
    puts "   Ledger de tokens   : #{@config[:output]}.ledger.json"
    true
  rescue StandardError => e
    warn "✗  El pipeline falló: #{e.class} — #{e.message}"
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
    opts.banner = "Uso: ruby showrunner.rb PROMPT [opciones]"
    opts.on("--duration N", Integer, "Duración objetivo en segundos (default 75)") { |v| options[:duration] = v }
    opts.on("--resolution RES", "480P|720P|1080P (default 720P)")                 { |v| options[:resolution] = v }
    opts.on("--token-budget N", Integer, "Presupuesto de tokens (default 18000)")  { |v| options[:token_budget] = v }
    opts.on("--seed N", Integer, "Fija la selección de historia/dominio")          { |v| options[:seed] = v }
    opts.on("--render", "Ejecuta el pipeline completo (requiere red + ffmpeg)")    { options[:render] = true }
    opts.on("--dry-run", "Corre el pipeline entero sin red, con datos locales")    { options[:dry_run] = true }
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
    puts "\n💡  Para ejecutar sin gastar red/tokens: --dry-run"
    puts "💡  Para ejecutar el pipeline completo:  --render"
  end
end
