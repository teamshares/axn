# frozen_string_literal: true

require "axn/attachable/base"
require "axn/attachable/proxy_builder"

module Axn
  module Attachable
    extend ActiveSupport::Concern

    included do
      include Base
    end

    # Extend DSL methods from attachment types when module is included
    def self.included(base)
      super
      AttachmentTypes.all.each do |(_name, klass)|
        base.extend klass::DSL if klass.const_defined?(:DSL)
      end
    end
  end
end
