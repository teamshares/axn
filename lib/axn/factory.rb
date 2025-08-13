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
        success: nil,
        error: nil,
        error_from: {},

        # Hooks
        before: nil,
        after: nil,
        around: nil,

        # Callbacks
        on_success: nil,
        on_failure: nil,
        on_error: nil,
        on_exception: nil,

        # Strategies
        use: [],

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

          axn.success(success) if success.present?
          axn.error(error) if error.present?

          axn.error_from(**_array_to_hash(error_from)) if error_from.present?

          # Hooks
          axn.before(before) if before.present?
          axn.after(after) if after.present?
          axn.around(around) if around.present?

          # Callbacks
          axn.on_success(&on_success) if on_success.present?
          axn.on_failure(&on_failure) if on_failure.present?
          axn.on_error(&on_error) if on_error.present?
          axn.on_exception(&on_exception) if on_exception.present?

          # Strategies
          Array(use).each do |strategy|
            if strategy.is_a?(Array)
              strategy_name, *config_args = strategy
              if config_args.last.is_a?(Hash)
                *other_args, config = config_args
                axn.use(strategy_name, *other_args, **config)
              else
                axn.use(strategy_name, *config_args)
              end
            else
              axn.use(strategy)
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
