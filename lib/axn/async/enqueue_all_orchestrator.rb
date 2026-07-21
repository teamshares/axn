# frozen_string_literal: true

module Axn
  module Async
    # Custom error for missing enqueues_each configuration
    class MissingEnqueuesEachError < StandardError; end

    # Shared trigger action for executing batch enqueueing in the background.
    # Called by enqueue_all to iterate over configured fields asynchronously.
    #
    # Configure the async adapter via Axn.config.set_enqueue_all_async,
    # or it defaults to Axn.config.set_default_async.
    #
    # @example Configure a specific queue for all enqueue_all jobs
    #   Axn.configure do |c|
    #     c.set_enqueue_all_async(:sidekiq, queue: :batch)
    #   end
    class EnqueueAllOrchestrator
      include Axn

      # Disable automatic before/after logging - we log the count manually
      auto_log false

      expects :target_class_name
      expects :static_args, default: {}, allow_blank: true

      def call
        target = target_class_name.constantize

        deserialized_static_args = Axn::Internal::AsyncSerialization.restore_nested_payload(static_args)

        count = self.class.execute_iteration(
          target,
          **deserialized_static_args,
          on_progress: method(:set_execution_context),
        )

        message_parts = ["Batch enqueued #{count} jobs for #{target.name}"]
        message_parts << "with explicit args: #{static_args.inspect}" if static_args.any?

        Axn::Internal::CallLogger.log_at_level(
          self.class,
          level: :info,
          message_parts:,
          error_context: "logging batch enqueue completion",
        )
      end

      class << self
        # Entry point for enqueue_all - validates upfront, then executes async
        #
        # @param target [Class] The action class to batch enqueue
        # @param static_args [Hash] Static arguments passed to each job
        # @return [String] Job ID from the async adapter
        def enqueue_for(target, **static_args)
          validate_async_configured!(target)

          # Handle no-expects case: just call_async directly
          return target.call_async(**static_args) if target.internal_field_configs.empty?

          # Get configs and resolved static args
          # Kwargs are split: scalars → resolved_static, enumerables → configs
          configs, resolved_static = resolve_configs(target, static_args:)

          # Validate static args upfront (raises ArgumentError if missing)
          validate_static_args!(target, configs, resolved_static) if configs.any?

          # Check if any configs came from kwargs (these have lambdas that can't be serialized)
          # If so, we must execute iteration synchronously
          has_kwarg_iteration = configs.any? { |c| c.from.is_a?(Proc) && static_args.key?(c.field) }

          if has_kwarg_iteration
            # Execute iteration synchronously - kwargs with iterables can't be serialized
            kwarg_fields = configs.select { |c| c.from.is_a?(Proc) && static_args.key?(c.field) }.map(&:field)
            info "[enqueue_all] Running in foreground: kwargs #{kwarg_fields.join(', ')} cannot be serialized for background execution"
            execute_iteration_without_logging(target, **static_args)
          else
            # static_args ride nested inside this job's own payload; see AsyncSerialization#prepare_nested_payload.
            static_args_payload = Axn::Internal::AsyncSerialization.prepare_nested_payload(resolved_static)
            call_async(target_class_name: target.name, static_args: static_args_payload)
          end
        end

        # Execute the actual iteration (called from #call in background)
        # Returns the count of jobs enqueued
        #
        # @param target [Class] The action class to enqueue jobs for
        # @param on_progress [Proc, nil] Callback to track iteration progress for logging context
        # @param static_args [Hash] Static arguments to pass to each job
        def execute_iteration(target, on_progress: nil, **static_args)
          configs, resolved_static = resolve_configs(target, static_args:)
          count = { value: 0 }
          iterate(target:, configs:, index: 0, accumulated: {}, static_args: resolved_static, count:, on_progress:)
          fire_enqueue_all_callbacks(target:, configs:, count: count[:value])
          count[:value]
        end

        # Execute iteration with per-job async logging suppressed (for foreground execution)
        def execute_iteration_without_logging(target, **static_args)
          original_levels = target._auto_log_levels
          target._auto_log_levels = Core::AutomaticLogging::OUTCOMES.each_with_object({}) { |outcome, h| h[outcome] = nil }.freeze
          execute_iteration(target, **static_args)
        ensure
          target._auto_log_levels = original_levels
        end

        private

        # Fire any registered on_enqueue_all callbacks once, after the fan-out completes.
        # Callbacks live in the shared callbacks registry (event_type :enqueue_all), so they
        # reuse the on_* family's registration, validation, if:/unless: matching, and
        # last-defined-wins ordering. Execution stays bespoke here because the shared Invoker
        # is exception-shaped and cannot carry the sources:/count: payload.
        #
        # Resolves the per-field sources hash only when an applicable callback exists, so
        # actions without the hook (or whose if:/unless: all fail) pay no extra source resolution.
        def fire_enqueue_all_callbacks(target:, configs:, count:)
          # NOTE: matchers (if:/unless:) are exception-shaped; pass exception: nil. They can
          # condition on class-level state but cannot observe sources/count.
          descriptors = target._callbacks_registry.for(:enqueue_all).select { |d| d.matches?(action: target, exception: nil) }
          return if descriptors.empty?

          # Lazy + memoized: resolve the sources hash only when a callback actually requests
          # `sources:` (count-only callbacks skip it entirely), and only once across callbacks.
          # The thunk is invoked INSIDE invoke_enqueue_all_callback's rescue so a failed second
          # resolution (non-repeatable source / transient DB or API error) is swallowed like any
          # other hook error — it must never propagate out of execute_iteration after the fan-out
          # has already enqueued, which would fail the orchestrator and retry/duplicate the batch.
          #
          # NOTE: deliberately re-resolves each source (a second, un-materialized resolution
          # distinct from iterate's). Keep it un-materialized — do not cache iterate's source
          # here, or the hook would force materialization and break the relation contract.
          sources = nil
          resolve_sources = lambda do
            sources ||= configs.each_with_object({}) do |config, hash|
              hash[config.field] = config.resolve_source(target:)
            end
          end

          descriptors.each { |descriptor| invoke_enqueue_all_callback(target:, handler: descriptor.handler, resolve_sources:, count:) }
        end

        # Invoke a single callback handler in the target class context with arity-filtered
        # kwargs. A Symbol handler resolves to a class method on the target; a callable is
        # instance_exec'd on the class. The sources hash is resolved (via resolve_sources) only
        # if the handler requests it. A raise — from the handler OR from resolving sources — is
        # swallowed (mirrors on_success / filter_block) so the fan-out is never aborted.
        def invoke_enqueue_all_callback(target:, handler:, resolve_sources:, count:)
          Axn::Extensions.best_effort("on_enqueue_all callback for #{target.name}") do
            if handler.is_a?(Symbol)
              unless target.respond_to?(handler, true)
                target.warn("Ignoring apparently-invalid on_enqueue_all symbol #{handler.inspect} -- class does not respond to method")
                return
              end
              callable = target.method(handler)
            else
              callable = handler
            end

            available = { count: }
            available[:sources] = resolve_sources.call if requests_param?(callable, :sources)
            args, kwargs = Axn::Internal::Callable.only_requested_params(callable, kwargs: available)

            if handler.is_a?(Symbol)
              target.send(handler, *args, **kwargs)
            else
              target.instance_exec(*args, **kwargs, &handler)
            end
          end
        end

        # Whether a callable accepts a given keyword (directly or via **kwargs / keyrest).
        def requests_param?(callable, name)
          callable.parameters.any? do |type, param_name|
            type == :keyrest || (%i[key keyreq].include?(type) && param_name == name)
          end
        end

        # Builds iteration sources and resolves static args from kwargs
        #
        # Returns [configs, resolved_static_args] where:
        # - configs: Array of Config objects for fields to iterate
        # - resolved_static_args: Hash of field => value for static (non-iterated) fields
        #
        # Kwargs handling:
        # - Scalar values → static args (override any inferred/explicit config)
        # - Enumerable values → iteration source (replaces inferred/explicit config source)
        #   Exception: if field expects enumerable type (Array, etc), treat as scalar
        def resolve_configs(target, static_args: {})
          explicit_configs = target._batch_enqueue_configs
          explicit_fields = explicit_configs.map(&:field)

          resolved_static = {}
          kwarg_configs = []

          # Process kwargs: separate into static vs iterable
          static_args.each do |field, value|
            field_config = target.internal_field_configs.find { |c| c.field == field }

            if should_iterate?(value, field_config)
              # Enumerable kwarg → create a config to iterate over it
              kwarg_configs << BatchEnqueue::Config.new(
                field:,
                from: -> { value },
                via: nil,
                filter_block: nil,
              )
            else
              # Scalar kwarg → static arg
              resolved_static[field] = value
            end
          end

          # Fields covered by scalar kwargs shouldn't be iterated
          scalar_fields = resolved_static.keys
          iterable_kwarg_fields = kwarg_configs.map(&:field)

          # Filter explicit configs: remove fields that are given as scalars
          # but keep fields that are given as iterables (kwarg will override the source)
          filtered_explicit = explicit_configs.reject { |c| scalar_fields.include?(c.field) }

          # For explicit configs with matching kwarg iterables, the kwarg takes precedence
          filtered_explicit = filtered_explicit.reject { |c| iterable_kwarg_fields.include?(c.field) }

          # Infer configs for model: fields not already covered
          exclude_from_inference = explicit_fields + scalar_fields + iterable_kwarg_fields
          inferred = infer_configs_from_models(target, exclude: exclude_from_inference)

          # Merge: inferred first (as defaults), then explicit (as overrides), then kwarg configs (as final overrides)
          merged = inferred + filtered_explicit + kwarg_configs

          # Sort for memory efficiency: model-based configs (using find_each) should be processed first
          # to minimize memory usage in nested iterations
          merged.sort_by! { |config| model_based_config?(config, target) ? 0 : 1 }

          return [merged, resolved_static] if merged.any?

          # No configs at all - error only if there are required fields not covered by static args
          uncovered_fields = target.internal_field_configs.map(&:field) - resolved_static.keys
          uncovered_required = uncovered_fields.reject do |field|
            field_config = target.internal_field_configs.find { |c| c.field == field }
            field_config&.default.present? || field_config&.validations&.dig(:allow_blank)
          end

          return [[], resolved_static] if uncovered_required.empty?

          raise MissingEnqueuesEachError,
                "#{target.name} has required fields (#{uncovered_required.join(', ')}) " \
                "not covered by enqueues_each, model: declarations, or static args. " \
                "Add `enqueues_each :field_name, from: -> { ... }` for fields to iterate, " \
                "use `expects :field, model: SomeModel` where SomeModel responds to find_each, " \
                "or pass the field as a static argument to enqueue_all."
        end

        # Infer configs from fields with model: declarations whose model responds to find_each
        def infer_configs_from_models(target, exclude: [])
          target.internal_field_configs.filter_map do |field_config|
            next if exclude.include?(field_config.field)

            model_config = field_config.validations&.dig(:model)
            next unless model_config

            model_class = model_config[:klass]
            next unless model_class.respond_to?(:find_each)

            # Create an inferred config (equivalent to `enqueues_each :field`)
            BatchEnqueue::Config.new(field: field_config.field, from: nil, via: nil, filter_block: nil)
          end
        end

        # Checks if a config is model-based (will use find_each for memory-efficient iteration)
        def model_based_config?(config, target)
          # Configs with nil 'from' are inferred from model declarations
          return true if config.from.nil?

          # For explicit configs, check if the field has a model declaration that supports find_each
          field_config = target.internal_field_configs.find { |c| c.field == config.field }
          model_config = field_config&.validations&.dig(:model)
          return true if model_config && model_config[:klass].respond_to?(:find_each)

          false
        end

        def validate_async_configured!(target)
          # Set up default async configuration if none is set. Routes through the shared helper
          # (rather than calling target.async directly) so it sets _async_via_default — otherwise a
          # defaulted action would build a per-action Worker subclass that a fresh Sidekiq worker
          # can't reconstruct (the action body never re-runs `async`). Self-guards on adapter presence.
          target.send(:_ensure_default_async_configured)

          return if target._async_adapter.present? && target._async_adapter != false

          raise NotImplementedError,
                "#{target.name} does not have async configured. " \
                "Add `async :sidekiq` or `async :active_job` to enable enqueue_all."
        end

        def validate_static_args!(target, configs, static_args)
          enqueue_each_fields = configs.map(&:field)
          all_expected_fields = target.internal_field_configs.map(&:field)
          static_fields = all_expected_fields - enqueue_each_fields

          # Check for required static fields (those without defaults and not optional)
          required_static = static_fields.reject do |field|
            field_config = target.internal_field_configs.find { |c| c.field == field }
            next true if field_config&.default.present?
            next true if field_config&.validations&.dig(:allow_blank)

            false
          end

          missing = required_static - static_args.keys
          return unless missing.any?

          raise ArgumentError,
                "Missing required static field(s): #{missing.join(', ')}. " \
                "These fields are not covered by enqueues_each and must be provided."
        end

        def iterate(target:, configs:, index:, accumulated:, static_args:, count:, on_progress:)
          # Base case: all fields accumulated, enqueue the job
          if index >= configs.length
            on_progress&.call(stage: :enqueueing, enqueue_args: accumulated.merge(static_args))
            target.call_async(**accumulated, **static_args)
            count[:value] += 1
            return
          end

          config = configs[index]

          # Track which field's source we're resolving
          on_progress&.call(stage: :resolving_source, field: config.field)
          source = config.resolve_source(target:)

          # Use find_each if available (ActiveRecord), otherwise each
          iterator = source.respond_to?(:find_each) ? :find_each : :each

          source.public_send(iterator) do |item|
            # Track current item being processed
            item_id = item.try(:id) || item.to_s.truncate(100)
            on_progress&.call(stage: :iterating, field: config.field, current_item_id: item_id)

            # Apply filter block if present - swallow errors, skip item
            if config.filter_block
              filter_result = Axn::Extensions.best_effort("filter block for :#{config.field}") do
                config.filter_block.call(item)
              end
              next unless filter_result
            end

            # Apply via extraction if present - swallow errors, skip item
            value = if config.via
                      begin
                        item.public_send(config.via)
                      rescue StandardError => e
                        Axn::Extensions.best_effort("via extraction (:#{config.via}) for :#{config.field}") { raise e }
                        next
                      end
                    else
                      item
                    end

            # Recurse to next field
            iterate(
              target:,
              configs:,
              index: index + 1,
              accumulated: accumulated.merge(config.field => value),
              static_args:,
              count:,
              on_progress:,
            )
          end
        end

        # Determines if a kwarg value should be iterated over or used as static
        #
        # @param value [Object] The value passed in kwargs
        # @param field_config [Object, nil] The field's config from internal_field_configs
        # @return [Boolean] true if we should iterate over the value
        def should_iterate?(value, field_config)
          return false unless value.respond_to?(:each)
          return false if value.is_a?(String) || value.is_a?(Hash)
          return false if field_expects_enumerable?(field_config)

          true
        end

        # Checks if a field expects an enumerable type (Array, Set, etc)
        #
        # @param field_config [Object, nil] The field's config from internal_field_configs
        # @return [Boolean] true if the field expects an enumerable
        def field_expects_enumerable?(field_config)
          return false unless field_config

          type_config = field_config.validations&.dig(:type)
          return false unless type_config

          # type: Array becomes { klass: Array } after syntactic sugar
          expected_type = type_config[:klass]
          return false unless expected_type

          # Handle array of types (e.g., type: [Array, Hash])
          Array(expected_type).any? do |type|
            next false unless type.is_a?(Class)

            ENUMERABLE_TYPES.any? { |enum_type| type <= enum_type }
          end
        rescue TypeError
          # expected_type might be a Symbol or something that doesn't support <=
          false
        end

        # Types that are considered enumerable for the purposes of iteration detection
        ENUMERABLE_TYPES = [Array, Set].freeze
      end
    end
  end
end
