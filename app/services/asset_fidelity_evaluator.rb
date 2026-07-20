# frozen_string_literal: true

require_relative "scale_contract_resolver"

# Semantic preflight for canonical assets. It is intentionally deterministic:
# model output may propose profiles, but it cannot grade its own fidelity.
class AssetFidelityEvaluator
  GENERIC_MARKERS = [
    "matching the narrative tone", "key character", "expressive, key player",
    "acts with intent", "cinematic portrait", "rich lighting",
    "high-fidelity spatial environment", "mysterious haze",
    "volumetric lighting, highly detailed", "default studio location"
  ].freeze
  PLACEHOLDER_NAMES = %w[protagonist protagonista hero heroine character personaje].freeze
  STOP_WORDS = %w[
    about after again also and are because been being between both but can could
    each for from had has have into its more most not only other our out over same
    should some such than that the their them then there these they this through
    under very was were what when where which while who will with would your
    como con del desde donde el ella en entre era esta este esto hay la las los
    para pero por que se sin sobre son su sus una uno y
  ].freeze

  class << self
    def evaluate(source_prompt:, assets:, source_profiles: nil)
      source = [source_profiles, source_prompt].compact.join("\n")
      characters = Array(fetch(assets, "characters"))
      props = Array(fetch(assets, "props"))
      locations = Array(fetch(assets, "locations"))
      issues = []

      if characters.empty?
        issues << issue("critical", "missing_character_profile", "No canonical character was extracted from the source")
      else
        characters.each_with_index do |raw_character, index|
          character = stringify(raw_character)
          character_text = [character["name"], character["entity_type"], character["physical_description"],
                            character["wardrobe"], character["visual_prompt"], *Array(character["immutable_traits"])].join(" ")
          if generic?(character_text) || character_text.split.size < 14
            issues << issue("critical", "generic_character_profile", "Character '#{character['name'] || index + 1}' is generic and is not safe for reference generation")
          elsif index.zero? && detailed_source?(source) && overlap(source, character_text) < 3
            issues << issue("critical", "character_source_mismatch", "Primary character does not preserve enough distinctive source traits")
          end
          if character_text.match?(ScaleContractResolver::MINIATURE_PATTERN) &&
             !character["scale_reference"].to_s.match?(/same physical height|canonical height|same-class peer/i)
            issues << issue("critical", "missing_miniature_scale_lock", "Miniature character has no measurable peer-relative scale contract")
          end
        end
      end

      locations.each do |raw|
        location = stringify(raw)
        text = [location["name"], location["description"], location["visual_prompt"]].join(" ")
        next unless generic?(text)

        issues << issue("critical", "generic_location_profile", "Location '#{location['name']}' is a generic visual fallback")
      end

      all_text = (characters + props + locations).map { |asset| stringify(asset).values.join(" ") }.join(" ")
      score = if source.strip.empty?
                issues.empty? ? 100 : 35
              else
                [100 - issues.sum { |item| item["severity"] == "critical" ? 45 : 10 } -
                  (detailed_source?(source) && overlap(source, all_text) < 4 ? 15 : 0), 0].max
              end

      {
        "status" => issues.empty? ? "passed" : "failed",
        "ready" => issues.none? { |item| item["severity"] == "critical" },
        "score" => score,
        "source_overlap_terms" => overlap(source, all_text),
        "issues" => issues
      }
    end

    def generic?(text)
      normalized = text.to_s.downcase
      GENERIC_MARKERS.any? { |marker| normalized.include?(marker) }
    end

    private

    def fetch(hash, key)
      return unless hash.respond_to?(:[])
      hash[key] || hash[key.to_sym]
    end

    def detailed_source?(source)
      source.to_s.length >= 180
    end

    def overlap(left, right)
      (tokens(left) & tokens(right)).size
    end

    def tokens(text)
      text.to_s.downcase.scan(/[\p{L}\p{N}]+/).reject do |word|
        word.length < 4 || STOP_WORDS.include?(word)
      end.uniq
    end

    def stringify(value)
      value.respond_to?(:stringify_keys) ? value.stringify_keys : value.to_h.transform_keys(&:to_s)
    end

    def issue(severity, code, message)
      { "severity" => severity, "shot_id" => nil, "code" => code, "message" => message }
    end
  end
end
