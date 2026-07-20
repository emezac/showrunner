# frozen_string_literal: true

class ProjectChannel < ApplicationCable::Channel
  def subscribed
    stream_from "project_#{params[:id]}"
  end

  def unsubscribed
    # Any cleanup when channel is unsubscribed
  end
end
