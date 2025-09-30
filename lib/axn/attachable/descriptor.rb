# frozen_string_literal: true

module Axn
  module Attachable
    Descriptor = Data.define(:as, :name, :axn_klass, :kwargs, :block) do
      def validate!
        Validator.validate!(self)
      end
    end
  end
end
