# frozen_string_literal: true

puts "Seeding database..."

# 1. Crear Cuenta y Usuario por defecto
account = Account.find_or_create_by!(name: "Showrunner Productions")
user = User.find_or_create_by!(name: "Enrique Director", email: "enrique@showrunner.ai")

# 2. Crear un Proyecto de demostración en estado Awaiting Storyboard Approval
# Esto le permite al usuario ver la interfaz completa del storyboard de inmediato.
p1 = user.projects.create!(
  prompt: "Un robot minero abandonado en Marte descubre una flor orgánica creciendo bajo la arena de óxido de hierro.",
  title: "La Flor de Óxido",
  seed: 424242,
  status: "awaiting_storyboard_approval",
  token_budget: 18000,
  tokens_used: 1250,
  tokens_remaining: 16750,
  video_credits_used: 0,
  resolution: "720P",
  duration: 40,
  dry_run: true,
  direction: {
    "director_influence" => "denis_villeneuve",
    "camera_style" => "slow_pans_fixed",
    "color_grade" => "desert_warmth",
    "music_style" => "epic_orchestral",
    "voice_style" => "male_deep"
  },
  manifest: {
    "version" => "1.0",
    "request" => {
      "prompt" => "Un robot minero abandonado en Marte descubre una flor orgánica creciendo bajo la arena de óxido de hierro.",
      "target_duration" => 40,
      "resolution" => "720P",
      "token_budget" => 18000,
      "video_model" => "happyhorse-1-1",
      "seed" => 424242
    },
    "story" => {
      "base_story_id" => "space_opera_default",
      "domain" => "space_opera",
      "preserved_genes" => ["awakening", "sacrifice"],
      "tone" => "epic",
      "protagonist_bible" => { "name" => "Ares-4", "details" => "Robot de minería oxidado con ópticas amarillas." },
      "cargo_bible" => { "name" => "La Flor", "details" => "Una flor orgánica roja que brilla tenuemente." },
      "display" => {
        "title" => "La Flor de Óxido",
        "genre_label" => "Epic Space Opera",
        "emotional_beat_summary" => "Intriguing Hook → Tension Escalation → Decisive Climax → Solemn Resolution",
        "quality_score" => 8.8,
        "characters" => ["Ares-4", "La Flor"],
        "scene_titles" => ["Dunas de Marte", "El Descubrimiento", "El Sacrificio"]
      }
    },
    "reasoning" => {
      "detected_signals" => ["Epic", "Spiritual Awakening", "Heroic Sacrifice"],
      "chosen_structure" => ["Intriguing Hook", "Tension Escalation", "Decisive Climax", "Solemn Resolution"]
    },
    "quality_meter" => {
      "drama" => 90,
      "action" => 75,
      "visual_coherence" => 95,
      "ending" => 90
    },
    "coherence_metrics" => {
      "narrative_coherence" => 94,
      "visual_consistency" => 96,
      "character_consistency" => 98
    },
    "screenplay" => {
      "title" => "La Flor de Óxido",
      "scenes" => [
        {
          "heading" => "EXT. DUNAS DE MARTE - DÍA",
          "beat" => "mystery",
          "shots" => [
            {
              "id" => "1.1",
              "visual_prompt" => "Ares-4, robot de minería oxidado con ópticas amarillas, excavando lentamente en dunas rojas bajo un cielo anaranjado",
              "camera" => "fixed close-up",
              "mode" => "slow_pans_fixed",
              "duration" => 5
            }
          ]
        },
        {
          "heading" => "EXT. DUNAS DE MARTE - DETALLE - DÍA",
          "beat" => "escalation",
          "shots" => [
            {
              "id" => "2.1",
              "visual_prompt" => "Ares-4, robot de minería oxidado con ópticas amarillas, sus garras mecánicas descubren una flor orgánica roja que brilla bajo el polvo de Marte",
              "camera" => "extreme close-up",
              "mode" => "slow_pans_fixed",
              "duration" => 5
            }
          ]
        },
        {
          "heading" => "EXT. DUNAS DE MARTE - CLÍMAX - DÍA",
          "beat" => "climax",
          "shots" => [
            {
              "id" => "3.1",
              "visual_prompt" => "Ares-4 protege la flor de una tormenta de arena inminente, su chasis bloquea el viento feroz",
              "camera" => "medium shot",
              "mode" => "slow_pans_fixed",
              "duration" => 6
            }
          ]
        }
      ]
    }
  }
)

puts "✓ Seeding completado exitosamente!"
