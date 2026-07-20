# frozen_string_literal: true

class AddDryRunToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :dry_run, :boolean, default: true, null: false
  end
end
