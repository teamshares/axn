# frozen_string_literal: true

require_relative "attachable/base"
require_relative "attachable/steps"
require_relative "attachable/subactions"

module Action
  module Attachable
    extend ActiveSupport::Concern

    included do
      include Base
      include Steps
      include Subactions
    end
  end
end
