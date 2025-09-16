# frozen_string_literal: true

module Axn
  module Util
    module Memoization
      def self.define_memoized_reader_method(target, field, &block)
        target.define_method(field) do
          ivar = :"@_memoized_reader_#{field}"
          cached_val = instance_variable_get(ivar)
          return cached_val if cached_val.present?

          value = instance_exec(&block)
          instance_variable_set(ivar, value)
        end
      end
    end
  end
end
