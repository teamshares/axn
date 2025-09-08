# frozen_string_literal: true

module Axn
  class Factory
    class << self
      # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity, Metrics/ParameterLists
      def build(
        callable = nil,
        # Builder-specific options
        name: nil,
        superclass: nil,
        expose_return_as: :nil,

        # Expose standard class-level options
        exposes: [],
        expects: [],
        success: nil,
        error: nil,

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
        raise ArgumentError, "[Axn::Factory] Cannot receive both a callable and a block" if callable.present? && block_given?

        executable = callable || block
        raise ArgumentError, "[Axn::Factory] Must provide either a callable or a block" unless executable

        args = executable.parameters.each_with_object(_hash_with_default_array) { |(type, field), hash| hash[type] << field }

        if args[:opt].present? || args[:req].present? || args[:rest].present?
          raise ArgumentError,
                "[Axn::Factory] Cannot convert callable to action: callable expects positional arguments"
        end
        raise ArgumentError, "[Axn::Factory] Cannot convert callable to action: callable expects a splat of keyword arguments" if args[:keyrest].present?

        if args[:key].present?
          raise ArgumentError,
                "[Axn::Factory] Cannot convert callable to action: callable expects keyword arguments with defaults (ruby does not allow introspecting)"
        end

        expects = _hydrate_hash(expects)
        exposes = _hydrate_hash(exposes)

        Array(args[:keyreq]).each do |field|
          expects[field] ||= {}
        end

        # NOTE: inheriting from wrapping class, so we can set default values (e.g. for HTTP headers)
        Class.new(superclass || Object) do
          include Axn unless self < Axn

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

            retval = instance_exec(**unwrapped_kwargs, &executable)
            expose(expose_return_as => retval) if expose_return_as.present?
          end
        end.tap do |axn|
          expects.each do |field, opts|
            axn.expects(field, **opts)
          end

          exposes.each do |field, opts|
            axn.exposes(field, **opts)
          end

          # Apply success and error handlers
          _apply_handlers(axn, :success, success, Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor)
          _apply_handlers(axn, :error, error, Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor)

          # Hooks
          axn.before(before) if before.present?
          axn.after(after) if after.present?
          axn.around(around) if around.present?

          # Callbacks
          _apply_handlers(axn, :on_success, on_success, Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor)
          _apply_handlers(axn, :on_failure, on_failure, Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor)
          _apply_handlers(axn, :on_error, on_error, Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor)
          _apply_handlers(axn, :on_exception, on_exception, Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor)

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

      def _apply_handlers(axn, method_name, value, _descriptor_class)
        return unless value.present?

        # Check if the value itself is a hash (this catches the case where someone passes a hash literal)
        raise Axn::UnsupportedArgument, "Cannot pass hash directly to #{method_name} - use descriptor objects for kwargs" if value.is_a?(Hash)

        # Wrap in Array() to handle both single values and arrays
        Array(value).each do |handler|
          raise Axn::UnsupportedArgument, "Cannot pass hash directly to #{method_name} - use descriptor objects for kwargs" if handler.is_a?(Hash)

          # Both descriptor objects and simple cases (string/proc) can be used directly
          axn.public_send(method_name, handler)
        end
      end
    end
  end
end
