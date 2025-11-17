# frozen_string_literal: true

module Axn
  class Strategies
    module Form
      # @param expect [Symbol] the attribute name to expect in the context (e.g. :params)
      # @param expose [Symbol] the attribute name to expose in the context (e.g. :form)
      # @param type [Class] the form class to use
      # @param inject [Array<Symbol>] optional additional attributes to include in the form (e.g. [:user, :company])
      def self.configure(expect: :params, expose: :form, type: nil, inject: nil)
        expect ||= :"#{expose.to_s.delete_suffix("_form")}_params"

        # Aliasing to avoid shadowing/any confusion
        expect_attr = expect
        expose_attr = expose

        Module.new do
          extend ActiveSupport::Concern

          included do
            raise ArgumentError, "form strategy: must pass explicit :type parameter to `use :form` when applying to anonymous classes" if type.nil? && name.nil?

            type ||= "#{name}::#{expose_attr.to_s.classify}".constantize

            raise ArgumentError, "form strategy: #{type} must implement `valid?`" unless type.method_defined?(:valid?)

            expects expect_attr, type: :params
            exposes(expose_attr, type:)

            define_method expose_attr do
              attrs_for_form = public_send(expect_attr)&.dup || {}

              Array(inject).each do |ctx|
                attrs_for_form[ctx] = public_send(ctx)
              end

              type.new(attrs_for_form)
            end
            memo expose_attr

            before do
              expose expose_attr => public_send(expose_attr)
              fail! unless public_send(expose_attr).valid?
            end
          end
        end
      end
    end
  end
end
