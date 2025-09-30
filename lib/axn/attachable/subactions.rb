# frozen_string_literal: true

module Axn
  module Attachable
    module Subactions
      extend ActiveSupport::Concern

      class_methods do
        def axn(name, axn_klass = nil, **kwargs, &block)
          attach_axn(as: :axn, name:, axn_klass:, **kwargs, &block)
        end

        def axn_method(name, axn_klass = nil, **kwargs, &block)
          attach_axn(as: :method, name:, axn_klass:, **kwargs, &block)
        end
      end
    end
  end
end
