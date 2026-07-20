# frozen_string_literal: true

class CreateUiAssistLedgerEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :ui_assist_ledger_entries do |t|
      t.references :project, null: false, foreign_key: true
      t.integer :tokens_used, null: false

      t.timestamps
    end
  end
end
