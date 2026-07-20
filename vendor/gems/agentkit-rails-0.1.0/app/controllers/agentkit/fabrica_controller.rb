# frozen_string_literal: true

module Agentkit
  # The Fábrica (Factory) controller manages the self-improvement loop:
  # EvolutionItems → CodeGenerations → apply to disk.
  # Mounted at /agentkit/fabrica.
  class FabricaController < ActionController::API
    before_action :authenticate_user!

    # GET /agentkit/fabrica/evolution_items
    def evolution_items
      items = Agentkit::EvolutionItem
        .where(user: current_user)
        .order(created_at: :desc)

      items = items.where(status: params[:status]) if params[:status].present?

      render json: items.map { |i| serialize_item(i) }
    end

    # POST /agentkit/fabrica/evolution_items/:id/accept
    def accept_item
      item = find_item
      item.accept!
      render json: { status: "accepted", item: serialize_item(item) }
    end

    # POST /agentkit/fabrica/evolution_items/:id/reject
    def reject_item
      item = find_item
      item.reject!(reason: params[:reason])
      render json: { status: "rejected", item: serialize_item(item) }
    end

    # GET /agentkit/fabrica/code_generations
    def code_generations
      gens = Agentkit::CodeGeneration
        .where(user: current_user)
        .includes(:evolution_item)
        .order(created_at: :desc)

      render json: gens.map { |g| serialize_generation(g) }
    end

    # POST /agentkit/fabrica/code_generations/:id/apply
    def apply_generation
      gen = Agentkit::CodeGeneration.find_by!(id: params[:id], user: current_user)
      gen.apply!(current_user)
      render json: { status: "applied", target_file: gen.target_file }
    rescue SecurityError => e
      render json: { error: e.message }, status: :forbidden
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def find_item
      Agentkit::EvolutionItem.find_by!(id: params[:id], user: current_user)
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Evolution item not found" }, status: :not_found and return
    end

    def serialize_item(item)
      {
        id:          item.id,
        item_type:   item.item_type,
        title:       item.title,
        description: item.description,
        rationale:   item.rationale,
        status:      item.status,
        priority:    item.priority,
        created_at:  item.created_at,
        code_generations_count: item.code_generations.count
      }
    end

    def serialize_generation(gen)
      {
        id:             gen.id,
        evolution_item: { id: gen.evolution_item_id, title: gen.evolution_item&.title },
        target_file:    gen.target_file,
        generated_code: gen.generated_code,
        explanation:    gen.explanation,
        status:         gen.status,
        applied_at:     gen.applied_at,
        created_at:     gen.created_at
      }
    end

    def authenticate_user!
      # Domain implements this
    end

    def current_user
      raise NotImplementedError, "Domain must implement current_user"
    end
  end
end
