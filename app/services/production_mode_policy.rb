# frozen_string_literal: true

# Defines the product contract between Automatic and Full Control modes.
# Automatic may resolve omitted creative settings deterministically. Full
# Control may pause and accept visual-QA risk, but it may not silently invent
# creative or audio choices that the producer left blank.
class ProductionModePolicy
  CONTROL_REQUIRED_FIELDS = %w[
    genre camera_style color_grade music_style voice_style
  ].freeze

  FIELD_LABELS = {
    "genre" => "Genre",
    "camera_style" => "Camera language",
    "color_grade" => "Color language",
    "music_style" => "Sound direction",
    "voice_style" => "Narration"
  }.freeze

  class << self
    def resolve(input:, prompt:)
      raw = input.to_h.with_indifferent_access
      mode = raw["pipeline_mode"].to_s
      mode = "agentic" if mode.blank? || mode == "automatic"
      mode = "control" if mode == "full_control"

      direction = raw.to_h.stringify_keys.compact
      direction["pipeline_mode"] = mode
      explicit = direction.select { |_key, value| value.present? }.keys

      if mode == "control"
        missing = CONTROL_REQUIRED_FIELDS.select { |field| direction[field].blank? }
        direction["configuration_source"] = "producer_explicit"
        direction["explicit_fields"] = explicit
        return {
          "direction" => direction,
          "errors" => missing.map { |field| "#{FIELD_LABELS.fetch(field)} must be selected in Full Control mode" },
          "resolved_defaults" => {}
        }
      end

      defaults = automatic_defaults(prompt: prompt, supplied_genre: direction["genre"])
      resolved = {}
      defaults.each do |field, value|
        next if direction[field].present?

        direction[field] = value
        resolved[field] = value
      end
      direction["configuration_source"] = "automatic_resolution"
      direction["explicit_fields"] = explicit
      direction["automatic_defaults"] = resolved
      { "direction" => direction, "errors" => [], "resolved_defaults" => resolved }
    end

    def automatic?(direction)
      direction.to_h.with_indifferent_access["pipeline_mode"].to_s != "control"
    end

    private

    def automatic_defaults(prompt:, supplied_genre: nil)
      genre = supplied_genre.presence || infer_genre(prompt)
      case genre
      when "sci_fi"
        defaults(genre, "slow_pans_fixed", "cyberpunk", "cyberpunk_synths")
      when "thriller", "horror"
        defaults(genre, "handheld_shaky", "noir", "ambient")
      when "fantasy"
        defaults(genre, "cinematic", "kodak", "epic_orchestral")
      when "drama"
        defaults(genre, "slow_pans_fixed", "warm", "ambient")
      else
        defaults(genre, "cinematic", "kodak", "ambient")
      end
    end

    def defaults(genre, camera, color, music)
      {
        "genre" => genre,
        "camera_style" => camera,
        "color_grade" => color,
        "music_style" => music,
        # Automatic mode never invents spoken narration. Screenplay dialogue
        # remains available for an explicit voice treatment.
        "voice_style" => "none"
      }
    end

    def infer_genre(prompt)
      text = prompt.to_s.downcase
      return "sci_fi" if text.match?(/science fiction|sci[- ]?fi|space|spaceship|alien|robot|cyber|future|ciencia ficci[oó]n|nave|extraterrestre|futuro/)
      return "horror" if text.match?(/horror|haunted|ghost|demon|terror|fantasma|demonio/)
      return "thriller" if text.match?(/mystery|thriller|crime|detective|misterio|suspenso|crimen|detective/)
      return "fantasy" if text.match?(/fantasy|magic|myth|dragon|enchanted|fantas[ií]a|m[aá]gic|mito|drag[oó]n|encantad/)

      "drama"
    end
  end
end
