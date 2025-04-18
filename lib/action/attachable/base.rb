# frozen_string_literal: true

module Action
  module Attachable
    module Base
      extend ActiveSupport::Concern

      class_methods do
        def _new_action_name(name) = "_subaction_#{name}"

        def axn_for_attachment(attachment_type: "Action", name: nil, axn_klass: nil, exposes: {}, expects: {}, &block)
          raise ArgumentError, "#{attachment_type} name must be a string or symbol" unless name.is_a?(String) || name.is_a?(Symbol)
          raise ArgumentError, "#{attachment_type} '#{name}' must be given an existing action class or a block" if axn_klass.nil? && !block_given?

          if axn_klass && block_given?
            raise ArgumentError,
                  "#{attachment_type} '#{name}' was given both an existing action class and a block - only one is allowed"
          end

          raise ArgumentError, "#{attachment_type} cannot be added -- '#{name}' is already taken" if respond_to?(_new_action_name(name))

          if axn_klass && !(axn_klass.respond_to?(:<) && axn_klass < Action)
            raise ArgumentError,
                  "#{attachment_type} '#{name}' must be given a block or an already-existing Action class"
          end

          Axn::Factory.build(superclass: self, exposes:, expects:, &block)
        end
      end
    end
  end
end
