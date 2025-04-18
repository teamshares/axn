# frozen_string_literal: true

module Axn
  class Factory
    class << self
      # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity, Metrics/ParameterLists
      def build(
        superclass: nil,
        exposes: {},
        expects: {},
        messages: {},
        before: nil,
        after: nil,
        around: nil,
        rollback: nil,
        &block
      )
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

        # NOTE: inheriting from wrapping class, so we can set default values (e.g. for HTTP headers)
        Class.new(superclass || Object) do
          include Action unless self < Action

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

          axn.messages(**messages) if messages.present?

          # Hooks
          axn.before(before) if before.present?
          axn.after(after) if after.present?
          axn.around(around) if around.present?

          # Rollback
          if rollback.present?
            raise ArgumentError, "Rollback must be a callable" unless rollback.respond_to?(:call) && rollback.respond_to?(:arity)
            raise ArgumentError, "Rollback must be a callable with no arguments" unless rollback.arity.zero?

            axn.define_method(:rollback) do
              instance_exec(&rollback)
            end
          end

          # Default value exposure
          axn.exposes(:value, allow_blank: true) if exposes.blank?
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity, Metrics/ParameterLists

      private

      def _hash_with_default_array = Hash.new { |h, k| h[k] = [] }

      def _hydrate_hash(given)
        return given if given.is_a?(Hash)

        Array(given).each_with_object({}) do |key, acc|
          acc[key] = {}
        end
      end
    end
  end
end
