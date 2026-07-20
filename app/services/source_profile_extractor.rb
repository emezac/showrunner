# frozen_string_literal: true

# Separates canonical entity descriptions from screenplay/camera directions.
# This accepts loose prose, Markdown and bilingual labels without requiring a
# project-specific template.
class SourceProfileExtractor
  SCENE_HEADING = /(?:\A|\n)\s*(?:\#{1,4}\s*)?(?:first\s+scene|scene\s*\d+|escena\s*\d+|sequence\s*\d+|secuencia\s*\d+|act\s*\d+|acto\s*\d+|teaser|screenplay|guion)\b/i
  CHARACTER_LABEL = /(?:\A|\n)\s*(?:character|personaje|protagonist|protagonista|hero|h[eé]roe)\s*:\s*/i
  LOCATION_LABEL = /(?:\A|\n)\s*(?:location|locaci[oó]n|setting|environment|ambiente)\s*:\s*/i

  class << self
    def character_profile(prompt, name: nil)
      extract_labeled(prompt, CHARACTER_LABEL, name: name)
    end

    def location_profile(prompt)
      extract_labeled(prompt, LOCATION_LABEL)
    end

    def profile_contaminated?(text)
      value = text.to_s
      value.match?(SCENE_HEADING) || value.match?(/\b(?:camera|c[aá]mara|lens|lente|shot|toma)\b/i) && value.length > 1_500
    end

    private

    def extract_labeled(prompt, label, name: nil)
      source = prompt.to_s
      match = source.match(label)
      value = if match
                tail = source[match.end(0)..]
                tail.to_s.split(SCENE_HEADING, 2).first.to_s
              else
                source.split(SCENE_HEADING, 2).first.to_s
              end
      value = value.sub(/\A\s*\#{1,4}\s*/, "").strip
      value = value.sub(
        /\A(?:visual\s+description(?:\s+of\s+(?:the\s+)?(?:hero|character|protagonist))?|descripci[oó]n\s+visual(?:\s+del?\s+(?:h[eé]roe|personaje|protagonista))?)\s*\n+/i,
        ""
      ).strip
      return value if name.blank? || placeholder_name?(name)

      sections = value.split(/\n{2,}|(?=^\#{1,4}\s+)/)
      selected = sections.select { |section| section.downcase.include?(name.to_s.downcase) }.join("\n")
      selected.length >= 80 ? selected.strip : value
    end

    def placeholder_name?(name)
      name.to_s.match?(/\A(?:protagonist|protagonista|hero|heroine|h[eé]roe|character|personaje|primary character)\z/i)
    end
  end
end
