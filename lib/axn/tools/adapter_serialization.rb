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
      def declare_reject_opaque_exposed_values!(default:)
        setting :reject_opaque_exposed_values, default:, one_of: [true, false], overridable: true
      end

      # Renders a successful result's `exposes` values, resolving `reject_opaque_exposed_values`
      # PER TOOL rather than off the gem-wide config — the load-bearing rule of the author-once model
      # (a plain wrapped Axn never included this adapter's `overrides` module, so it has no accessor of
      # its own; `resolve_override_for` reads the override store directly and falls back through the
      # gem-wide config to the declared default).
      #
      # Takes ONLY the result, not an axn class: the class is derived from `result.__action__.class`,
      # so resolving one class's override while rendering a DIFFERENT class's result — the only way to
      # skip resolution by accident — is structurally impossible, the same reasoning that dropped
      # `Axn::Extensions::Serialization.render`'s field-config argument (a rendered body must match
      # the result it came from).
      def serialize_exposed(result)
        axn_class = result.__action__.class
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
      # On a raise: reports through `Axn.config.on_exception` for observability (inside
      # `Axn::Extensions.best_effort`, so a reporter that itself raises cannot break this guard's own
      # never-raises contract), then re-raises when `Axn::Extensions.raises_in_dev?` so a real bug
      # surfaces loudly in development rather than being silently masked as a generic tool error, and
      # otherwise calls `on_error` with the exception so the caller builds its own transport-native
      # error response — that response shape is adapter-specific (an `MCP::Tool::Response`, a Hash, an
      # HTTP `Dispatch`), so it is never this method's job to construct one.
      #
      # Rescues `StandardError` plus `Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR`
      # (`SystemStackError`, `ScriptError`) — the same allowlist `Core::Executor` settles onto a
      # result, reused rather than a fourth ad-hoc breadth: `result`'s own `as_json`/`to_h` is
      # arbitrary caller code and free to recurse, so a runaway there is `SystemStackError`, not
      # `StandardError`.
      def guard_tool_response(axn_class, on_error:)
        yield
      rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR => e
        adapter_name = Axn::Internal::Rendering.module_name(self)

        Axn::Extensions.best_effort("#{adapter_name} tool response mapping", action: axn_class) do
          Axn.config.on_exception(e, action: axn_class, context: { source: adapter_name })
        end

        Axn::Extensions.reraise_for_dev(e, "#{adapter_name} tool response mapping") if Axn::Extensions.raises_in_dev?

        on_error.call(e)
      end
    end
  end
end
