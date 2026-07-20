# frozen_string_literal: true

require "fileutils"
require "open3"
require "securerandom"

# Resolves and prepares final-cut audio without pretending that silent video is
# a completed sound mix. Music is generated procedurally by Editor from the
# selected style; optional narration is synthesized from screenplay narration
# or dialogue and then mixed with ducking. When a producer explicitly selects
# a voice for a non-dialogue screenplay, the approved scene actions become the
# narration source. This honors the audio choice without inventing story facts.
class AudioDirector
  class ConfigurationError < StandardError; end
  class SynthesisError < StandardError; end

  VOICES = {
    "female_whisper" => { say: "Samantha", espeak: "en+f3" },
    "male_deep" => { say: "Alex", espeak: "en+m3" },
    "robotic_flat" => { say: "Zarvox", espeak: "en+m1" }
  }.freeze

  class << self
    def prepare!(screenplay:, direction:, output_dir:, target_duration: nil)
      source = direction.to_h.with_indifferent_access
      music_style = source["music_style"].presence
      voice_style = source["voice_style"].presence
      raise ConfigurationError, "Sound direction is unresolved" if music_style.blank?
      raise ConfigurationError, "Narration choice is unresolved" if voice_style.blank?

      voice_track = nil
      narration = { "text" => "", "source" => "none" }
      speech_rate = nil
      if voice_style != "none"
        narration = resolve_narration(screenplay)
        if narration["text"].blank?
          raise ConfigurationError,
            "Narration was selected, but the screenplay has no spoken text or narrative scene actions to voice"
        end

        speech_rate = speech_rate_for(narration["text"], target_duration: target_duration)
        voice_track = synthesize!(
          text: narration["text"], style: voice_style, output_dir: output_dir,
          speech_rate: speech_rate
        )
      end

      {
        "soundtrack_style" => (music_style unless music_style == "none"),
        "voice_style" => voice_style,
        "voice_track" => voice_track,
        "narration_source" => narration["source"],
        "narration_text" => narration["text"],
        "speech_rate_wpm" => speech_rate,
        "audio_required" => music_style != "none" || voice_style != "none",
        "explicit_silence" => music_style == "none" && voice_style == "none"
      }
    end

    def resolve_narration(screenplay)
      explicit = narration_text(screenplay)
      return { "text" => explicit, "source" => "screenplay_spoken_text" } if explicit.present?

      derived = action_narration_text(screenplay)
      return { "text" => derived, "source" => "approved_scene_actions" } if derived.present?

      { "text" => "", "source" => "missing" }
    end

    def narration_text(screenplay)
      direct = [screenplay["narration"], screenplay["voice_over"]].compact_blank
      scenes = Array(screenplay["scenes"])
      scene_narration = scenes.flat_map do |scene|
        values = [scene["narration"], scene["voice_over"]].compact_blank
        dialogue = Array(scene["dialogue"]).filter_map do |line|
          text = line["line"].to_s.squish
          text if text.present?
        end
        values + dialogue
      end
      (direct + scene_narration).join(". ").squish.first(12_000)
    end

    def action_narration_text(screenplay)
      actions = Array(screenplay["scenes"]).filter_map do |scene|
        text = [scene["action"], scene["story_event"], scene["summary"]]
          .find { |candidate| candidate.to_s.squish.present? }
        normalize_narration_text(text)
      end

      actions.uniq.join(" ").squish.first(12_000)
    end

    def speech_rate_for(text, target_duration: nil)
      duration = target_duration.to_f
      return 180 unless duration.positive?

      word_count = text.to_s.scan(/\S+/).size
      # Reserve ten percent of the cut for punctuation pauses and the natural
      # tail of the synthesizer, then keep the result inside an intelligible
      # range supported by both macOS `say` and espeak.
      requested = (word_count * 60.0 / (duration * 0.9)).ceil
      requested.clamp(130, 260)
    end

    def synthesize!(text:, style:, output_dir:, speech_rate: nil)
      FileUtils.mkdir_p(output_dir)
      voice = VOICES.fetch(style.to_s, VOICES["male_deep"])
      if executable?("say")
        path = File.join(output_dir, "narration_#{SecureRandom.hex(6)}.aiff")
        command = ["say", "-v", voice[:say]]
        command += ["-r", speech_rate.to_i.to_s] if speech_rate.to_i.positive?
        _out, error, status = Open3.capture3(*command, "-o", path, text.to_s)
      elsif executable?("espeak")
        path = File.join(output_dir, "narration_#{SecureRandom.hex(6)}.wav")
        command = ["espeak", "-v", voice[:espeak]]
        command += ["-s", speech_rate.to_i.to_s] if speech_rate.to_i.positive?
        _out, error, status = Open3.capture3(*command, "-w", path, text.to_s)
      else
        raise SynthesisError, "No local speech synthesizer is available"
      end
      unless status.success? && File.file?(path) && File.size(path).positive?
        raise SynthesisError, "Narration synthesis failed: #{error.to_s.squish.first(240)}"
      end

      path
    end

    private

    def normalize_narration_text(value)
      value.to_s
        .gsub(/\A\s*(?:ACTION|NARRATION)\s*:\s*/i, "")
        .gsub(/[\*#_`]+/, "")
        .squish
    end

    def executable?(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        File.executable?(File.join(directory, name))
      end
    end
  end
end
