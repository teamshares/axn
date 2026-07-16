# frozen_string_literal: true

module Axn
  class Factory
    NOT_PROVIDED = :__not_provided__

    class << self
      # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity, Metrics/ParameterLists
      def build(
        callable = nil,
        # Builder-specific options
        superclass: nil,
        expose_return_as: nil,

        # Module inclusion options
        include: [],
        extend: [],
        prepend: [],

        # Expose standard class-level options
        exposes: [],
        expects: [],
        success: nil,
        error: nil,

        # Naming and metadata
        axn_name: nil,
        description: NOT_PROVIDED,
        semantic_hints: nil,

        # Failure reclassification
        fails_on: nil,

        # Observability facets (single spec or list of specs)
        tag: nil,
        dimension: nil,

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

        # Async configuration
        async: nil,

        # Logging configuration
        auto_log: NOT_PROVIDED,

        # Internal flag to prevent recursion during action class creation
        # Tracks which target class is having an action class created for it
        _creating_action_class_for: nil,

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
        _build_axn_class(superclass:, args:, executable:, expose_return_as:, include:, extend:, prepend:, _creating_action_class_for:).tap do |axn|
          expects.each do |field, opts|
            axn.expects(field, **opts)
          end

          exposes.each do |field, opts|
            axn.exposes(field, **opts)
          end

          # Naming and metadata
          axn.axn_name(axn_name) unless axn_name.nil?
          # Write the backing attribute directly rather than calling `axn.description(...)`: the
          # `description` DSL is only extended onto axn when no non-Axn ancestor already defines
          # `description` (PRO-2875), so a `axn.description(...)` call would hit the ancestor's
          # setter when building on a base class (e.g. a tool base) that defines its own.
          #
          # NOT_PROVIDED (not nil) is the omission sentinel: `_axn_description` is an inherited
          # class_attribute, so a nil default would be indistinguishable from an explicit
          # `description: nil`. A caller building on a superclass with an inherited description needs
          # `description: nil` to CLEAR it (else the subclass republishes stale provider text), so an
          # explicit nil must write through while a truly-omitted arg leaves the inherited value.
          axn._axn_description = description unless description == NOT_PROVIDED
          axn.semantic_hints(*Array(semantic_hints)) unless semantic_hints.nil?

          # Observability facets (fan out a single spec or a list)
          _apply_facets(axn, :tag, tag)
          _apply_facets(axn, :dimension, dimension)

          # Apply logging configuration (always apply if provided to override defaults).
          # A Hash forwards as per-outcome keywords (auto_log success: :info, ...); anything else
          # is the positional level (auto_log :warn / auto_log false).
          unless auto_log == NOT_PROVIDED
            auto_log.is_a?(Hash) ? axn.auto_log(**auto_log) : axn.auto_log(auto_log)
          end

          # Apply success and error handlers
          _apply_handlers(axn, :success, success, Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor)
          _apply_handlers(axn, :error, error, Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor)

          # Failure reclassification — applied AFTER the error handlers on purpose. `fails_on Klass, "msg"`
          # wires a conditional `error` message; the message registry is last-defined-wins, and among
          # competing REASONS the most-recently-declared matches first. Mirroring the conventional
          # hand-written order (`error ...` then `fails_on ...`), the fan-out runs here so a
          # reclassification message out-specifies an `error:` reason that also matches the exception,
          # rather than being shadowed by it.
          _apply_fails_on(axn, fails_on)

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

          # Async configuration
          unless async.nil?
            async_array = Array(async)
            # Skip async configuration if adapter is nil (but not if array is empty)
            if !async_array.empty? && async_array[0].nil?
              # Do nothing - skip async configuration
            else
              _apply_async_config(axn, async_array)
            end
          end

          # Default exposure
          axn.exposes(expose_return_as, optional: true) if expose_return_as.present?
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity, Metrics/ParameterLists

      private

      def _hash_with_default_array = Hash.new { |h, k| h[k] = [] }

      def _hydrate_hash(given) = Axn::FieldDeclarations.hydrate(given)

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

      # `fails_on` accumulates across calls, so a builder value fans out into one call per spec.
      # A bare Class (or Array<Class>) is one matcher; an Array is a LIST of specs. Within a spec:
      # all-Classes means one matcher over all of them (the `exceptions` arg is itself an array),
      # otherwise the spec is [exceptions, message] with a trailing Hash forwarded as kwargs.
      #   fails_on: MyError                                 -> one matcher
      #   fails_on: [A, B]                                  -> two matchers (one class each)
      #   fails_on: [[A, B]]                                -> one matcher covering both
      #   fails_on: [[A, "msg", { standalone: true }]]      -> fails_on(A, "msg", standalone: true)
      #   fails_on: [[[A, B], "msg"]]                       -> fails_on([A, B], "msg")
      def _apply_fails_on(axn, value)
        return if value.nil?

        specs = value.is_a?(Array) ? value : [value]
        specs.each { |spec| _apply_one_fails_on(axn, spec) }
      end

      def _apply_one_fails_on(axn, spec)
        return axn.fails_on(spec) if spec.is_a?(Class)
        raise ArgumentError, "[Axn::Factory] Invalid fails_on spec: #{spec.inspect}" unless spec.is_a?(Array)

        parts = spec.dup
        kwargs = parts.last.is_a?(Hash) ? parts.pop : {}
        if parts.all? { |p| p.is_a?(Class) }
          axn.fails_on(parts, **kwargs)
        else
          # A non-all-classes spec is [exceptions, message]. More than two positional parts is a
          # malformed spec (e.g. `[TimeoutError, "retry", :extra]`): destructuring would silently drop
          # the extras, whereas the equivalent direct `fails_on(TimeoutError, "retry", :extra)` raises.
          # Fail at declaration rather than mask the typo.
          raise ArgumentError, "[Axn::Factory] Invalid fails_on spec (expected [exceptions, message?]): #{spec.inspect}" if parts.size > 2

          exceptions, message = parts
          axn.fails_on(exceptions, message, **kwargs)
        end
      end

      # The only keyword option the `tag`/`dimension` DSL accepts. A trailing Hash in a facet spec is
      # forwarded as kwargs ONLY when it looks like these options; otherwise it is a positional resolver.
      FACET_KWARG_KEYS = %i[from].freeze

      # `tag`/`dimension` accumulate one facet per call. A value whose first element is itself an
      # Array is a LIST of specs; otherwise the value is a single spec. Each spec is [name, resolver]
      # (or [name, resolver, { from: … }]). Names are never arrays, so first-element-is-Array
      # unambiguously distinguishes a list from a single spec.
      #   tag: [:region, "us5"]                     -> tag(:region, "us5")
      #   tag: [:charged, "yes", { from: :result }] -> tag(:charged, "yes", from: :result)
      #   tag: [:payload, { kind: "a" }]            -> tag(:payload, { kind: "a" })  # Hash resolver
      #   tag: [[:a, 1], [:b, 2]]                   -> tag(:a, 1); tag(:b, 2)
      def _apply_facets(axn, method_name, value)
        return if value.nil?

        specs = value.is_a?(Array) && value.first.is_a?(Array) ? value : [value]
        specs.each do |spec|
          raise ArgumentError, "[Axn::Factory] Invalid #{method_name} spec: #{spec.inspect}" unless spec.is_a?(Array)

          parts = spec.dup
          # A trailing Hash is only `from:` kwargs when every key is a supported kwarg; otherwise it is a
          # literal Hash RESOLVER value (the DSL accepts `tag(:name, { … })`), forwarded positionally to
          # stay at parity. (An empty Hash is a resolver too — `**{}` would drop it.) The narrow
          # unexpressible case — a resolver Hash whose only key is `:from` — needs the DSL's brace syntax,
          # which a flat data spec can't carry.
          kwargs = {}
          kwargs = parts.pop if _facet_kwargs?(parts.last)
          axn.public_send(method_name, *parts, **kwargs)
        end
      end

      def _facet_kwargs?(candidate)
        candidate.is_a?(Hash) && !candidate.empty? && (candidate.keys - FACET_KWARG_KEYS).empty?
      end

      def _build_axn_class(superclass:, args:, executable:, expose_return_as:, include: nil, extend: nil, prepend: nil, _creating_action_class_for: nil) # rubocop:disable Lint/UnderscorePrefixedVariableName
        # Mark superclass if we're creating an action class (for recursion prevention)
        # Track which target class is having an action created for it
        superclass.instance_variable_set(:@_axn_creating_action_class_for, _creating_action_class_for) if _creating_action_class_for && superclass

        Class.new(superclass || Object) do
          include Axn unless self < Axn

          Array(include).each { |mod| include mod }
          Array(extend).each { |mod| extend mod }
          Array(prepend).each { |mod| prepend mod }

          # Set a default name for anonymous classes to help with debugging
          define_singleton_method(:name) do
            "AnonymousAxn_#{object_id}"
          end

          define_method(:call) do
            unwrapped_kwargs = Array(args[:keyreq]).each_with_object({}) do |field, hash|
              hash[field] = public_send(field)
            end

            retval = instance_exec(**unwrapped_kwargs, &executable)
            expose(expose_return_as => retval) if expose_return_as.present?
          end
        end
      ensure
        superclass.instance_variable_set(:@_axn_creating_action_class_for, nil) if _creating_action_class_for && superclass
      end

      def _apply_async_config(axn, async)
        raise ArgumentError, "[Axn::Factory] Invalid async configuration" unless _validate_async_config(async)

        adapter, *config_args = async

        # Determine hash config and callable config
        config = config_args.find { |arg| arg.is_a?(Hash) }
        block = config_args.find { |arg| arg.respond_to?(:call) }

        # Call async once with the determined values
        axn.async(adapter, **(config || {}), &block)
      end

      def _validate_async_config(async_array)
        return false unless async_array.length.between?(1, 3)

        adapter = async_array[0]
        second_arg = async_array[1]
        third_arg = async_array[2]

        # First arg must be adapter (symbol/string), false, or nil
        return false unless adapter.is_a?(Symbol) || adapter.is_a?(String) || adapter == false || adapter.nil?

        case async_array.length
        when 1
          # Pattern A: [:sidekiq], [false], or [nil]
          true
        when 2
          # Pattern B: [:sidekiq, hash_or_callable] or [nil, hash_or_callable]
          second_arg.is_a?(Hash) || second_arg.respond_to?(:call)
        when 3
          # Pattern C: [:sidekiq, hash, callable] or [nil, hash, callable]
          second_arg.is_a?(Hash) && third_arg.respond_to?(:call)
        else
          false
        end
      end
    end
  end
end
