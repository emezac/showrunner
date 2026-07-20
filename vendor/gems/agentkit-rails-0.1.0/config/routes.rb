# frozen_string_literal: true

Agentkit::Engine.routes.draw do
  # ─── HITL Suggestions ─────────────────────────────────────────────────────
  resources :suggestions, only: [:index] do
    member do
      post :approve
      post :reject
      post :snooze
    end
  end

  # ─── Dreaming ─────────────────────────────────────────────────────────────
  namespace :dreaming do
    get  :status
    post :run_now
  end

  # ─── Fábrica (self-improvement) ───────────────────────────────────────────
  namespace :fabrica do
    get  :evolution_items
    post "evolution_items/:id/accept", to: "fabrica#accept_item",   as: :accept_item
    post "evolution_items/:id/reject", to: "fabrica#reject_item",   as: :reject_item
    get  :code_generations
    post "code_generations/:id/apply", to: "fabrica#apply_generation", as: :apply_generation
  end

  # ─── A2A (Agent-to-Agent) ─────────────────────────────────────────────────
  # Only mounted when a2a_enabled: true in config
  scope :a2a do
    get  ".well-known/agent.json", to: "a2a#agent_card"
    post "/",                      to: "a2a#dispatch"
  end
end
