# frozen_string_literal: true

module Axn
  class Factory
    class << self
      # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity, Metrics/ParameterLists
      def build(
        # Builder-specific options
        name: nil,
        superclass: nil,
        expose_return_as: :nil,

        # Expose standard class-level options
        exposes: [],
        expects: [],
        messages: {},
        error_from: {},
        rescues: {},

        # Hooks
        before: nil,
        after: nil,
        around: nil,

        # Allow dynamically assigning rollback method
        rollback: nil,
        &block
      )
        args = block.parameters.each_with_object(_hash_with_default_array) { |(type, field), hash| hash[type] << field }

        if args[:opt].present? || args[:req].present? || args[:rest].present?
          raise ArgumentError,
                "[Axn::Factory] Cannot convert block to action: block expects positional arguments"
        end
        raise ArgumentError, "[Axn::Factory] Cannot convert block to action: block expects a splat of keyword arguments" if args[:keyrest].present?

        if args[:key].present?
          raise ArgumentError,
                "[Axn::Factory] Cannot convert block to action: block expects keyword arguments with defaults (ruby does not allow introspecting)"
        end

        expects = _hydrate_hash(expects)
        exposes = _hydrate_hash(exposes)

        Array(args[:keyreq]).each do |field|
          expects[field] ||= {}
        end

        # NOTE: inheriting from wrapping class, so we can set default values (e.g. for HTTP headers)
        Class.new(superclass || Object) do
          include Action unless self < Action

          define_singleton_method(:name) do
            [
              superclass&.name.presence || "AnonymousAction",
              name,
            ].compact.join("#")
          end

          define_method(:call) do
            unwrapped_kwargs = Array(args[:keyreq]).each_with_object({}) do |field, hash|
              hash[field] = public_send(field)
            end

            retval = instance_exec(**unwrapped_kwargs, &block)
            expose(expose_return_as => retval) if expose_return_as.present?
          end
        end.tap do |axn|
          expects.each do |field, opts|
            axn.expects(field, **opts)
          end

          exposes.each do |field, opts|
            axn.exposes(field, **opts)
          end

          axn.messages(**messages) if messages.present? && messages.values.any?(&:present?)

          axn.error_from(**_array_to_hash(error_from)) if error_from.present?
          axn.rescues(**_array_to_hash(rescues)) if rescues.present?

          # Hooks
          axn.before(before) if before.present?
          axn.after(after) if after.present?
          axn.around(around) if around.present?

          # Rollback
          if rollback.present?
            raise ArgumentError, "[Axn::Factory] Rollback must be a callable" unless rollback.respond_to?(:call) && rollback.respond_to?(:arity)
            raise ArgumentError, "[Axn::Factory] Rollback must be a callable with no arguments" unless rollback.arity.zero?

            axn.define_method(:rollback) do
              instance_exec(&rollback)
            end
          end

          # Default exposure
          axn.exposes(expose_return_as, allow_blank: true) if expose_return_as.present?
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity, Metrics/ParameterLists

      private

      def _hash_with_default_array = Hash.new { |h, k| h[k] = [] }

      def _array_to_hash(given)
        return given if given.is_a?(Hash)

        [given].to_h
      end

      def _hydrate_hash(given)
        return given if given.is_a?(Hash)

        Array(given).each_with_object({}) do |key, acc|
          if key.is_a?(Hash)
            key.each_key do |k|
              acc[k] = key[k]
            end
          else
            acc[key] = {}
          end
        end
      end
    end
  end
end
