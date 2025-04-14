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

        axn_klass ||= block_to_axn(block, exposes:, expects:)

        define_singleton_method(new_action_name) { axn_klass }

        define_singleton_method(name) do |**kwargs|
          send(new_action_name).call(**kwargs)
        end

        define_singleton_method("#{name}!") do |**kwargs|
          send(new_action_name).call!(**kwargs)
        end
      end

      private

      def _hash_with_default_array = Hash.new { |h, k| h[k] = [] }

      def _hydrate_hash(given)
        return given if given.is_a?(Hash)

        raise ArgumentError, "Expected a Hash or an Array of keys" unless given.is_a?(Array)

        given.each_with_object({}) do |key, acc|
          acc[key] = {}
        end
      end

      def block_to_axn(block, exposes: {}, expects: {})
        args = block.parameters.each_with_object(_hash_with_default_array) { |(type, name), hash| hash[type] << name }

        raise ArgumentError, "Cannot convert block to action: block expects positional arguments" if args[:req].present? || args[:rest].present?
        raise ArgumentError, "Cannot convert block to action: block expects a splat of keyword arguments" if args[:keyrest].present?

        # TODO: is there any way to support default arguments? (if so, set allow_blank: true for those)
        if args[:key].present?
          raise ArgumentError,
                "Cannot convert block to action: block expects keyword arguments with defaults (ruby does not allow introspecting)"
        end

        expects = _hydrate_hash(expects)
        exposes = _hydrate_hash(exposes)

        Array(args[:keyreq]).each do |name|
          expects[name] ||= {}
        end

        Class.new do
          include Action

          define_method(:call) do
            unwrapped_kwargs = Array(args[:keyreq]).each_with_object({}) do |name, hash|
              hash[name] = public_send(name)
            end
            value = instance_exec(**unwrapped_kwargs, &block)
            expose(value:) if exposes.blank? # NOTE: only setting default value exposure if nothing explicitly passed in
          end
        end.tap do |axn| # rubocop: disable Style/MultilineBlockChain
          expects.each do |name, opts|
            axn.expects(name, **opts)
          end

          exposes.each do |name, opts|
            axn.exposes(name, **opts)
          end

          # Default value exposure
          axn.exposes(:value, allow_blank: true) if exposes.blank?
        end
      end
    end
  end
end
