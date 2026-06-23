# frozen_string_literal: true

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
      Core::NestingTracking.tracking(@action) do
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
        Internal::PipingError.swallow("updating notification payload while tracing axn.call", action: @action, exception: e)
      end

      instrument_block = proc do
        ActiveSupport::Notifications.instrument("axn.call", payload, &)
      ensure
        update_payload.call
      end

      if defined?(OpenTelemetry)
        in_span_kwargs = { attributes: { "axn.resource" => resource } }
        in_span_kwargs[:record_exception] = false if Internal::Tracing.supports_record_exception_option?

        Internal::Tracing.tracer.in_span("axn.call", **in_span_kwargs) do |span|
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
            Internal::PipingError.swallow("updating OTel span while tracing axn.call", action: @action, exception: e)
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
        Internal::PipingError.swallow("calling emit_metrics while tracing axn.call", action: @action, exception: e)
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
      Internal::CallLogger.log_at_level(
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
      Internal::CallLogger.log_at_level(
        @action_class,
        level:,
        message_parts: [
          "Execution completed (with outcome: #{@action.result.outcome}) in #{Internal::Timing.human_duration(@action.result.elapsed_time)}",
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
      return if Util::ExecutionContext.background?
      return if Util::ExecutionContext.console?
      return if Core::NestingTracking._current_axn_stack.size > 1

      "\n------\n"
    end

    # =========================================================================
    # TIMING (Inside zone - sets elapsed_time)
    # =========================================================================

    def with_timing
      timing_start = Internal::Timing.now
      yield
    ensure
      elapsed_mils = Internal::Timing.elapsed_ms(timing_start)
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
      begin
        apply_defaults!(:outbound)
      rescue StandardError => defaults_error
        Internal::PipingError.swallow("applying outbound defaults on failure", exception: defaults_error, action: @action)
      end

      @context.__record_exception(e)

      @action_class._dispatch_callbacks(:error, action: @action, exception: e)

      if e.is_a?(Failure) || @action_class._fails_on?(e) || Internal::ExceptionClassification.failure?(e) ||
         Axn::ValidationError.user_facing?(e)
        # Make a `fails_on` (or user-facing `expects ..., user_facing:`) classification sticky to this
        # exception object (per call tree), so it stays a failure (fires on_failure, no report) as it
        # propagates through ancestor `call!`s — mirroring how Axn::Failure is sticky via its class.
        # Also record it on this result's context so result.outcome reports `failure` after the
        # per-execution set is cleared.
        Internal::ExceptionClassification.mark_failure!(e) unless e.is_a?(Failure)
        @context.__classify_as_failure!
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

      # Per-action :exception callbacks fire at each level (an action may legitimately observe its
      # own failure), but the GLOBAL report is sent only once per exception. A nested `call!`
      # re-raises the same exception object up the stack; without this, each ancestor executor would
      # report it again — N duplicate Honeybadger notices for one bug.
      @action_class._dispatch_callbacks(:exception, action: @action, exception:)
      return if Internal::ExceptionClassification.reported?(exception)

      context = Internal::ExceptionContext.build(
        action: @action,
        retry_context:,
      )

      Axn.config.on_exception(exception, action: @action, context:)

      # Mark reported only AFTER the global report succeeds. If `build`/`on_exception` raises, the
      # rescue below swallows it WITHOUT marking — so an ancestor executor still attempts the report
      # rather than seeing `reported?` and dropping the exception entirely.
      Internal::ExceptionClassification.mark_reported!(exception)
    rescue StandardError => e
      Internal::PipingError.swallow("executing on_exception hooks", action: @action, exception: e)
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
      @context.__record_early_completion(e.message, prefixed: e.prefixed)
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

        parent_field = _wire_parent_key(config.on)
        subfield = config.field
        parent_value = @context.provided_data[parent_field]

        current_subfield_value = Core::FieldResolvers.resolve(type: :extract, field: subfield, provided_data: parent_value)
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

      if direction == :inbound
        _validate_inbound!(validations:, context:, configs:)
      else
        Axn::Validation::Fields.validate!(validations:, context:, exception_klass:)
      end
    end

    # Inbound validation has three sources — top-level fields, subfields, and model consistency.
    # Only top-level fields can opt into `user_facing:`; subfields and model consistency are always
    # dev-facing. To keep "dev-facing dominates a mixed failure" honest, we must not reclassify the
    # top-level failure until we know the later checks pass — otherwise a blank user-facing field
    # would short-circuit and mask a co-occurring dev-facing subfield/model violation.
    def _validate_inbound!(validations:, context:, configs:)
      fields_error = _capture_inbound_validation_error do
        Axn::Validation::Fields.validate!(validations:, context:, exception_klass: InboundValidationError)
      end

      if fields_error
        reclassified = _reclassified_user_facing_error(fields_error, configs)
        # A dev-facing top-level field already failed → it dominates now; preserve the original
        # behavior (raise immediately, later checks not consulted).
        raise fields_error if reclassified.equal?(fields_error)

        # Top-level failures are all user-facing — but an *independent* dev-facing subfield/model
        # violation still wins, so run those first and let any such error propagate unreclassified.
        # A subfield/model check that hangs off one of the *failed* user-facing parents is derived
        # from that failure (extraction against a broken parent), not independent — skip it so it
        # can't mask the parent's own user-facing message.
        failed_fields = fields_error.errors.map { |err| err.attribute.to_sym }.uniq
        validate_subfields_contract!(skip_parents: failed_fields)
        validate_model_consistency!(skip_fields: failed_fields)
        raise reclassified
      end

      validate_subfields_contract!
      validate_model_consistency!
    end

    def _capture_inbound_validation_error
      yield
      nil
    rescue InboundValidationError => e
      e
    end

    def _reclassified_user_facing_error(error, configs)
      user_facing = configs.each_with_object({}) do |config, hash|
        hash[config.field] = config.user_facing if config.user_facing
      end
      failing = error.errors.map { |err| err.attribute.to_sym }.uniq
      return error unless failing.any? && failing.all? { |field| user_facing.key?(field) }

      InboundValidationError.new(error.errors, user_facing: true, user_facing_message: _user_facing_message(error, failing, user_facing))
    end

    # One message part per failing user-facing field, in failure order, joined like
    # `ValidationError#message`: `true` → the field's own validation message(s); a String → verbatim;
    # a Symbol/callable → its return, invoked with an error **scoped to that field** (so a shared
    # `->(e) { e.message }` sees only its own field, not the aggregate). A String/Symbol/callable
    # that resolves blank falls back to the field's own validation message, so a user-facing failure
    # never surfaces as the dev-facing generic message. The composed reason is then headlined by any
    # declared base `error` in Result (prefixed-by-default, like a `fail!` reason).
    def _user_facing_message(error, failing, user_facing)
      failing.flat_map do |field|
        own = _field_validation_messages(error, field)
        override = case user_facing[field]
                   when true then own
                   when String then user_facing[field]
                   else Core::Flow::Handlers::Invoker.call(action: @action, handler: user_facing[field],
                                                           exception: _field_scoped_error(error, field),
                                                           operation: "resolving user_facing: message")
                   end
        # `presence` first (blank-aware: a handler returning `false`/`nil`/"" means "no message"),
        # then coerce — otherwise `false.to_s` would surface the literal "false" instead of falling
        # back to the field's own validation message.
        Array(override).filter_map { |m| m.presence&.to_s }.presence || own
      end.to_sentence
    end

    # The InboundValidationError handed to a per-field Symbol/Proc handler, carrying only that
    # field's validation errors — `user_facing:` is configured per field, so its handler must see a
    # field-scoped error (otherwise `e.message` leaks every failing field into each field's part).
    def _field_scoped_error(error, field)
      field_errors = error.errors.select { |err| err.attribute.to_sym == field }
      scoped = ActiveModel::Errors.new(field_errors.first.base)
      field_errors.each { |err| scoped.import(err) }
      InboundValidationError.new(scoped)
    end

    def _field_validation_messages(error, field)
      error.errors.select { |err| err.attribute.to_sym == field }.map(&:full_message)
    end

    # For id-based (`:find`) `model:` fields, reject contradictory input: a record AND a `<field>_id`
    # that disagree. Operates purely on raw provided data (no resolution), so it never triggers a
    # lookup. Skipped for custom finders, where `<field>_id` holds a finder-specific token rather than
    # a primary key and a record-vs-id comparison would be meaningless.
    def validate_model_consistency!(skip_fields: [])
      mismatches = []

      @action_class.send(:internal_field_configs).each do |config|
        next unless _id_based_model?(config)
        next if skip_fields.include?(config.field)

        msg = _model_record_id_mismatch(source: @context.provided_data, field: config.field)
        mismatches << msg if msg
      end

      @action_class.send(:subfield_configs).each do |config|
        next unless _id_based_model?(config)
        next if skip_fields.include?(_root_wire_field(config.on))

        parent = Axn::Core::ContractForSubfields.resolve_parent(@action, config.on)
        msg = _model_record_id_mismatch(source: parent, field: config.field)
        mismatches << msg if msg
      end

      return if mismatches.empty?

      # InboundValidationError (a ValidationError) renders its message via errors.full_messages, so
      # it must be raised with an ActiveModel::Errors object — a plain String would NoMethodError the
      # moment anything reads result.error/message. Mismatches carry their own field prefix, so add
      # them on :base (full_messages returns base messages verbatim, no attribute prefix).
      errors = ActiveModel::Errors.new(@action)
      mismatches.each { |msg| errors.add(:base, msg) }
      raise InboundValidationError, errors
    end

    def _id_based_model?(config)
      model = config.validations[:model]
      model.is_a?(Hash) && model[:finder] == :find
    end

    def _model_record_id_mismatch(source:, field:)
      return nil if source.nil?

      record = Core::FieldResolvers.resolve(type: :extract, field:, provided_data: source)
      raw_id = Core::FieldResolvers.resolve(type: :extract, field: :"#{field}_id", provided_data: source)
      return nil if record.nil? || raw_id.nil? || raw_id.to_s.strip.empty?
      return nil unless record.respond_to?(:id)
      return nil if record.id.to_s == raw_id.to_s

      "#{field}: provided record (id=#{record.id.inspect}) conflicts with #{field}_id=#{raw_id.inspect} — pass one, or matching values"
    end

    # Normalize a subfield's `on:` back to the ultimate top-level *wire* field — the key ActiveModel
    # reports in validation errors, and what the skip sets are built from. `on:` names a *reader*,
    # which may be aliased (`as:`), dotted (`"raw_payload.meta"`), or itself rooted at another
    # subfield; walk all three back to the top-level field so a derived check against a failed
    # user-facing parent is skipped no matter how the parent was named.
    def _root_wire_field(on)
      root = on.to_s.split(".").first
      top = @action_class.send(:internal_field_configs).find { |c| c.reader_as.to_s == root }
      return top.field if top

      sub = @action_class.send(:subfield_configs).find { |c| c.reader_as.to_s == root }
      return _root_wire_field(sub.on) if sub

      root.to_sym
    end

    def validate_subfields_contract!(skip_parents: [])
      @action_class.send(:subfield_configs).each do |config|
        parent_field = config.on
        subfield = config.field
        next if skip_parents.include?(_root_wire_field(parent_field))

        Axn::Validation::Subfields.validate!(
          field: subfield,
          validations: config.validations,
          source: Axn::Core::ContractForSubfields.resolve_parent(@action, parent_field),
          exception_klass: InboundValidationError,
          action: @action,
          reader: config.reader_as,
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

        parent_field = _wire_parent_key(config.on)
        subfield = config.field
        parent_value = @context.provided_data[parent_field]

        next if parent_value && !Core::FieldResolvers.resolve(type: :extract, field: subfield, provided_data: parent_value).nil?

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

    # on_success is defined to run only once the *enclosing* transaction durably commits
    # (immediately when none is open), and to be skipped if it rolls back.
    # ActiveRecord.after_all_transactions_commit (AR 7.2+) yields immediately with no open
    # transaction, otherwise registers an after_commit hook on the outermost transaction.
    # Guarded so non-Rails usage (no ActiveRecord) and pre-7.2 ActiveRecord (no
    # after_all_transactions_commit) both dispatch inline as before.
    def trigger_on_success
      dispatch = -> { @action_class._dispatch_callbacks(:success, action: @action, exception: nil) }

      if defined?(ActiveRecord) && ActiveRecord.respond_to?(:after_all_transactions_commit)
        ActiveRecord.after_all_transactions_commit(&dispatch)
      else
        dispatch.call
      end
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
      @context.__record_early_completion(e.message, prefixed: e.prefixed)
      raise e
    end

    # =========================================================================
    # SUBFIELD HELPERS
    # =========================================================================

    # Translate an aliased top-level `on:` parent back to its wire key (see
    # Contract::ClassMethods#_wire_parent_key) so the default/preprocess mutation paths land on the
    # caller-supplied provided_data key.
    def _wire_parent_key(on) = @action_class._wire_parent_key(on)

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
