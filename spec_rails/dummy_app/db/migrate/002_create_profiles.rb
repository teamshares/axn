# frozen_string_literal: true

class CreateProfiles < ActiveRecord::Migration[7.0]
  def change
    create_table :profiles do |t|
      t.references :user, null: false
      t.string :nickname, null: true

      t.timestamps
    end
  end
end
