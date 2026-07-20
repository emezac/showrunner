# frozen_string_literal: true

class ApplicationAgent < Agentkit::ApplicationAgent
  # Override domain_context to provide running context to the agents
  def domain_context
    parts = []
    if current_user
      parts << "User: #{current_user.email} (ID: #{current_user.id})."
    end
    parts << "System Time: #{Time.current.utc.iso8601}."
    parts.join(" ")
  end
end
