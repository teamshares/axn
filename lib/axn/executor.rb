# frozen_string_literal: true

require "securerandom"

module Axn
  # Executor encapsulates the full execution pipeline for an action.
  # It owns all the wrapper logic that was previously spread across instance methods,
  # reducing the number of methods injected into user classes.
  #
  # The execution pipeline has two zones separated by the exception boundary:
  #
  # **Outside zone** (result settled, must not raise):
  # - nesting_tracking: manages the axn stack
  # - tracing: reads result.outcome, result.elapsed_time, result.exception
  # - logging: reads result.ok?, result.outcome, result.elapsed_time
  #
  # **Boundary:**
  # - exception_handling: catches exceptions, sets result state, dispatches callbacks
  #
  # **Inside zone** (can raise fail!/done!):
  # - timing: sets elapsed_time via ensure
  # - contract: validates inputs/outputs, applies defaults/preprocessing
  # - hooks: user before/after/around hooks
  class Executor # rubocop:disable Metrics/ClassLength
    def initialize(action)
      @action = action
      @action_class = action.class
      @context = action.instance_variable_get(:@__context)
    end

    def run
      Axn::Core::NestingTracking.tracking(@action) do
        with_tracing do
          with_logging do
            with_timing do
              with_exception_handling do
                with_contract do
                  with_hooks do
                    @action.call
                  end
                end
              end
            end
          end
        end
      end
    end

    private

    # =========================================================================
    # TRACING (Outside zone - result is settled)
    # =========================================================================

    def with_tracing(&)
      resource = @action_class.name || "AnonymousClass"
      payload = { resource:, action: @action }

      update_payload = proc do
        result = @action.result
        outcome = result.outcome.to_s
        payload[:outcome] = outcome
        payload[:result] = result
        payload[:elapsed_time] = result.elapsed_time
        payload[:exception] = result.exception if result.exception
      rescue StandardError => e
        Internal::Logging.piping_error("updating notification payload while tracing axn.call", action: @action, exception: e)
      end

      instrument_block = proc do
        ActiveSupport::Notifications.instrument("axn.call", payload, &)
      ensure
        update_payload.call
      end

      if defined?(OpenTelemetry)
        in_span_kwargs = { attributes: { "axn.resource" => resource } }
        in_span_kwargs[:record_exception] = false if Axn::Core::Tracing._supports_record_exception_option?

        Axn::Core::Tracing.tracer.in_span("axn.call", **in_span_kwargs) do |span|
          instrument_block.call
        ensure
          begin
            result = @action.result
            outcome = result.outcome.to_s
            span.set_attribute("axn.outcome", outcome)

            if %w[failure exception].include?(outcome) && result.exception
              span.record_exception(result.exception)
              error_message = result.exception.message || result.exception.class.name
              span.status = OpenTelemetry::Trace::Status.error(error_message)
            end
          rescue StandardError => e
            Internal::Logging.piping_error("updating OTel span while tracing axn.call", action: @action, exception: e)
          end
        end
      else
        instrument_block.call
      end
    ensure
      begin
        emit_metrics_proc = Axn.config.emit_metrics
        if emit_metrics_proc
          result = @action.result
          Internal::Callable.call_with_desired_shape(emit_metrics_proc, kwargs: { resource:, result: })
        end
      rescue StandardError => e
        Internal::Logging.piping_error("calling emit_metrics while tracing axn.call", action: @action, exception: e)
      end
    end

    # =========================================================================
    # LOGGING (Outside zone - result is settled)
    # =========================================================================

    def with_logging
      log_before if @action_class.log_calls_level
      yield
    ensure
      log_after if @action_class.log_calls_level || @action_class.log_errors_level
    end

    def log_before
      Internal::LogFormatting.log_at_level(
        @action_class,
        level: @action_class.log_calls_level,
        message_parts: ["About to execute"],
        join_string: " with: ",
        before: top_level_separator,
        error_context: "logging before hook",
        context_direction: :inbound,
        context_instance: @action,
      )
    end

    def log_after
      if @action_class.log_calls_level
        log_after_at_level(@action_class.log_calls_level)
        return
      end

      return unless @action_class.log_errors_level && !@action.result.ok?

      log_after_at_level(@action_class.log_errors_level)
    end

    def log_after_at_level(level)
      Internal::LogFormatting.log_at_level(
        @action_class,
        level:,
        message_parts: [
          "Execution completed (with outcome: #{@action.result.outcome}) in #{@action.result.elapsed_time} milliseconds",
        ],
        join_string: ". Set: ",
        after: top_level_separator,
        error_context: "logging after hook",
        context_direction: :outbound,
        context_instance: @action,
      )
    end

    def top_level_separator
      return if Axn.config.env.production?
      return if Internal::ExecutionContext.background?
      return if Internal::ExecutionContext.console?
      return if Axn::Core::NestingTracking._current_axn_stack.size > 1

      "\n------\n"
    end

    # =========================================================================
    # TIMING (Inside zone - sets elapsed_time)
    # =========================================================================

    def with_timing
      timing_start = Axn::Core::Timing.now
      yield
    ensure
      elapsed_mils = Axn::Core::Timing.elapsed_ms(timing_start)
      @context.send(:elapsed_time=, elapsed_mils)
    end

    # =========================================================================
    # EXCEPTION HANDLING (Boundary)
    # =========================================================================

    def with_exception_handling
      yield
    rescue Internal::EarlyCompletion
      raise
    rescue StandardError => e
      @context.__record_exception(e)

      @action_class._dispatch_callbacks(:error, action: @action, exception: e)

      if e.is_a?(Failure)
        @action_class._dispatch_callbacks(:failure, action: @action, exception: e)
      else
        trigger_on_exception(e)
      end
    end

    def trigger_on_exception(exception)
      retry_context = Async::CurrentRetryContext.current if defined?(Async::CurrentRetryContext)
      if retry_context
        mode = @action_class.try(:_async_exception_reporting)
        return unless retry_context.should_trigger_on_exception?(mode)
      end

      @action_class._dispatch_callbacks(:exception, action: @action, exception:)

      context = Internal::GlobalExceptionReportingHelpers.build_exception_context(
        action: @action,
        retry_context:,
      )

      Axn.config.on_exception(exception, action: @action, context:)
    rescue StandardError => e
      Internal::Logging.piping_error("executing on_exception hooks", action: @action, exception: e)
    end

    # =========================================================================
    # CONTRACT (Inside zone)
    # =========================================================================

    def with_contract(&)
      return if handle_early_completion_if_raised { apply_inbound_preprocessing! }
      return if handle_early_completion_if_raised { apply_defaults!(:inbound) }

      validate_contract!(:inbound)

      if handle_early_completion_if_raised(&)
        apply_defaults!(:outbound)
        validate_contract!(:outbound)
        return
      end

      apply_defaults!(:outbound)
      validate_contract!(:outbound)

      @context.__finalize!
      trigger_on_success
    end

    def handle_early_completion_if_raised
      yield
      false
    rescue Internal::EarlyCompletion => e
      @context.__record_early_completion(e.message)
      trigger_on_success
      true
    end

    def apply_inbound_preprocessing!
      @action_class.send(:internal_field_configs).each do |config|
        next unless config.preprocess

        initial_value = @context.provided_data[config.field]
        @context.provided_data[config.field] = Internal::ContractErrorHandling.with_contract_error_handling(
          exception_class: ContractViolation::PreprocessingError,
          message: ->(field, error) { "Error preprocessing field '#{field}': #{error.message}" },
          field_identifier: config.field,
        ) do
          @action.instance_exec(initial_value, &config.preprocess)
        end
      end

      apply_inbound_preprocessing_for_subfields!
    end

    def apply_inbound_preprocessing_for_subfields!
      @action_class.send(:subfield_configs).each do |config|
        next unless config.preprocess

        parent_field = config.on
        subfield = config.field
        parent_value = @context.provided_data[parent_field]

        current_subfield_value = Axn::Core::FieldResolvers.resolve(type: :extract, field: subfield, provided_data: parent_value)
        preprocessed_value = Internal::ContractErrorHandling.with_contract_error_handling(
          exception_class: ContractViolation::PreprocessingError,
          message: ->(_field, error) { "Error preprocessing subfield '#{config.field}' on '#{config.on}': #{error.message}" },
          field_identifier: "#{config.field} on #{config.on}",
        ) do
          @action.instance_exec(current_subfield_value, &config.preprocess)
        end
        update_subfield_value(parent_field, subfield, preprocessed_value)
      end
    end

    def validate_contract!(direction)
      raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

      configs = direction == :inbound ? @action_class.send(:internal_field_configs) : @action_class.send(:external_field_configs)
      validations = configs.each_with_object({}) do |config, hash|
        hash[config.field] = config.validations
      end
      context = direction == :inbound ? @action.internal_context : @action.result
      exception_klass = direction == :inbound ? InboundValidationError : OutboundValidationError

      Axn::Validation::Fields.validate!(validations:, context:, exception_klass:)

      validate_subfields_contract! if direction == :inbound
    end

    def validate_subfields_contract!
      @action_class.send(:subfield_configs).each do |config|
        parent_field = config.on
        subfield = config.field

        Axn::Validation::Subfields.validate!(
          field: subfield,
          validations: config.validations,
          source: @action.public_send(parent_field),
          exception_klass: InboundValidationError,
          action: @action,
        )
      end
    end

    def apply_defaults!(direction)
      raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

      if direction == :outbound
        @action_class.send(:external_field_configs).each do |config|
          field = config.field
          next if @context.exposed_data.key?(field)

          @context.exposed_data[field] = @context.provided_data[field] if @context.provided_data.key?(field)
        end
      end

      configs = direction == :inbound ? @action_class.send(:internal_field_configs) : @action_class.send(:external_field_configs)
      defaults_mapping = configs.each_with_object({}) do |config, hash|
        hash[config.field] = config.default
      end.compact

      defaults_mapping.each do |field, default_value_getter|
        data_hash = direction == :inbound ? @context.provided_data : @context.exposed_data
        next if data_hash.key?(field) && !data_hash[field].nil?

        data_hash[field] = Internal::ContractErrorHandling.with_contract_error_handling(
          exception_class: ContractViolation::DefaultAssignmentError,
          message: ->(field_name, error) { "Error applying default for field '#{field_name}': #{error.message}" },
          field_identifier: field,
        ) do
          default_value_getter.respond_to?(:call) ? @action.instance_exec(&default_value_getter) : default_value_getter
        end
      end

      apply_defaults_for_subfields! if direction == :inbound
    end

    def apply_defaults_for_subfields!
      @action_class.send(:subfield_configs).each do |config|
        next unless config.default

        parent_field = config.on
        subfield = config.field
        parent_value = @context.provided_data[parent_field]

        next if parent_value && !Axn::Core::FieldResolvers.resolve(type: :extract, field: subfield, provided_data: parent_value).nil?

        @context.provided_data[parent_field] = {} if parent_value.nil?

        default_value = Internal::ContractErrorHandling.with_contract_error_handling(
          exception_class: ContractViolation::DefaultAssignmentError,
          message: ->(_field, error) { "Error applying default for subfield '#{config.field}' on '#{config.on}': #{error.message}" },
          field_identifier: "#{config.field} on #{config.on}",
        ) do
          config.default.respond_to?(:call) ? @action.instance_exec(&config.default) : config.default
        end
        update_subfield_value(parent_field, subfield, default_value)
      end
    end

    def trigger_on_success
      @action_class._dispatch_callbacks(:success, action: @action, exception: nil)
    end

    # =========================================================================
    # HOOKS (Inside zone)
    # =========================================================================

    def with_hooks
      respecting_early_completion do
        run_around_hooks do
          respecting_early_completion do
            run_before_hooks
            yield
            run_after_hooks
          end
        end
      end
    end

    def run_around_hooks(&block)
      @action_class.around_hooks.reverse.inject(block) do |chain, hook|
        proc { run_hook(hook, chain) }
      end.call
    end

    def run_before_hooks
      run_hooks(@action_class.before_hooks)
    end

    def run_after_hooks
      run_hooks(@action_class.after_hooks.reverse)
    end

    def run_hooks(hooks)
      hooks.each { |hook| run_hook(hook) }
    end

    def run_hook(hook, *)
      hook.is_a?(Symbol) ? @action.send(hook, *) : @action.instance_exec(*, &hook)
    end

    def respecting_early_completion
      yield
    rescue Internal::EarlyCompletion => e
      @context.__record_early_completion(e.message)
      raise e
    end

    # =========================================================================
    # SUBFIELD HELPERS
    # =========================================================================

    def update_subfield_value(parent_field, subfield, new_value)
      parent_value = @context.provided_data[parent_field]

      if Internal::SubfieldPath.nested?(subfield)
        update_nested_subfield_value(parent_field, subfield, new_value)
      elsif parent_value.is_a?(Hash)
        update_simple_hash_subfield(parent_field, subfield, new_value)
      elsif parent_value.respond_to?("#{subfield}=")
        Internal::SubfieldPath.update_object(parent_value, subfield, new_value)
      end
    end

    def update_simple_hash_subfield(parent_field, subfield, new_value)
      parent_value = @context.provided_data[parent_field].dup
      parent_value[subfield] = new_value
      @context.provided_data[parent_field] = parent_value
    end

    def update_nested_subfield_value(parent_field, subfield, new_value)
      parent_value = @context.provided_data[parent_field]
      path_parts = Internal::SubfieldPath.parse(subfield)

      target_parent = Internal::SubfieldPath.navigate_to_parent(parent_value, path_parts)
      target_parent[path_parts.last.to_sym] = new_value
    end
  end
end
