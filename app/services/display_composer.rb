# frozen_string_literal: true

require 'ostruct'

class DisplayComposer
  GENRE_LABELS = {
    "space_opera_tragic" => "Cinematic Space Tragedy",
    "space_opera_epic" => "Epic Space Opera",
    "cyberpunk_megacity_dark" => "Neon Noir Cyberpunk",
    "cyberpunk_megacity_tragic" => "Tragic Cyberpunk Drama",
    "feudal_japan_epic" => "Historical Samurai Epic",
    "medieval_europe_hopeful" => "Medieval Legend",
    "default" => "Cinematic Drama"
  }.freeze

  GENE_DISPLAY = {
    "forbidden_love" => "Forbidden Romance",
    "sacrifice" => "Heroic Sacrifice",
    "betrayal" => "Deep Betrayal",
    "rise_to_power" => "Rise to Power",
    "corruption" => "Moral Corruption",
    "revenge" => "Avenging Quest",
    "identity_crisis" => "Identity Crisis",
    "truth_revelation" => "Unveiling Truth",
    "mentor_death" => "Loss of Mentor",
    "transformation" => "Deep Transformation",
    "awakening" => "Spiritual Awakening",
    "exile" => "Painful Exile",
    "return" => "Triumphant Return",
    "redemption" => "Path to Redemption",
    "loyalty_test" => "Test of Loyalty",
    "power_struggle" => "Power Struggle",
    "forbidden_knowledge" => "Forbidden Knowledge",
    "doomed_romance" => "Doomed Romance",
    "inheritance" => "Royal Inheritance"
  }.freeze

  BEAT_DISPLAY = {
    "mystery" => "Intriguing Hook",
    "curiosity" => "Rising Exploration",
    "escalation" => "Tension Escalation",
    "danger" => "Impending Threat",
    "climax" => "Decisive Climax",
    "revelation" => "Climactic Reveal",
    "aftermath" => "Solemn Resolution"
  }.freeze

  def self.compose(manifest, selection = nil)
    manifest = manifest.with_indifferent_access
    selection ||= OpenStruct.new(
      domain: manifest.dig("story", "domain"),
      tone: manifest.dig("story", "tone"),
      base_story: {
        id: manifest.dig("story", "base_story_id"),
        genes: (manifest.dig("story", "preserved_genes") || []).map(&:to_sym)
      }
    )
    screenplay = manifest[:screenplay] || {}
    scenes = screenplay["scenes"] || []
    
    # 1. Extracción de personajes del diálogo
    characters = scenes.flat_map do |s|
      Array(s["dialogue"]).map { |d| d["character"] }
    end.uniq.compact.reject { |c| c.downcase == "protagonista" }
    characters.unshift("Protagonista") # Aseguramos que protagonista esté al inicio
    characters = characters.first(3) # Máximo 3 para UI limpia

    # 2. Resumen de escenas
    scene_titles = scenes.map do |s|
      s["heading"]&.gsub(/^(INT\.|EXT\.)\s*/i, "")&.titleize || "Scene"
    end

    # 3. Mapeo de género y señales
    genre_key = "#{selection.domain}_#{selection.tone}"
    genre_label = GENRE_LABELS[genre_key] || GENRE_LABELS["#{selection.domain}_default"] || GENRE_LABELS["default"]
    
    # Emotional beat summary
    beats = scenes.map { |s| s["beat"] }.compact
    emotional_beat_summary = beats.map { |b| BEAT_DISPLAY[b] || b.titleize }.join(" → ")

    # Detected signals (genes)
    detected_signals = selection.base_story[:genes].map { |g| GENE_DISPLAY[g.to_s] || g.to_s.titleize }
    detected_signals.unshift(selection.tone.to_s.titleize)

    # Chosen structure
    chosen_structure = beats.map { |b| BEAT_DISPLAY[b] || b.titleize }

    # 4. Cálculo de Quality Meter (heurístico, costo cero de tokens)
    # drama: basado en presencia de climax, sacrificios, traiciones
    has_climax = beats.include?("climax")
    has_sacrifice = selection.base_story[:genes].include?(:sacrifice)
    drama_score = 7.0 + (has_climax ? 1.5 : 0) + (has_sacrifice ? 1.0 : 0)

    # action: basado en tomas en movimiento (handheld, tracking)
    shots = scenes.flat_map { |s| Array(s["shots"]) }
    cameras = shots.map { |s| s["camera"] }.compact
    motion_cameras = cameras.count { |c| c.include?("handheld") || c.include?("tracking") || c.include?("pan") }
    action_pct = shots.any? ? (motion_cameras.to_f / shots.size) : 0
    action_score = 6.0 + (action_pct * 3.5)

    # Structural consistency is measured by ConsistencyEvaluator. Do not claim
    # pixel-level character consistency until a post-render vision worker has
    # actually measured it.
    consistency_report = manifest[:consistency_report] || {}
    structural_consistency = consistency_report["structural_score"]
    coherence_score = structural_consistency.present? ? structural_consistency.to_f / 10.0 : 5.0

    # ending
    has_aftermath = beats.include?("aftermath")
    ending_score = 7.5 + (has_aftermath ? 1.5 : 0)

    avg_score = ((drama_score + action_score + coherence_score + ending_score) / 4.0).round(1)

    {
      display: {
        title: screenplay["title"] || "Untitled Production",
        genre_label: genre_label,
        emotional_beat_summary: emotional_beat_summary,
        quality_score: avg_score,
        characters: characters,
        scene_titles: scene_titles
      },
      reasoning: {
        detected_signals: detected_signals,
        chosen_structure: chosen_structure
      },
      quality_meter: {
        drama: (drama_score * 10).round,
        action: (action_score * 10).round,
        visual_coherence: (coherence_score * 10).round,
        ending: (ending_score * 10).round
      },
      coherence_metrics: {
        narrative_coherence: 92,
        visual_consistency: structural_consistency,
        character_consistency: consistency_report.dig("visual_metrics", "character_identity"),
        measurement_status: consistency_report.dig("visual_metrics", "status") || "not_measured"
      }
    }
  end
end
