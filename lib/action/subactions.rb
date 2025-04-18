# frozen_string_literal: true

module Action
  module Subactions
    extend ActiveSupport::Concern

    class_methods do
      def action(name, axn_klass = nil, exposes: {}, expects: {}, &block)
        raise ArgumentError, "Action name must be a string or symbol" unless name.is_a?(String) || name.is_a?(Symbol)
        raise ArgumentError, "Action '#{name}' must be given an existing action class or a block" if axn_klass.nil? && !block_given?
        raise ArgumentError, "Action '#{name}' was given both an existing action class and a block - only one is allowed" if axn_klass && block_given?

        new_action_name = "_subaction_#{name}"
        raise ArgumentError, "Action cannot be added -- '#{name}' is already taken" if respond_to?(new_action_name)

        if axn_klass && !(axn_klass.respond_to?(:<) && axn_klass < Action)
          raise ArgumentError,
                "Action '#{name}' must be given a block or an already-existing Action class"
        end

        axn_klass ||= Axn::Factory.build(superclass: self, exposes:, expects:, &block)

        define_singleton_method(new_action_name) { axn_klass }

        define_singleton_method(name) do |**kwargs|
          send(new_action_name).call(**kwargs)
        end

        define_singleton_method("#{name}!") do |**kwargs|
          send(new_action_name).call!(**kwargs)
        end
      end
    end
  end
end
