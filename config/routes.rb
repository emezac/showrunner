Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  # Mount AgentKit engine
  mount Agentkit::Engine => "/agentkit"

  # Projects resources
  resources :projects do
    member do
      post :approve_storyboard
      post :render_video
      post :regenerate_scene
      post :regenerate_shot
      post :generate_variant
      post :update_metadata
      post :regenerate_asset_image
      post :regenerate_shot_image
      post :regenerate_scene_images
      post :rerun_visual_qa
    end
    collection do
      post :copilot_suggest
      post :forecast_tokens
    end
  end

  # Root route
  root "projects#index"
  get "architecture" => "projects#architecture", as: :architecture
  get "placeholders/:filename" => "projects#placeholder", as: :placeholder, constraints: { filename: /.*/ }
end
