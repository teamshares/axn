# frozen_string_literal: true

module Axn
  module Tools
    # Mixed into an adapter's config module (which already `extend Axn::Configurable`), alongside
    # `Axn::Tools::AdapterRoots`, to declare and consume the one setting every tool-serving adapter
    # needs — "does rendering a value with no author-declared JSON projection fail or ship anyway" —
    # and to run the resolve -> render / resolve -> map chain through it. Every adapter hand-rolled
    # this identically except for the setting's default (PRO-2996): the declaration, the
    # `resolve_override_for` call, and the never-raises guard around result-to-response mapping now
    # live here once, so a fourth adapter (or a fourth per-tool override reader on an existing one)
    # cannot get any of the three wrong.
    module AdapterSerialization
      # Declares the per-adapter `reject_opaque_exposed_values` setting. `default:` has NO method
      # default and is required: core never picks a value here, because the correct default is a
      # transport question, not a shared one — a published HTTP contract with a declared
      # `output_schema` must reject a rendering its author never declared (axn-openapi: `true`), while
      # an LLM-facing adapter is better off shipping an ugly-but-honest string than failing the whole
      # call (axn-mcp/axn-ruby_llm: `false`). Fixing either direction here would be actively wrong for
      # the other. `overridable: true` so a single tool can opt in/out via `configure(:ns) { |c| ... }`
      # without moving the gem-wide default.
      #
      # Must be called after `config_namespace` — an `overridable:` setting locks the namespace
      # (Axn::Configurable::PerClassOverrides#_define_override_methods), and `config_namespace`'s own
      # lock guard raises a clear "declare it before any overridable setting" message if the order is
      # wrong, so this method adds no separate check for it.
      # `default:` is validated against the same `[true, false]` allowlist `one_of:` enforces on
      # every later ASSIGNMENT — but `Axn::Configurable#setting` never validates its own literal
      # `default:`, only a subsequent write. Left unchecked, `declare_reject_opaque_exposed_values!
      # default: "false"` (a String, not the Boolean `false`) would install cleanly and read back as
      # `"false"` — which `serialize_exposed`'s `reject_opaque:` treats by TRUTHINESS, so a plain
      # non-boolean typo would silently turn ON strict rejection for every tool, the opposite of what
      # `default: false` was written to mean, with no raise anywhere until a caller noticed the wrong
      # behavior. Checked here so the mistake fails at gem load instead.
      def declare_reject_opaque_exposed_values!(default:)
        unless [true, false].include?(default)
          raise ArgumentError, "declare_reject_opaque_exposed_values! default: must be true or false; got #{default.inspect}"
        end

        setting :reject_opaque_exposed_values, default:, one_of: [true, false], overridable: true
      end

      # Renders a successful result's `exposes` values, resolving `reject_opaque_exposed_values`
      # PER TOOL rather than off the gem-wide config — the load-bearing rule of the author-once model
      # (a plain wrapped Axn never included this adapter's `overrides` module, so it has no accessor of
      # its own; `resolve_override_for` reads the override store directly and falls back through the
      # gem-wide config to the declared default).
      #
      # Takes ONLY the result, not an axn class: the class is derived from `result.__action__`'s OWN
      # class, so resolving one class's override while rendering a DIFFERENT class's result — the
      # only way to skip resolution by accident — is structurally impossible, the same reasoning
      # that dropped `Axn::Extensions::Serialization.render`'s field-config argument (a rendered body
      # must match the result it came from).
      #
      # Read through `Internal::Identity.class_of` (a bound `Object#class`), not a dispatched
      # `.class` — the action instance is user-authored code, and nothing stops it defining its own
      # `#class` (Ruby allows it; axn's method-shadowing guards reserve `call`/`_run`/`initialize`,
      # not `class`). A hijacked `#class` pointing at a DIFFERENT tool's class would resolve THIS
      # tool's `reject_opaque_exposed_values` against that other tool's setting instead of its own —
      # reproduced: a strict tool whose action defined `def class = LenientTool` rendered an opaque
      # value it should have refused, resolving the lenient tool's override instead of its own.
      def serialize_exposed(result)
        axn_class = Axn::Internal::Identity.class_of(result.__action__)
        Axn::Extensions::Serialization.render(
          result,
          reject_opaque: resolve_override_for(axn_class, :reject_opaque_exposed_values),
        )
      end

      # Wraps a transport's result-to-response mapping — rendering the exposed values and building the
      # transport-native response object — in axn's non-bang "never raises" guarantee. `axn_class.call`
      # itself never raises (core catches the action body's own exceptions into a failed Result and
      # pages `on_exception` itself); what CAN raise is the step that runs after it, entirely outside
      # core's executor: a value with no honest JSON form, a structure past the encoder's
      # `max_nesting`, or a plain gem bug in the mapping code.
      #
      # Scope this around ONLY that mapping step — never around `axn_class.call` (or the Invoker's
      # call to it), which already reports its own exceptions; wrapping both would page `on_exception`
      # twice for one failure.
      #
      # On a raise: re-raises when `Axn::Extensions.raises_in_dev?` so a real bug surfaces loudly in
      # development rather than being silently masked as a generic tool error; otherwise reports
      # through `Axn.config.on_exception` for observability (inside `Axn::Extensions.best_effort`, so
      # a reporter that itself raises cannot break this guard's own never-raises contract) and calls
      # `on_error` with the exception so the caller builds its own transport-native error response —
      # that response shape is adapter-specific (an `MCP::Tool::Response`, a Hash, an HTTP
      # `Dispatch`), so it is never this method's job to construct one.
      #
      # The dev-loud check runs FIRST, before any report — matching `Extensions._warn_and_swallow`'s
      # own precedent (the dev-loud raise supersedes reporting there too, since the raise itself IS
      # the notification) rather than diverging from it. This ordering is load-bearing, not
      # cosmetic: reporting first would mean that when the CONFIGURED reporter is itself broken,
      # `best_effort`'s own dev-loud reraise fires on the REPORTER's exception before this method
      # ever reaches its own reraise of the original mapping failure `e` — so development would
      # surface "reporter broken" instead of the actual bug this guard exists to expose. Checking
      # `raises_in_dev?` first and reraising `e` immediately means the reporter is never even
      # invoked on that path, so it cannot mask anything.
      #
      # `report_ignored: false` on the `best_effort` call: this guard IS "a guard wrapping the
      # global exception report" (`best_effort`'s own doc for the flag), so the default
      # `report_ignored: true` would hand a broken reporter's OWN failure to
      # `Axn.config.on_ignored_exception` — which, left at ITS default, routes right back to the
      # same broken `on_exception`. `Axn::Extensions.reporting?` cannot catch this the way it catches
      # a handler re-entering itself mid-call: `while_reporting`'s `ensure` already cleared the flag
      # by the time the raised exception unwinds back out to this `rescue`, so an unguarded
      # `best_effort` here reports one mapping failure through a broken reporter TWICE.
      #
      # `on_error` is called OUTSIDE that `best_effort` (adapter-authored response-building code, not
      # a side channel `best_effort` is meant to guard), but it must not defeat this method's own
      # never-raises promise either: a raise from it is code this method invoked, not a caller
      # holding its own guard, so it gets the same report-then-propagate treatment. There is
      # genuinely no substitute response to fall back to here — the whole reason `on_error` exists is
      # that only the adapter knows its transport's error shape — so the best this can do is make the
      # second failure OBSERVABLE (report it) rather than let it escape as a silent, undiagnosable
      # double fault.
      #
      # Rescues `StandardError` plus `Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR`
      # (`SystemStackError`, `ScriptError`) — the same allowlist `Core::Executor` settles onto a
      # result, reused rather than a fourth ad-hoc breadth: `result`'s own `as_json`/`to_h` is
      # arbitrary caller code and free to recurse, so a runaway there is `SystemStackError`, not
      # `StandardError`. Both rescues below share the same breadth for the same reason.
      def guard_tool_response(axn_class, on_error:)
        yield
      rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR => e
        adapter_name = Axn::Internal::Rendering.module_name(self)
        desc = "#{adapter_name} tool response mapping"

        Axn::Extensions.reraise_for_dev(e, desc) if Axn::Extensions.raises_in_dev?

        Axn::Extensions.best_effort(desc, action: axn_class, report_ignored: false) do
          Axn.config.on_exception(e, action: axn_class, context: { source: adapter_name })
        end

        begin
          on_error.call(e)
        rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR => on_error_failure
          Axn::Extensions.best_effort("#{desc} (building the fallback response)", action: axn_class, report_ignored: false) do
            Axn.config.on_exception(on_error_failure, action: axn_class, context: { source: adapter_name })
          end

          # A bare `raise` here would re-raise `$!`, but that is NOT dispatch-free the way the doc
          # above claims for `e`: Ruby calls `#exception` on the currently-active exception even for
          # a zero-arg `raise` -- `on_error` is adapter-authored code, and a class overriding
          # `#exception` to return a different object (or raise) would replace or mask the reported
          # `on_error_failure` right here. `reraise_for_dev` is the established safe path for this
          # exact hazard (native dispatch only when trustworthy, an axn-owned wrapper otherwise) --
          # called unconditionally here, not gated on `raises_in_dev?`, since there is no fallback
          # left to swallow into regardless of environment.
          Axn::Extensions.reraise_for_dev(on_error_failure, "#{desc} (building the fallback response)")
        end
      end
    end
  end
end
