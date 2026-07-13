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

    # Best-effort inbound preparation for OUT-OF-BAND facet resolution — the async exhaustion/discard
    # report path (Axn::Async::ExceptionReporting), where an action is reconstructed from job args and
    # never executed. Applies the same inbound coercion, preprocessing, and defaults a normal `.call`
    # would (in that order), so a facet reading a coerced/defaulted/preprocessed input resolves the
    # value the worker saw rather than the raw constructor value. Deliberately does NOT validate (a
    # report on already-dead work must never raise) and does NOT run the action; model: readers still
    # resolve lazily on read. Any failure is swallowed — a partially-prepared instance still yields
    # more facets than a bare one.
    def prepare_inbound_for_facets!
      apply_inbound_coercion!
      apply_inbound_preprocessing!
      apply_defaults!(:inbound)
    rescue StandardError => e
      Internal::PipingError.swallow("preparing inbound context for async facet resolution", action: @action, exception: e)
    end

    # Input-phase facet resolution for enqueue-time sinks (e.g. Sidekiq job tags), where there is
    # no run to hang completion-time resolution on. Resolves only `from: :inputs` facets (via the
    # memoized resolved_input_* readers) against the RAW enqueued inputs. It deliberately does NOT
    # run preprocess/defaults: those are user hooks that must execute once, at perform — a dynamic
    # `default:`/`preprocess:` run here would both double-execute (enqueue AND perform) and compute
    # a value that can differ from the run, so the facet would drift from its own job. Resolving
    # from raw inputs keeps the facet in lockstep with the serialized payload the worker receives.
    # `from: :result` facets are excluded by construction (they can't resolve before the body runs);
    # a `model:` field's record still loads lazily (facade.rb) if a resolver reads it. Returns one
    # resolved map per enabled source (tags, then dimensions), kept SEPARATE so a name declared as
    # both a tag and a dimension yields two facets rather than one clobbering the other. `sources`
    # is a subset of %i[tag dimension]. See PRO-2855.
    def resolve_inbound_facets(sources)
      maps = []
      maps << resolved_input_tags if sources.include?(:tag)
      maps << resolved_input_dimensions if sources.include?(:dimension)
      maps
    end

    private

    # =========================================================================
    # TRACING (Outside zone - result is settled)
    # =========================================================================

    def with_tracing(&block)
      resource = @action_class.resolved_axn_name
      payload = { resource:, action: @action }

      update_payload = proc do
        result = @action.result
        outcome = result.outcome.to_s
        payload[:outcome] = outcome
        payload[:result] = result
        payload[:elapsed_time] = result.elapsed_time
        payload[:exception] = result.exception if result.exception
        payload[:tags] = Core::Tagging.dup_facets(resolved_tags) if @action_class._tags.any?
        payload[:dimensions] = Core::Tagging.dup_facets(resolved_dimensions) if @action_class._dimensions.any?
      rescue StandardError => e
        Internal::PipingError.swallow("updating notification payload while tracing axn.call", action: @action, exception: e)
      end

      # Enrich the payload from inside the instrument block — after the action settles but
      # BEFORE ActiveSupport publishes the event — so live `axn.call` subscribers observe the
      # full payload. Running update_payload after `instrument` returns (its own ensure) would
      # publish first and mutate after, leaving subscribers with outcome/result/tags/dimensions
      # missing at callback time.
      instrument_block = proc do
        ActiveSupport::Notifications.instrument("axn.call", payload) do
          block.call
        ensure
          update_payload.call
        end
      end

      if defined?(OpenTelemetry)
        in_span_kwargs = { attributes: { "axn.resource" => resource } }
        in_span_kwargs[:record_exception] = false if Internal::Tracing.supports_record_exception_option?

        Internal::Tracing.tracer.in_span("axn.call", **in_span_kwargs) do |span|
          instrument_block.call
        ensure
          finalize_span(span)
        end
      else
        instrument_block.call
      end
    ensure
      begin
        emit_metrics_proc = Axn.config.emit_metrics
        if emit_metrics_proc
          result = @action.result
          Internal::Callable.call_with_desired_shape(emit_metrics_proc,
                                                     kwargs: { resource:, result:, dimensions: Core::Tagging.dup_facets(resolved_dimensions) })
        end
      rescue StandardError => e
        Internal::PipingError.swallow("calling emit_metrics while tracing axn.call", action: @action, exception: e)
      end
    end

    def finalize_span(span)
      result = @action.result
      outcome = result.outcome.to_s
      span.set_attribute("axn.outcome", outcome)

      if %w[failure exception].include?(outcome) && result.exception
        span.record_exception(result.exception)
        error_message = result.exception.message || result.exception.class.name
        span.status = OpenTelemetry::Trace::Status.error(error_message)
      end

      resolved_tags.each { |name, value| span.set_attribute("axn.tag.#{name}", value) }
      resolved_dimensions.each { |name, value| span.set_attribute("axn.dimension.#{name}", value) }
    rescue StandardError => e
      Internal::PipingError.swallow("updating OTel span while tracing axn.call", action: @action, exception: e)
    end

    # Facets resolve in two phases (see Core::Tagging::Facet): input-phase facets resolve from
    # inputs (eagerly, before the body — so they can annotate in-flight logs), result-phase facets
    # resolve at settle. Each phase is memoized and resolved once; the settle-time sinks (span,
    # payload, emit_metrics, completion-line log) read the merged view.
    def resolved_tags = @resolved_tags ||= resolved_input_tags.merge(resolved_result_tags)
    def resolved_dimensions = @resolved_dimensions ||= resolved_input_dimensions.merge(resolved_result_dimensions)

    # Build a declared facet map for the exception report. REUSE the pre-body input-phase snapshot
    # (`input_snapshot`, memoized in with_facet_log_context before `call`) so the report matches the
    # value the span/payload/logs captured — even if the body then mutated an input. Resolve only the
    # RESULT-phase facets freshly here, and deliberately NOT through the memoized resolved_result_*:
    # trigger_on_exception runs inside with_timing, before its ensure sets result.elapsed_time, so
    # memoizing now would freeze a result-phase facet reading elapsed_time as nil and poison those
    # post-timing sinks. dup the whole merge so a reporter mutating a value can't corrupt the shared
    # input snapshot the other sinks read (the fresh result-phase values are already private).
    def resolve_report_facets(input_snapshot, map)
      return {} unless map.any?

      Core::Tagging.dup_facets(input_snapshot.merge(Core::Tagging.resolve(map, action: @action, from: :result)))
    end

    def resolved_input_tags = @resolved_input_tags ||= _resolve_facets(@action_class._tags, :inputs)
    def resolved_result_tags = @resolved_result_tags ||= _resolve_facets(@action_class._tags, :result)
    def resolved_input_dimensions = @resolved_input_dimensions ||= _resolve_facets(@action_class._dimensions, :inputs)
    def resolved_result_dimensions = @resolved_result_dimensions ||= _resolve_facets(@action_class._dimensions, :result)

    def _resolve_facets(facets, from)
      facets.any? ? Core::Tagging.resolve(facets, action: @action, from:) : {}
    end

    # =========================================================================
    # LOGGING (Outside zone - result is settled)
    # =========================================================================

    def with_logging
      log_before if @action_class._auto_log_before_level
      yield
    ensure
      log_after
    end

    def log_before
      Internal::CallLogger.log_at_level(
        @action_class,
        level: @action_class._auto_log_before_level,
        message_parts: ["About to execute"],
        join_string: " with: ",
        before: top_level_separator,
        error_context: "logging before hook",
        context_direction: :inbound,
        context_instance: @action,
      )
    end

    def log_after
      level = @action_class._auto_log_level_for(@action.result.outcome)
      return unless level

      log_after_at_level(level)
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
        facets: log_facets,
      )
    end

    # Copies (never the memoized maps) of the resolved facets for the log sink, so a suffix/tagged
    # annotation can never mutate what the span / payload / emit_metrics sinks share. Omitted
    # entirely when nothing is declared, so an action with no facets does zero extra work here.
    def log_facets
      return nil unless @action_class._tags.any? || @action_class._dimensions.any?

      {
        tags: Core::Tagging.dup_facets(resolved_tags),
        dimensions: Core::Tagging.dup_facets(resolved_dimensions),
      }
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

      # Resolve + stamp the presentation BEFORE dispatching any callbacks, so an on_error/on_failure
      # filter or body that reads exception.message observes the same resolved string as result.error
      # and the call!-raised exception — not the raw reason. (Context is finalized by __record_exception
      # above, so result.error memoizes here.)
      _resolve_and_stamp_presentation(e)

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

    # Resolve THIS level's presentation NOW (memoizing it on the result) and, for an Axn-owned
    # exception, stamp it onto #message so a rescued exception reads the same string as result.error.
    #
    # The eager resolution matters even when nothing is stamped: it must happen while this action is
    # still on the nesting stack, because an ancestor's `call!` carried the child's presentation in
    # CarriedPresentation, which is cleared when the stack empties. Resolving (and memoizing) here
    # freezes the aggregated value before that reset; a later lazy read would find the carry gone.
    #
    # The cross-level CARRY itself is set by `call!`, not here — it must be scoped to transparent
    # `call!` bubbling. Setting it at every level would leave a presentation on a child run via plain
    # `.call`, which an explicit `.call` + re-raise (e.g. `step`'s bug path, `raise step_result.exception`)
    # would then leak into the parent's aggregation.
    def _resolve_and_stamp_presentation(exception)
      resolved = @action.result.error
      return unless resolved && Axn.owns_failure_exception?(exception) && exception.respond_to?(:__present_as)

      exception.__present_as(resolved)
    end

    def trigger_on_exception(exception)
      retry_context = Async::CurrentRetryContext.current if defined?(Async::CurrentRetryContext)
      if retry_context
        mode = @action_class.try(:_async_exception_reporting)
        return unless retry_context.should_trigger_on_exception?(mode)
      end

      # Per-action :exception callbacks fire at each level (an action may legitimately observe its
      # own failure), but the GLOBAL report is sent at most once per exception, at the INNERMOST action
      # that treats it as a bug (where the failing action and full nesting stack are still live). A
      # nested `call!` re-raises the same object up the stack; the `reported?` guard stops each ancestor
      # from reporting it again.
      @action_class._dispatch_callbacks(:exception, action: @action, exception:)
      return if Internal::ExceptionClassification.reported?(exception)

      # Mark BEFORE attempting, so the report is best-effort EXACTLY once: if on_exception (or building
      # its context) raises, it's swallowed and logged below and NOT retried from an ancestor (which
      # would describe the wrong action anyway). Deterministic regardless of nesting depth.
      Internal::ExceptionClassification.mark_reported!(exception)

      context = Internal::ExceptionContext.build(
        action: @action,
        retry_context:,
        # Pre-body input snapshot (memoized) + freshly-resolved result-phase facets; see resolve_report_facets.
        tags: resolve_report_facets(resolved_input_tags, @action_class._tags),
        dimensions: resolve_report_facets(resolved_input_dimensions, @action_class._dimensions),
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

    def with_contract(&block)
      apply_inbound_coercion!
      return if handle_early_completion_if_raised { apply_inbound_preprocessing! }
      return if handle_early_completion_if_raised { apply_defaults!(:inbound) }

      validate_contract!(:inbound)

      # Inputs are canonical here (preprocessed, defaulted, validated), so input-phase facets can
      # resolve — wrap the body so in-flight log lines inherit them under a SemanticLogger.
      if handle_early_completion_if_raised { with_facet_log_context(&block) }
        apply_defaults!(:outbound)
        validate_contract!(:outbound)
        return
      end

      apply_defaults!(:outbound)
      validate_contract!(:outbound)

      @context.__finalize!
      trigger_on_success
    end

    # Resolve input-phase facets here — after inbound validation, before the body — so their values
    # reflect pre-body inputs. This happens unconditionally (memoized, reused by the settle-time
    # sinks), so the phase contract holds regardless of logger: without this, a plain-logger run
    # would first resolve them later at the completion sinks, making a mutable input's value depend
    # on the logger. Then, only if the configured logger is a SemanticLogger, wrap the body in a
    # tagged context so every log line emitted during `call` is annotated (axn.tag.<name> /
    # axn.dimension.<name>). Result-phase facets aren't available yet — they only annotate the
    # settle-time completion line.
    def with_facet_log_context(&body)
      return body.call unless @action_class._tags.any? || @action_class._dimensions.any?

      named = Core::Tagging.namespaced(tags: resolved_input_tags, dimensions: resolved_input_dimensions)
      return body.call unless named.any? && Internal::CallLogger.semantic_logger?

      SemanticLogger.tagged(**named, &body)
    end

    def handle_early_completion_if_raised
      yield
      false
    rescue Internal::EarlyCompletion => e
      @context.__record_early_completion(e.message, standalone: e.standalone)
      trigger_on_success
      true
    end

    # Wire→Ruby coercion for declared-inbound fields, for those that opted in via `coerce:` (a
    # `coerce: true` flag inside the type bag) OR — when the action resolves `coerce_input_types` on —
    # every coercible-typed field that didn't opt out (see #coerce_field_inbound?). Runs first in the
    # inbound pipeline — before any user preprocess:, defaults, and validation — so downstream stages
    # see the Ruby value. One depth-generalized pass over both stores (a top-level field is the
    # depth-0 case of its ResolvedPath). Coerce-or-leave (Axn::Reflection::Coercion): only String
    # values are transformed, an unparseable string passes through to the normal TypeValidator error,
    # and a present real object is untouched — so an absent/nil value never writes back and coercion
    # never materializes anything. Ambient subfields reject `coerce:` at declaration and aren't
    # indexed, so they never reach the write-back.
    def apply_inbound_coercion!
      coerce_input_types = Axn::Configuration.resolve_override_for(@action_class, :coerce_input_types)

      _inbound_configs.each do |config|
        type_opt = config.validations[:type]
        klasses = Axn::Reflection::Coercion.coercible_klasses(type_opt)
        next if klasses.empty?
        next unless coerce_field_inbound?(type_opt, coerce_input_types)
        next unless (path = _resolved_path_for(config))

        current = _current_value_at(path)
        coerced = Axn::Reflection::Coercion.coerce_value(current, klasses)
        _write_value_at!(path, coerced) unless coerced.equal?(current)
      end
    end

    # Whether a field coerces this run. A field's own `coerce` flag is a tri-state (true/false/absent)
    # and always wins: explicit true coerces, explicit false opts out (even when coerce_input_types is
    # on), and absent follows the resolved coerce_input_types flag. Only reached for a field with ≥1
    # coercible member, so a coerce_input_types-on action still leaves non-coercible types untouched.
    def coerce_field_inbound?(type_opt, coerce_input_types)
      explicit = type_opt.is_a?(Hash) ? type_opt[:coerce] : nil
      explicit.nil? ? coerce_input_types : explicit
    end

    # With coerce_input_types resolved on, surface `coerce: true` in the type bag for a coercible field
    # that didn't set `coerce:` explicitly, so TypeValidator emits the "could not be coerced" message on
    # a parse failure exactly as for an explicit `coerce:` field. Message-only — the coercion itself
    # already ran in apply_inbound_coercion!; this returns a copy and never mutates the shared config.
    # A field with an explicit coerce flag (true or false) is left as-is, so field-level intent wins.
    def _with_effective_coerce(field_validations)
      type_opt = field_validations[:type]
      return field_validations if type_opt.nil?
      return field_validations if type_opt.is_a?(Hash) && type_opt.key?(:coerce)
      return field_validations if Axn::Reflection::Coercion.coercible_klasses(type_opt).empty?

      type_hash = type_opt.is_a?(Hash) ? type_opt : { klass: type_opt }
      field_validations.merge(type: type_hash.merge(coerce: true))
    end

    # One depth-generalized pass over both stores. For a subfield, a nil parent has nowhere to write
    # the result, so _write_value_at! no-ops and the preprocess output is dropped — deliberately: a
    # nil/absent parent means the subfield is absent (PRO-2857), and a preprocess must NOT synthesize
    # the parent into existence (unlike a subfield `default:`, which does). Materializing here would
    # make an absent parent present — masking a required parent, and tripping shape/type validation
    # the schema then can't mirror. (A top-level field is its own root, so its result always writes.)
    def apply_inbound_preprocessing!
      _inbound_configs.each do |config|
        next unless config.preprocess
        next unless (path = _resolved_path_for(config))

        current_value = _current_value_at(path)
        preprocessed_value = Internal::ContractErrorHandling.with_contract_error_handling(
          exception_class: ContractViolation::PreprocessingError,
          message: ->(_field, error) { "Error preprocessing #{_field_descriptor(config)}: #{error.message}" },
          field_identifier: _field_identifier(config),
        ) do
          @action.instance_exec(current_value, &config.preprocess)
        end
        _write_value_at!(path, preprocessed_value)
      end
    end

    def validate_contract!(direction)
      raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

      configs = direction == :inbound ? @action_class.send(:internal_field_configs) : @action_class.send(:external_field_configs)
      coerce_input_types = direction == :inbound && Axn::Configuration.resolve_override_for(@action_class, :coerce_input_types)
      validations = configs.each_with_object({}) do |config, hash|
        hash[config.field] = coerce_input_types ? _with_effective_coerce(config.validations) : config.validations
      end
      context = direction == :inbound ? @action.internal_context : @action.result
      exception_klass = direction == :inbound ? InboundValidationError : OutboundValidationError

      if direction == :inbound
        _validate_inbound!(validations:, context:, configs:)
      else
        Axn::Validation::Fields.validate!(validations:, context:, exception_klass:)
      end
    end

    # Inbound validation has three sources — top-level fields, subfields, and model consistency —
    # and runs collect-then-settle: EVERY check is collected first (one aggregate top-level pass,
    # per-subfield errors, model-consistency mismatches), stranded checks are pruned with complete
    # failure knowledge, and the survivors settle once. Classification follows each failing config's
    # own `user_facing:` at any depth; model-consistency mismatches are structurally dev-facing. The
    # settling rule: any dev-facing violation dominates and the whole (unsuppressed) violation set
    # raises unreclassified — a real contract bug always pages, with every co-occurring violation in
    # one report; only when EVERY violation lands on a user-facing config does the failure compose
    # into one user-facing message.
    def _validate_inbound!(validations:, context:, configs:)
      top_errors = Axn::Validation::Fields.collect_errors(validations:, context:)
      failing_roots = top_errors.map { |err| err.attribute.to_sym }.uniq

      subfield_failures = _collect_subfield_failures
      failed_nodes = {}.compare_by_identity
      subfield_failures.each { |failure| failed_nodes[failure.path.node] = true if failure.path }

      # Causal suppression, post-hoc with COMPLETE failure knowledge (declaration order can't hide an
      # ancestor that failed after a descendant validated): a nil/invalid ancestor strands every
      # descendant (PRO-2857), so a stranded check's noise is attributed to the ancestor — it must
      # never page over a user-facing ancestor's message, nor pad a dev-facing report.
      subfield_failures.reject! { |failure| failure.path && _suppressed_by_failed_ancestor?(failure.path, failing_roots, failed_nodes) }
      mismatches = _model_consistency_mismatches(failing_roots, failed_nodes)

      return if top_errors.empty? && subfield_failures.empty? && mismatches.empty?

      user_facing = _user_facing_configs(configs)
      all_user_facing = mismatches.empty? &&
                        failing_roots.all? { |field| user_facing.key?(field) } &&
                        subfield_failures.all? { |failure| failure.config.user_facing }

      raise InboundValidationError, _aggregate_errors(top_errors, subfield_failures, mismatches) unless all_user_facing

      # Resolve the user-facing message — invoking any Symbol/Proc handler — only now, once we know
      # this is the exception we actually raise (the dominance check above didn't pre-empt it), so a
      # discarded reclassification never fires an expensive/side-effecting handler for nothing.
      raise _composed_user_facing_error(top_errors, failing_roots, user_facing, subfield_failures)
    end

    SubfieldFailure = Data.define(:config, :path, :errors)

    # Every subfield's errors, collected in declaration order with no early exit — settling needs the
    # complete set (both to aggregate the report and to suppress stranded descendants accurately).
    def _collect_subfield_failures
      coerce_input_types = Axn::Configuration.resolve_override_for(@action_class, :coerce_input_types)

      @action_class.send(:subfield_configs).filter_map do |config|
        errors = Axn::Validation::Subfields.collect_errors(
          field: config.field,
          validations: coerce_input_types ? _with_effective_coerce(config.validations) : config.validations,
          source: _resolved_parent_value(config.on),
          action: @action,
          reader: config.reader_as,
        )
        SubfieldFailure.new(config:, path: _resolved_path_for(config), errors:) if errors.any?
      end
    end

    def _suppressed_by_failed_ancestor?(path, failed_roots, failed_nodes)
      failed_roots.include?(path.wire_path.first) || path.ancestors.any? { |node, _seg| failed_nodes.key?(node) }
    end

    # The one dev-facing exception: every unsuppressed violation from all three sources in a single
    # errors object, in source order (top-level fields, then subfields in declaration order, then
    # model-consistency mismatches on :base).
    def _aggregate_errors(top_errors, subfield_failures, mismatches)
      errors = ActiveModel::Errors.new(Axn::Validation::Aggregate.new)
      top_errors.each { |err| errors.import(err) }
      subfield_failures.each do |failure|
        failure.errors.each { |err| errors.import(err) }
      end
      mismatches.each { |msg| errors.add(:base, msg) }
      errors
    end

    # The one exception raised when every violation is user-facing: all errors aggregated (so
    # dev-facing introspection still sees the full picture), with the composed message drawn from
    # each failing config's own `user_facing:` setting.
    def _composed_user_facing_error(top_errors, failing_roots, user_facing, subfield_failures)
      parts = _user_facing_message_parts(top_errors, failing_roots, user_facing)
      parts += subfield_failures.flat_map do |failure|
        _resolve_user_facing_override(failure.config.user_facing, own: failure.errors.map(&:full_message),
                                                                  scoped_error: InboundValidationError.new(failure.errors))
      end

      InboundValidationError.new(_aggregate_errors(top_errors, subfield_failures, []),
                                 user_facing: true, user_facing_message: parts.to_sentence)
    end

    def _user_facing_configs(configs)
      # config.field is symbol-keyed at declaration (PRO-2790), so it matches `failing` (built from
      # `err.attribute.to_sym`) directly — no normalization needed.
      configs.each_with_object({}) do |config, hash|
        hash[config.field] = config.user_facing if config.user_facing
      end
    end

    # One message part per failing user-facing field, in failure order, joined (with the subfield
    # parts) like `ValidationError#message`. The composed reason is then headlined by any declared
    # base `error` in Result (attached by default, like a `fail!` reason).
    def _user_facing_message_parts(top_errors, failing_roots, user_facing)
      failing_roots.flat_map do |field|
        _resolve_user_facing_override(user_facing[field], own: _field_validation_messages(top_errors, field),
                                                          scoped_error: _field_scoped_error(top_errors, field))
      end
    end

    # Resolve one config's `user_facing:` setting into its message part(s): `true` → the field's own
    # validation message(s); a String → verbatim; a Symbol/callable → its return, invoked with an
    # error **scoped to that field** (so a shared `->(e) { e.message }` sees only its own field, not
    # the aggregate). A String/Symbol/callable that resolves blank falls back to the field's own
    # validation message, so a user-facing failure never surfaces as the dev-facing generic message.
    def _resolve_user_facing_override(setting, own:, scoped_error:)
      override = case setting
                 when true then own
                 when String then setting
                 else Core::Flow::Handlers::Invoker.call(action: @action, handler: setting,
                                                         exception: scoped_error,
                                                         operation: "resolving user_facing: message")
                 end
      # `presence` first (blank-aware: a handler returning `false`/`nil`/"" means "no message"),
      # then coerce — otherwise `false.to_s` would surface the literal "false" instead of falling
      # back to the field's own validation message.
      Array(override).filter_map { |m| m.presence&.to_s }.presence || own
    end

    # The InboundValidationError handed to a per-field Symbol/Proc handler, carrying only that
    # field's validation errors — `user_facing:` is configured per field, so its handler must see a
    # field-scoped error (otherwise `e.message` leaks every failing field into each field's part).
    def _field_scoped_error(top_errors, field)
      scoped = ActiveModel::Errors.new(Axn::Validation::Aggregate.new)
      _field_errors(top_errors, field).each { |err| scoped.import(err) }
      InboundValidationError.new(scoped)
    end

    def _field_validation_messages(top_errors, field)
      _field_errors(top_errors, field).map(&:full_message)
    end

    def _field_errors(top_errors, field)
      top_errors.group_by_attribute[field] || []
    end

    # For id-based (`:find`) `model:` fields, reject contradictory input: a record AND a `<field>_id`
    # that disagree. Operates purely on raw provided data (no resolution), so it never triggers a
    # lookup. Skipped for custom finders, where `<field>_id` holds a finder-specific token rather than
    # a primary key and a record-vs-id comparison would be meaningless.
    # Model-consistency mismatch messages, both levels, structurally dev-facing. Aggregated into the
    # settled exception's errors on :base (InboundValidationError renders its message via
    # errors.full_messages, and base messages render verbatim — each mismatch carries its own field
    # prefix). Subfield checks are causally suppressed like subfield validation: a failed ancestor
    # means this chain's data is already known-bad, so a consistency mismatch under it is stranding noise.
    def _model_consistency_mismatches(failed_roots, failed_nodes)
      mismatches = []

      @action_class.send(:internal_field_configs).each do |config|
        next unless _id_based_model?(config)

        msg = _model_record_id_mismatch(source: @context.provided_data, field: config.field)
        mismatches << msg if msg
      end

      @action_class.send(:subfield_configs).each do |config|
        next unless _id_based_model?(config)
        next if (path = _resolved_path_for(config)) && _suppressed_by_failed_ancestor?(path, failed_roots, failed_nodes)

        msg = _model_record_id_mismatch(source: _resolved_parent_value(config.on), field: config.field)
        mismatches << msg if msg
      end

      mismatches
    end

    def _id_based_model?(config)
      model = config.validations[:model]
      model.is_a?(Hash) && model[:finder] == :find
    end

    def _model_record_id_mismatch(source:, field:)
      return nil if source.nil?

      record = Core::FieldResolvers.resolve(type: :extract, field:, provided_data: source)
      raw_id = Core::FieldResolvers.resolve(type: :extract, field: Internal::FieldConfig.model_id_key(field), provided_data: source)
      return nil if record.nil? || raw_id.nil? || raw_id.to_s.strip.empty?
      return nil unless record.respond_to?(:id)
      return nil if record.id.to_s == raw_id.to_s

      "#{field}: provided record (id=#{record.id.inspect}) conflicts with #{field}_id=#{raw_id.inspect} — pass one, or matching values"
    end

    def apply_defaults!(direction)
      raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

      return apply_inbound_defaults! if direction == :inbound

      @action_class.send(:external_field_configs).each do |config|
        field = config.field
        # Copy an unexposed inbound value forward before considering the default, so a provided
        # value wins over a declared default.
        @context.exposed_data[field] = @context.provided_data[field] if !@context.exposed_data.key?(field) && @context.provided_data.key?(field)

        next if config.default.nil?
        next if @context.exposed_data.key?(field) && !@context.exposed_data[field].nil?

        @context.exposed_data[field] = _resolve_default(config)
      end
    end

    # One depth-generalized pass over both stores (a top-level field is the depth-0 case: no
    # ancestors, so the chain gate is vacuous and the default value itself becomes the root value —
    # no `{}` synthesis). A default applies when the current value is nil/absent, matching key-absence
    # semantics at every depth.
    def apply_inbound_defaults!
      _inbound_configs.each do |config|
        next unless config.applied_default?
        next unless (path = _resolved_path_for(config))
        next unless _current_value_at(path).nil?

        # A nil non-object ancestor anywhere along the chain can't hold the nested structure —
        # materialization refuses to inject `{}` where it would fail that ancestor's own declared
        # type — so the subfield is absent. Skip evaluating/writing its default: a Proc default would
        # run its side effects for nothing, and the write would synthesize a type-violating value.
        next unless _default_chain_materializable?(path)

        @context.provided_data[path.wire_path.first] = {} if path.wire_path.size > 1 && @context.provided_data[path.wire_path.first].nil?

        _write_value_at!(path, _resolve_default(config))
      end
    end

    def _resolve_default(config)
      Internal::ContractErrorHandling.with_contract_error_handling(
        exception_class: ContractViolation::DefaultAssignmentError,
        message: ->(_field, error) { "Error applying default for #{_field_descriptor(config)}: #{error.message}" },
        field_identifier: _field_identifier(config),
      ) do
        config.default.respond_to?(:call) ? @action.instance_exec(&config.default) : config.default
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
      @context.__record_early_completion(e.message, standalone: e.standalone)
      raise e
    end

    # =========================================================================
    # RESOLVED-PATH HELPERS
    # =========================================================================
    # The inbound passes are driven by each config's ResolvedPath from the per-class cached
    # SubfieldTree: the tree already translated `on:` reader aliases and dotted segments into the
    # full provided_data wire path once, at build. A top-level field is the depth-0 case
    # (wire_path == [field], no ancestors), so one pass covers both stores.

    # Both stores in declaration order, top-level first — the order the formerly-separate
    # top-level/subfield passes always ran in.
    def _inbound_configs
      @action_class.send(:internal_field_configs) + @action_class.send(:subfield_configs)
    end

    def _resolved_path_for(config)
      @action_class._resolved_subfields.index[config]
    end

    # The current inbound value at a resolved path: the root value itself at depth 0, otherwise an
    # Extract dig from the root value (nil-safe: a nil root yields nil).
    def _current_value_at(path)
      root_value = @context.provided_data[path.wire_path.first]
      below = path.wire_path[1..]
      return root_value if below.empty?

      Core::FieldResolvers.resolve(type: :extract, field: below.join("."), provided_data: root_value)
    end

    # Human identifiers for contract-error reporting, matching each level's historical wording.
    def _field_descriptor(config)
      config.subfield? ? "subfield '#{config.field}' on '#{config.on}'" : "field '#{config.field}'"
    end

    def _field_identifier(config)
      config.subfield? ? "#{config.field} on #{config.on}" : config.field
    end

    # Whether a subfield default's ancestor chain can be fully materialized: every nil/absent node
    # along the chain (the top-level root included) must tolerate `{}` per its own declared types —
    # Schema.object_shaped? on each of the node's configs (an implicit dotted intermediate has no
    # configs and trivially qualifies), the same gate reflection's requiredness derivation uses. A
    # non-object type (e.g. `type: Array`) does NOT qualify — injecting `{}` there would fail that
    # node's own type validator and turn an optional-absent value into a validation error. Present
    # values are not judged here (the write path digs through whatever the caller supplied, as ever).
    def _default_chain_materializable?(path)
      value = @context.provided_data[path.wire_path.first]
      path.ancestors.each_with_index do |(node, seg), i|
        return false if value.nil? && !node.configs.all? { |c| Axn::Reflection::Schema.object_shaped?(c) }
        break if i == path.ancestors.size - 1

        value = value.nil? ? nil : Core::FieldResolvers.resolve(type: :extract, field: seg.to_s, provided_data: value)
      end
      true
    end

    # The parent value a subfield validates against, resolved once per distinct `on:` recipe per
    # call — two configs with the same `on:` share the identical resolution by definition (root
    # reader public_send + raw Extract digs; see ContractForSubfields.resolve_parent), so the memo
    # is a pure dedup of repeated digs. Only populated during the inbound-validation phase, after
    # every provided_data mutation (coercion/preprocess/defaults) has already run.
    def _resolved_parent_value(on)
      memo = (@_resolved_parent_values ||= {})
      key = on.to_s
      memo.fetch(key) { memo[key] = Axn::Core::ContractForSubfields.resolve_parent(@action, on) }
    end

    def _write_value_at!(path, new_value)
      root_key = path.wire_path.first
      below = path.wire_path[1..]
      # Depth 0: the value IS the root — assign directly (key-materializing, as top-level
      # preprocess/defaults always did).
      return @context.provided_data[root_key] = new_value if below.empty?

      parent_value = @context.provided_data[root_key]
      # A nil root has nowhere to write into — the value is deliberately dropped (a preprocess never
      # synthesizes its parent; a default materialized the root before reaching here).
      return if parent_value.nil?

      if below.size > 1
        target = Internal::SubfieldPath.navigate_to_parent(parent_value, below)
        target[below.last] = new_value
      elsif parent_value.is_a?(Hash)
        # Copy-on-write so the caller's own hash is never mutated by axn's write-back.
        @context.provided_data[root_key] = parent_value.merge(below.last => new_value)
      elsif parent_value.respond_to?("#{below.last}=")
        Internal::SubfieldPath.update_object(parent_value, below.last, new_value)
      end
    end
  end
end
