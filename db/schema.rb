# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 10) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

  create_table "accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "agentkit_agent_logs", force: :cascade do |t|
    t.string "agent_name", null: false
    t.float "cost_usd"
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.string "event_type"
    t.jsonb "payload", default: {}, null: false
    t.text "prompt_preview"
    t.string "status"
    t.integer "tokens_used"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["agent_name", "created_at"], name: "index_agentkit_agent_logs_on_agent_name_and_created_at"
    t.index ["event_type"], name: "index_agentkit_agent_logs_on_event_type"
    t.index ["status"], name: "index_agentkit_agent_logs_on_status"
    t.index ["user_id"], name: "index_agentkit_agent_logs_on_user_id"
  end

  create_table "agentkit_agent_suggestions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.jsonb "payload", default: {}, null: false
    t.string "priority", default: "medium", null: false
    t.datetime "resolved_at"
    t.string "source_agent", null: false
    t.string "status", default: "pending", null: false
    t.bigint "suggestable_id"
    t.string "suggestable_type"
    t.string "suggestion_type", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["priority"], name: "index_agentkit_suggestions_on_priority"
    t.index ["suggestable_type", "suggestable_id"], name: "index_agentkit_agent_suggestions_on_suggestable"
    t.index ["suggestable_type", "suggestable_id"], name: "index_agentkit_suggestions_on_suggestable"
    t.index ["user_id", "status"], name: "index_agentkit_suggestions_on_user_id_and_status"
    t.index ["user_id"], name: "index_agentkit_agent_suggestions_on_user_id"
  end

  create_table "agentkit_code_generations", force: :cascade do |t|
    t.datetime "applied_at"
    t.datetime "created_at", null: false
    t.bigint "evolution_item_id", null: false
    t.text "explanation"
    t.text "generated_code"
    t.string "status", default: "draft", null: false
    t.string "target_file", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["evolution_item_id", "status"], name: "index_agentkit_code_gens_on_evolution_item_and_status"
    t.index ["evolution_item_id"], name: "index_agentkit_code_generations_on_evolution_item_id"
    t.index ["user_id"], name: "index_agentkit_code_generations_on_user_id"
  end

  create_table "agentkit_evolution_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "item_type"
    t.string "priority"
    t.text "rationale"
    t.string "status", default: "pending", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["item_type"], name: "index_agentkit_evolution_items_on_item_type"
    t.index ["user_id", "status"], name: "index_agentkit_evolution_items_on_user_id_and_status"
    t.index ["user_id"], name: "index_agentkit_evolution_items_on_user_id"
  end

  create_table "agentkit_memories", force: :cascade do |t|
    t.bigint "account_id"
    t.float "confidence", default: 0.7, null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.vector "embedding", limit: 1536
    t.string "memory_type", default: "observation", null: false
    t.string "source_agent"
    t.string "status", default: "raw", null: false
    t.jsonb "tags", default: [], null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["account_id"], name: "index_agentkit_memories_on_account_id"
    t.index ["confidence"], name: "index_agentkit_memories_on_confidence"
    t.index ["embedding"], name: "index_agentkit_memories_on_embedding_ivfflat", opclass: :vector_cosine_ops, using: :ivfflat
    t.index ["memory_type"], name: "index_agentkit_memories_on_memory_type"
    t.index ["user_id", "status"], name: "index_agentkit_memories_on_user_id_and_status"
    t.index ["user_id"], name: "index_agentkit_memories_on_user_id"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "direction", default: {}
    t.boolean "dry_run", default: true, null: false
    t.integer "duration", default: 75, null: false
    t.string "final_video_url"
    t.jsonb "genes_override", default: []
    t.jsonb "manifest", default: {}
    t.text "prompt", null: false
    t.string "resolution", default: "720P", null: false
    t.integer "seed"
    t.string "status", default: "queued", null: false
    t.string "title"
    t.integer "token_budget", default: 18000, null: false
    t.integer "tokens_remaining"
    t.integer "tokens_used", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.integer "video_credits_used", default: 0, null: false
    t.index ["status"], name: "index_projects_on_status"
    t.index ["user_id"], name: "index_projects_on_user_id"
  end

  create_table "render_timings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "n_shots", null: false
    t.bigint "project_id", null: false
    t.string "resolution", null: false
    t.float "total_seconds", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_render_timings_on_project_id"
  end

  create_table "shots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration", default: 5, null: false
    t.boolean "locked", default: false, null: false
    t.bigint "project_id", null: false
    t.string "shot_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "variant_of_id"
    t.text "visual_prompt"
    t.index ["project_id", "shot_id"], name: "index_shots_on_project_id_and_shot_id", unique: true
    t.index ["project_id"], name: "index_shots_on_project_id"
    t.index ["variant_of_id"], name: "index_shots_on_variant_of_id"
  end

  create_table "ui_assist_ledger_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "project_id", null: false
    t.integer "tokens_used", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_ui_assist_ledger_entries_on_project_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "agentkit_agent_logs", "users"
  add_foreign_key "agentkit_agent_suggestions", "users"
  add_foreign_key "agentkit_code_generations", "agentkit_evolution_items", column: "evolution_item_id"
  add_foreign_key "agentkit_code_generations", "users"
  add_foreign_key "agentkit_evolution_items", "users"
  add_foreign_key "agentkit_memories", "accounts"
  add_foreign_key "agentkit_memories", "users"
  add_foreign_key "projects", "users"
  add_foreign_key "render_timings", "projects"
  add_foreign_key "shots", "projects"
  add_foreign_key "ui_assist_ledger_entries", "projects"
end
