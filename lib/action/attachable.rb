# frozen_string_literal: true

require "action/attachable/base"
require "action/attachable/steps"
require "action/attachable/subactions"

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
