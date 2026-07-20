# frozen_string_literal: true

# Converts structured shot intent into a generation prompt without asking an
# LLM to summarize (and potentially delete) critical blocking or state data.
class StoryboardPromptCompiler
  VERSION = "1.0"
  MAX_CHARS = 1_200

  class << self
    def compile!(screenplay)
      Array(screenplay["scenes"]).each do |scene|
        Array(scene["shots"]).each do |shot|
          source = source_action(shot)
          generation_action = shot["resolved_generation_action"].to_s.presence ||
            (source.length > 600 ? shot["story_event"].to_s : source)
          generation_action = source[0, 600].sub(/\s+\S*\z/, "") if generation_action.blank?
          components = {
            "purpose" => shot["purpose"].to_s,
            "story_event" => shot["story_event"].to_s,
            "action" => generation_action,
            "entry_state" => state_text(shot["entry_state"]),
            "exit_state" => state_text(shot["exit_state"]),
            "camera" => shot["camera"].to_s,
            "blocking" => state_text(shot["blocking"]),
            "scene_objective" => scene["objective"].to_s,
            "style" => Array(scene["style_directives"]).join("; "),
            "script_resolution" => Array(shot.dig("script_consistency", "issues"))
              .map { |item| item["message"] }.join("; ")
          }
          shot["source_visual_prompt"] ||= source
          shot["generation_action"] = generation_action
          shot["prompt_components"] = components
          shot["visual_prompt"] = render(components)
        end
      end
      screenplay
    end

    private

    def source_action(shot)
      shot["source_visual_prompt"].to_s.presence || strip_generated_sections(shot["visual_prompt"].to_s)
    end

    def strip_generated_sections(text)
      base = text.sub(/\AACTION:\s*/i, "")
      base = base.split(/\s*\|\s*CANON LOCK:/i, 2).first.to_s
      if base.include?("SHOT PURPOSE:")
        action = base[/\bACTION:\s*(.*?)(?=\s*\|\s*[A-Z _]+:|\z)/i, 1]
        return action.to_s.strip if action.present?
      end
      base.strip
    end

    def render(components)
      sections = []
      sections << "ACTION: #{bounded(components['action'], 380)}"
      sections << "SCRIPT CONSISTENCY: #{bounded(components['script_resolution'], 180)}" if components["script_resolution"].present?
      sections << "EXIT STATE: #{bounded(components['exit_state'], 130)}" if components["exit_state"].present?
      sections << "ENTRY STATE: #{bounded(components['entry_state'], 130)}" if components["entry_state"].present?
      sections << "CAMERA: #{bounded(components['camera'], 90)}" if components["camera"].present?
      sections << "BLOCKING: #{bounded(components['blocking'], 100)}" if components["blocking"].present?
      sections << "SHOT PURPOSE: #{bounded(components['purpose'], 110)}" if components["purpose"].present?
      if components["story_event"].present? && components["story_event"] != components["action"]
        sections << "STORY EVENT: #{bounded(components['story_event'], 150)}"
      end
      sections << "SCENE OBJECTIVE: #{bounded(components['scene_objective'], 110)}" if components["scene_objective"].present?
      sections << "STYLE: #{bounded(components['style'], 120)}" if components["style"].present?
      bounded(sections.join(" | "), MAX_CHARS)
    end

    def state_text(value)
      case value
      when Hash
        value.map { |key, item| "#{key}=#{state_text(item)}" }.join(", ")
      when Array
        value.map { |item| state_text(item) }.join(", ")
      else
        value.to_s
      end
    end

    def bounded(value, max_chars)
      text = value.to_s.gsub(/\s+/, " ").strip
      return text if text.length <= max_chars

      text[0, max_chars].sub(/\s+\S*\z/, "").strip
    end
  end
end
