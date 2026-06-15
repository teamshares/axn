# frozen_string_literal: true

class User < ActiveRecord::Base
  has_many :profiles, dependent: :destroy, autosave: true
  accepts_nested_attributes_for :profiles

  validates :name, presence: true
end
