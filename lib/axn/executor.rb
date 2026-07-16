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
    # never executed. Top-level and subfield coerce/preprocess/default now resolve lazily on the read
    # path (ContractForSubfields.resolve_value), so a facet reading a coerced/defaulted/preprocessed
    # input resolves the value the worker would see with no eager pass — the same lazy behavior model:
    # readers already relied on here. This just clears any pre-pipeline memo so those reads resolve
    # against the settled inputs. Deliberately does NOT validate (a report on already-dead work must
    # never raise) and does NOT run the action. Any failure is swallowed — a partially-prepared
    # instance still yields more facets than a bare one.
    def prepare_inbound_for_facets!
      _clear_pre_pipeline_memos!
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
      # Resolve readers in raw mode (ContractForSubfields.resolve_value): a facet reading an input sees the
      # raw serialized value, not the coerced/preprocessed/defaulted run-time value, so it stays in lockstep
      # with the payload the worker receives and a dynamic hook is not run at enqueue.
      @action.instance_variable_set(:@__resolve_raw_reads, true)
      maps = []
      maps << resolved_input_tags if sources.include?(:tag)
      maps << resolved_input_dimensions if sources.include?(:dimension)
      maps
    ensure
      @action.remove_instance_variable(:@__resolve_raw_reads) if @action.instance_variable_defined?(:@__resolve_raw_reads)
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
      # A pre-pipeline read — a hook/preprocess touching a reader (which may consult a sibling's
      # value-level default via resolve_model_via_sibling_id) — can populate both
      # ContractForSubfields' @__resolve_value_cache AND a reader's own memo before inbound validation
      # runs. The settled inputs are the authoritative state, so discard any pre-pipeline cache: the
      # validation-time reads below then resolve against the settled wire values.
      _clear_pre_pipeline_memos!

      # Top-level and subfield coerce:/preprocess:/default: resolve lazily on the read path
      # (ContractForSubfields.resolve_value), first triggered as inbound validation reads each reader —
      # never eagerly written back into provided_data. A `done!` raised inside a preprocess/default
      # therefore surfaces here, during validation, so this read is wrapped to settle the early
      # completion.
      return if handle_early_completion_if_raised { validate_contract!(:inbound) }

      # Inputs are canonical here (preprocessed, defaulted, validated), so input-phase facets can
      # resolve — wrap the body so in-flight log lines inherit them under a SemanticLogger.
      if handle_early_completion_if_raised { with_facet_log_context(&block) }
        apply_defaults!(:outbound)
        validate_contract!(:outbound)
        return
      end

      # The outbound copy-forward reads expects+exposes fields through the read path, which can be the
      # first time a field's default:/preprocess: runs; a done! raised there settles the same early
      # completion as one raised during validation or the body, rather than escaping .call.
      return if handle_early_completion_if_raised do
        apply_defaults!(:outbound)
        validate_contract!(:outbound)
      end

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

    # With coerce_input_types resolved on, surface `coerce: true` in the type bag for a coercible field
    # that didn't set `coerce:` explicitly, so TypeValidator emits the "could not be coerced" message on
    # a parse failure exactly as for an explicit `coerce:` field. Message-only — the coercion itself
    # resolves on the read path (ContractForSubfields.resolve_value); this returns a copy and never
    # mutates the shared config. A field with an explicit coerce flag (true or false) is left as-is,
    # so field-level intent wins.
    def _with_effective_coerce(field_validations)
      type_opt = field_validations[:type]
      return field_validations if type_opt.nil?
      return field_validations if type_opt.is_a?(Hash) && type_opt.key?(:coerce)
      return field_validations if Axn::Reflection::Coercion.coercible_klasses(type_opt).empty?

      type_hash = type_opt.is_a?(Hash) ? type_opt : { klass: type_opt }
      field_validations.merge(type: type_hash.merge(coerce: true))
    end

    def validate_contract!(direction)
      raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

      return _validate_inbound! if direction == :inbound

      failures = @action_class.send(:external_field_configs).filter_map do |config|
        errors = Axn::Validation::Fields.collect_errors(field: config.field, validations: config.validations,
                                                        source: @action.result, action: @action)
        ContractFailure.new(config:, path: nil, errors:, stranded_at: nil) if errors.any?
      end
      raise OutboundValidationError, _aggregate_errors(failures, []) if failures.any?
    end

    # Inbound validation has three sources — declared fields at every depth, plus model consistency —
    # and runs collect-then-settle: EVERY config's errors are collected first (one uniform per-config
    # pass over both stores, then model-consistency mismatches), stranded checks are pruned with
    # complete failure knowledge, and the survivors settle once. Classification follows each failing
    # config's own `user_facing:` at any depth; model-consistency mismatches are structurally
    # dev-facing. The settling rule: any dev-facing violation dominates and the whole (unsuppressed)
    # violation set raises unreclassified — a real contract bug always pages, with every co-occurring
    # violation in one report; only when EVERY violation lands on a user-facing config does the
    # failure compose into one user-facing message.
    def _validate_inbound!
      failures = _collect_contract_failures
      failed_nodes = {}.compare_by_identity
      failures.each { |failure| failed_nodes[failure.path.node] = true if failure.path }

      # Causal suppression, post-hoc with COMPLETE failure knowledge (declaration order can't hide an
      # ancestor that failed after a descendant validated): a nil/invalid ancestor strands every
      # descendant (PRO-2857), so a stranded check's noise is attributed to the ancestor — it must
      # never page over a user-facing ancestor's message, nor pad a dev-facing report. A failed
      # top-level config marks its root node, so its whole subtree suppresses through the same rule.
      failures.reject! { |failure| failure.path && _suppressed_by_failed_ancestor?(failure.path, failed_nodes) }
      mismatches = _model_consistency_mismatches(failed_nodes)

      return if failures.empty? && mismatches.empty?

      raise InboundValidationError, _aggregate_errors(failures, mismatches) unless mismatches.empty? && failures.all? { |f| _failure_fully_user_facing?(f) }

      # Resolve the user-facing message — invoking any Symbol/Proc handler — only now, once we know
      # this is the exception we actually raise (the dominance check above didn't pre-empt it), so a
      # discarded reclassification never fires an expensive/side-effecting handler for nothing.
      raise _composed_user_facing_error(failures)
    end

    ContractFailure = Data.define(:config, :path, :errors, :stranded_at)

    # Every inbound config's errors — top-level fields and subfields through the one collector —
    # gathered in declaration order with no early exit: settling needs the complete set (both to
    # aggregate the report and to suppress stranded descendants accurately). A top-level field
    # validates against the inbound facade (which resolves model records and reads by wire key); a
    # subfield against its canonically-resolved parent, with its reader supplied for model resolution.
    def _collect_contract_failures
      coerce_input_types = Axn::Configuration.resolve_override_for(@action_class, :coerce_input_types)

      _inbound_configs.filter_map do |config|
        errors = Axn::Validation::Fields.collect_errors(
          field: config.field,
          validations: coerce_input_types ? _with_effective_coerce(config.validations) : config.validations,
          source: config.subfield? ? _resolved_parent_value(config) : @action.internal_context,
          action: @action,
          reader: config.subfield? ? config.reader_as : nil,
          config: config.subfield? ? config : nil,
        )
        next if errors.empty?

        path = _resolved_path_for(config)
        ContractFailure.new(config:, path:, errors:, stranded_at: path && _stranded_ancestor_path(path, config))
      end
    end

    # The dotted wire path of the first nil INTERMEDIATE ancestor along a failing subfield's chain
    # (nil when the chain is intact, or when the nil is the top-level root itself — a nil root is
    # self-evident in the report: its own presence error co-reports, or its absence is the classic
    # PRO-2857 semantics). Purely diagnostic: names which nested hop stranded the failing check, so
    # a "Note can't be blank" three levels deep doesn't send the caller hunting.
    def _stranded_ancestor_path(path, config)
      root_config = @action_class.send(:internal_field_configs).find { |c| c.field == path.wire_path.first }
      value = root_config ? Axn::Core::ContractForSubfields.resolve_value(@action, root_config) : @context.provided_data[path.wire_path.first]
      return nil if value.nil?

      path.wire_path[1..-2].each_with_index do |seg, i|
        value = Core::FieldResolvers.resolve(type: :extract, field: seg.to_s, provided_data: value,
                                             permit_method_call: _segment_permits_method_call?(path, i + 1, config))
        return path.wire_path[0..i + 1].join(".") if value.nil?
      end
      nil
    rescue Axn::ContractViolation::UnextractableError
      # A malformed intermediate isn't a nil strand — its own validation reports it; no diagnostic.
      nil
    end

    # Whether reading the wire segment at `wire_index` (≥1) may dispatch a method: governed by the
    # config of the node that segment PRODUCES (its child — the deeper hop's parent, or the leaf for
    # the last segment). A declared child carries its OWN opt-in; an IMPLICIT intermediate honors the
    # resolving `config`'s method_call: (PRO-2926), so this diagnostic dispatches exactly the hops
    # runtime resolution does and never crashes on the gate error where runtime would have dispatched.
    def _segment_permits_method_call?(path, wire_index, config)
      child = wire_index < path.ancestors.size ? path.ancestors[wire_index].first : path.node
      _node_dispatches?(child) || (child.implicit? && config.method_call)
    end

    # Whether a tree node is produced by a method_call: subfield. Single source for "is this hop sharp?"
    def _node_dispatches?(node) = node.configs.any?(&:method_call)

    def _suppressed_by_failed_ancestor?(path, failed_nodes)
      path.ancestors.any? { |node, _seg| failed_nodes.key?(node) }
    end

    # The one dev-facing exception: every unsuppressed violation in a single errors object, in
    # declaration order (top-level fields then subfields), with model-consistency mismatches and
    # stranded-path diagnostics on :base.
    def _aggregate_errors(failures, mismatches)
      errors = ActiveModel::Errors.new(Axn::Validation::Aggregate.new)
      failures.each do |failure|
        failure.errors.each { |err| errors.import(err) }
      end
      mismatches.each { |msg| errors.add(:base, msg) }
      failures.filter_map(&:stranded_at).uniq.each do |strand|
        errors.add(:base, "'#{strand}' is nil, so nested expectations beneath it cannot be satisfied")
      end
      errors
    end

    # The one exception raised when every classification unit is user-facing: all errors aggregated
    # (so dev-facing introspection still sees the full picture), with the composed message drawn per
    # unit — each failing config's own `user_facing:` and each shape-member's own tagged intent — one
    # uniform path for every depth. Parts are de-duplicated so a String/Symbol member override on an
    # Array shape surfaces once rather than repeating per failing element.
    def _composed_user_facing_error(failures)
      parts = failures.flat_map { |failure| _user_facing_parts(failure) }
      InboundValidationError.new(_aggregate_errors(failures, []),
                                 user_facing: true, user_facing_message: parts.uniq.to_sentence)
    end

    # A ContractFailure is a container of errors at two classification granularities: a shape-member
    # error (tagged by ShapeValidator) is its own structural, individually-classified unit; every
    # other error is the field's OWN error.
    def _own_errors(failure) = failure.errors.reject { |e| e.options[:axn_shape_member] }
    def _member_errors(failure) = failure.errors.select { |e| e.options[:axn_shape_member] }

    # A failure composes user-facing only when EVERY classification unit is: the field's own errors
    # honor the field's `user_facing:` (own empty ⇒ vacuously satisfied), and each shape-member error
    # honors the member's own tagged intent. A member error defaults dev-facing, so an un-opted member
    # forces the aggregate dev-facing.
    def _failure_fully_user_facing?(failure)
      (_own_errors(failure).empty? || failure.config.user_facing) &&
        _member_errors(failure).all? { |e| e.options[:axn_member_user_facing] }
    end

    # The user-facing message part(s) for one failure, per classification unit: the field's own errors
    # resolve through the field's `user_facing:`; each shape-member error resolves through its own
    # tagged intent, scoped to just that member's failure. Reached only when the failure is fully
    # user-facing.
    def _user_facing_parts(failure)
      parts = []
      own = _own_errors(failure)
      if own.any?
        parts.concat(_resolve_user_facing_override(failure.config.user_facing,
                                                   own: own.map(&:full_message),
                                                   scoped_error: InboundValidationError.new(_errors_containing(own))))
      end
      _member_errors(failure).each do |error|
        parts.concat(_resolve_user_facing_override(error.options[:axn_member_user_facing],
                                                   own: [error.full_message],
                                                   scoped_error: InboundValidationError.new(_errors_containing([error]))))
      end
      parts
    end

    # A fresh ActiveModel::Errors carrying just the given Error objects, so a Symbol/Proc user_facing
    # handler resolving against it sees exactly that classification unit's message (not the aggregate).
    def _errors_containing(error_list)
      errors = ActiveModel::Errors.new(Axn::Validation::Aggregate.new)
      error_list.each { |err| errors.import(err) }
      errors
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

    # For id-based (`:find`) `model:` fields, reject contradictory input: a record AND a `<field>_id`
    # that disagree. The RECORD is always extracted raw (never a model lookup): a present record is
    # authoritative, so a defaulted sibling id must not override it into a fabricated conflict — the id
    # `default:` participates only via resolve_model_via_sibling_id (which fires only when the record is
    # absent). The `<field>_id` is compared against the CALLER-SUPPLIED token with the declared field's
    # own coerce:/preprocess: applied (never its default — see _consistency_id_for) at BOTH depths, so the
    # check agrees with what the reader and the finder path see; a default-only id (the caller supplied
    # nothing) resolves to nil here and never fabricates a conflict. Skipped for
    # custom finders, where `<field>_id` holds a finder-specific token rather than a primary key and a
    # record-vs-id comparison would be meaningless. Mismatches are structurally dev-facing, aggregated
    # into the settled exception's errors on :base (base messages render verbatim — each mismatch
    # carries its own field prefix). Subfield checks are causally suppressed like subfield validation: a
    # failed ancestor means this chain's data is already known-bad, so a consistency mismatch under it
    # is stranding noise.
    def _model_consistency_mismatches(failed_nodes)
      mismatches = []

      @action_class.send(:internal_field_configs).each do |config|
        next unless _id_based_model?(config)
        next if _model_gate_closed?(config) { @action.internal_context }

        record = Core::FieldResolvers.extract_or_nil(field: config.field, provided_data: @context.provided_data,
                                                     permit_method_call: config.method_call)
        raw_id = _consistency_id_for(config)
        msg = _record_id_mismatch(field: config.field, record:, raw_id:)
        mismatches << msg if msg
      end

      @action_class.send(:subfield_configs).each do |config|
        next unless _id_based_model?(config)
        next if (path = _resolved_path_for(config)) && _suppressed_by_failed_ancestor?(path, failed_nodes)
        next if _model_gate_closed?(config) { _resolved_parent_value(config) }

        source = _resolved_parent_value(config)
        record = Core::FieldResolvers.extract_or_nil(field: config.field, provided_data: source, permit_method_call: config.method_call)
        raw_id = _consistency_id_for(config)
        msg = _record_id_mismatch(field: config.field, record:, raw_id:)
        mismatches << msg if msg
      end

      mismatches
    end

    # A config whose MODEL validator is gated OFF for this call: ActiveModel has already waived it, so
    # the model-consistency check (which lives outside AM) must waive too — otherwise a gated-off model
    # field would still raise on a record/id conflict, the one check that survives a closed gate. Both
    # gate tiers are honored: the declaration-level shared if:/unless: AND the `model:` entry's OWN
    # nested if:/unless: (`model: { ..., if: }`), with AM's real tier precedence applied by the probe
    # (see Fields.validator_gate_open?). Key-presence on either tier is checked first, and the `source`
    # is yielded lazily, so an ungated config constructs nothing and resolves nothing — zero cost off
    # the gated path.
    def _model_gate_closed?(config)
      gate_keys = Internal::FieldConfig::CONDITIONAL_GATE_KEYS
      model = config.validations[:model]
      has_shared_gate = gate_keys.any? { |key| config.validations.key?(key) }
      has_nested_gate = model.is_a?(Hash) && gate_keys.any? { |key| model.key?(key) }
      return false unless has_shared_gate || has_nested_gate

      # The gate oracle asks ActiveModel itself (see Fields.validator_gate_open?): the action is
      # threaded, plus the subfield reader/config, so a Symbol/Proc gate resolves against the same
      # `self` and action delegation the real validators see. `source` is yielded only past the
      # key-presence guard, so an ungated config resolves nothing — zero cost off the gated path.
      !Axn::Validation::Fields.validator_gate_open?(
        validations: config.validations,
        entry_options: model,
        action: @action,
        source: yield,
        reader: config.subfield? ? config.reader_as : nil,
        config: config.subfield? ? config : nil,
      )
    end

    def _id_based_model?(config)
      model = config.validations[:model]
      model.is_a?(Hash) && model[:finder] == :find
    end

    # The <field>_id to check model consistency against, at EITHER depth (PRO-2910): nil unless the
    # caller actually supplied the id (a default-only id must not fabricate a conflict with a present
    # record — the record is authoritative), and otherwise the caller-supplied token with the declared
    # `<field>_id`'s coerce:/preprocess:/default: applied via its own reader value (resolve_value), so the
    # check compares exactly what the `<field>_id` reader, its validation, and the finder path
    # (resolve_model_via_sibling_id) all see. The `raw`-nil guard is what keeps a default out of the
    # comparison: with the raw token present, resolve_value returns the transformed present value (never
    # the field's default, which only substitutes for a nil resolved value), so a caller-SUPPLIED id is
    # compared as its own resolved value while a caller-OMITTED id is exempted before resolution. Reusing
    # the CACHED reader value also guarantees a stateful/side-effecting preprocess runs at most once per
    # call. A `<field>_id` with no declared field config carries no transform, so the raw token is used.
    def _consistency_id_for(config)
      id_key = Internal::FieldConfig.model_id_key(config.field)
      # The source and id-config lookup differ by depth: a top-level id is another declared root read off
      # provided_data; a subfield id is a child of the model leaf's own wire parent (the `on:` target),
      # read off the resolved parent — the same parent/child structure the finder rescue consults.
      if config.subfield?
        source = _resolved_parent_value(config)
        # Ambient configs are kept out of `_resolved_subfields`, so fall back to the ambient-scoped tree
        # exactly as the finder path (resolve_model_via_sibling_id) does — otherwise an ambient model
        # subfield's id would be compared raw and fabricate the conflict PRO-2910 fixes elsewhere.
        path = _resolved_path_for(config) || @action_class._ambient_subfield_tree.index[config]
        sibling_node = path && path.parent_node.children[id_key.to_sym]
        id_config = sibling_node&.configs&.first
      else
        source = @context.provided_data
        id_config = @action_class.send(:internal_field_configs).find { |c| c.field == id_key }
      end

      raw = Core::FieldResolvers.extract_or_nil(field: id_key, provided_data: source, permit_method_call: config.method_call)
      return nil if raw.nil?
      return raw unless id_config

      Axn::Core::ContractForSubfields.resolve_value(@action, id_config)
    end

    # The comparison core, source-agnostic: a provided record whose id disagrees with a provided
    # `<field>_id` is a contradiction. A nil/blank id, an absent record, or a record without `.id` is
    # no conflict. Callers supply the record and the (resolved) id from the appropriate source: at both
    # depths the caller-supplied token with its declared transform applied, never a default — see
    # _consistency_id_for.
    def _record_id_mismatch(field:, record:, raw_id:)
      return nil if record.nil? || raw_id.nil? || raw_id.to_s.strip.empty?
      return nil unless record.respond_to?(:id)
      return nil if record.id.to_s == raw_id.to_s

      "#{field}: provided record (id=#{record.id.inspect}) conflicts with #{field}_id=#{raw_id.inspect} — pass one, or matching values"
    end

    def apply_defaults!(direction)
      raise ArgumentError, "Invalid direction: #{direction} (outbound-only)" unless direction == :outbound

      @action_class.send(:external_field_configs).each do |config|
        field = config.field
        # Copy an unexposed inbound value forward before considering the default, so a provided value
        # wins over a declared default. A field that is both `expects` and `exposes` is read through
        # internal_context, so the RESOLVED inbound value (coerce/preprocess/default applied on the
        # read path) is forwarded. A pure-`exposes` field has no inbound reader, but the caller may
        # still have supplied its wire key directly, so it copies the raw provided_data value.
        unless @context.exposed_data.key?(field)
          if @action_class.send(:internal_field_configs).any? { |c| c.field == field }
            @context.exposed_data[field] = @action.internal_context.public_send(field)
          elsif @context.provided_data.key?(field)
            @context.exposed_data[field] = @context.provided_data[field]
          end
        end

        next if config.default.nil?
        next if @context.exposed_data.key?(field) && !@context.exposed_data[field].nil?

        @context.exposed_data[field] = _resolve_default(config)
      end
    end

    def _resolve_default(config)
      Internal::FieldConfig.resolve_default(@action, config)
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
    # Inbound validation is driven by each config's ResolvedPath from the per-class cached
    # SubfieldTree: the tree already translated `on:` reader aliases and dotted segments into the
    # full provided_data wire path once, at build. A top-level field is the depth-0 case
    # (wire_path == [field], no ancestors), so one collector covers both stores.

    # Both stores in declaration order, top-level first — the order inbound validation collects in.
    def _inbound_configs
      @action_class.send(:internal_field_configs) + @action_class.send(:subfield_configs)
    end

    def _resolved_path_for(config)
      @action_class._resolved_subfields.index[config]
    end

    # Drop the per-instance caches an early pre-pipeline read (a hook/preprocess touching a reader
    # before inbound validation runs) may have populated: ContractForSubfields' value-level cache
    # (@__resolve_value_cache, see resolve_value) AND each SUBFIELD reader's memoized value
    # (@_memoized_reader_<reader_as>, see Memoization.define_memoized_reader_method). Called at the top
    # of with_contract — the settled inputs are authoritative. Without this, a preprocess/default Proc
    # that reads a reader early caches a value against pre-pipeline state, and validation (which
    # public_sends the reader — see Validation::Fields) then sees stale input, so invalid data passes.
    # Same accepted trade as the resolve_value clear: a Proc default read early and re-read post-clear
    # runs twice.
    #
    # One ivar per reader-generating subfield config covers every flavor: the plain reader, and the
    # model RECORD reader (whose stale memo would otherwise pin a record resolved from the old id).
    # The model `<field>_id` reader is an unmemoized define_method (nothing to clear), and the boolean
    # `?` predicate is an alias of the primary reader (sharing its ivar), so neither needs its own clear.
    # Top-level reader memos live on the facade singleton, not the action instance, so they are not
    # cleared here: a top-level model record would re-run its finder — pre-existing behavior.
    def _clear_pre_pipeline_memos!
      @action.remove_instance_variable(:@__resolve_value_cache) if @action.instance_variable_defined?(:@__resolve_value_cache)

      @action_class.send(:subfield_configs).each do |config|
        ivar = :"@_memoized_reader_#{config.reader_as}"
        @action.remove_instance_variable(ivar) if @action.instance_variable_defined?(ivar)
      end
    end

    # The parent value a subfield validates against, resolved once per distinct `on:` target per
    # call — canonically, through the deepest reader-bearing ancestor (see
    # ContractForSubfields.resolve_parent), so both spellings of the same wire path share one
    # resolution. The parent itself is resolved on the read path (coerce/preprocess/default applied
    # without mutating provided_data), so this observes the same values the readers do. Keyed by
    # `method_call:` as well as the `on:` target: resolving an implicit method hop depends on the
    # resolving config's dispatch opt-in (PRO-2926), so two siblings under one `on:` that disagree on
    # `method_call:` must each resolve per their own flag — the non-opted-in one raising its own gate
    # regardless of order — rather than one reusing the other's dispatched (or refused) result.
    def _resolved_parent_value(config)
      memo = (@_resolved_parent_values ||= {})
      key = [config.on.to_s, config.method_call]
      memo.fetch(key) { memo[key] = Axn::Core::ContractForSubfields.resolve_parent(@action, config) }
    end
  end
end
