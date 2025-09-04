# frozen_string_literal: true

require "axn/attachable/base"
require "axn/attachable/steps"
require "axn/attachable/subactions"

module Axn
  module Attachable
    extend ActiveSupport::Concern

    included do
      include Base
      include Steps
      include Subactions
    end
  end
end
