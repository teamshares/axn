# frozen_string_literal: true

module Axn
  # The tool surface: registering an adapter, enumerating its tools, and validating their contracts.
  #
  # This module is what an adapter gem names for all three. `Registry` and `VersionGroup` beneath it are
  # storage an adapter reaches THROUGH these methods rather than naming directly — the registry in
  # particular is free to change how membership is stored, and a `VersionGroup` arrives as `versions`'
  # return value.
  #
  # The two other constants beneath it ARE adapter-facing, and an adapter names each directly: `Invoker`,
  # the sanctioned path for running an Axn as a tool (docs/reference/tool-invoker.md), and `AdapterRoots`,
  # the opt-in directory-membership mixin an adapter extends onto its own config module
  # (docs/recipes/authoring-tool-adapters.md).
  #
  # `for` is a keyword in statement position, so every call inside axn writes the receiver
  # (`Axn::Tools.for(...)`); a receiverless `for(...)` would parse as a loop.
  module Tools
    # `Exception`'s own implementation, for a reporting path that must not run an exception's override of it
    # (see `_named_invalid_contract`). `exception` clones and sets a message without running an initializer.
    EXCEPTION_EXCEPTION = ::Exception.instance_method(:exception)
    private_constant :EXCEPTION_EXCEPTION

    class << self
      # Registers an adapter key, optionally with the config source the registry reads `tool_roots`
      # from. Idempotent, and a source-less re-registration never wipes a source already supplied
      # (see Registry#register_adapter).
      def register_adapter(key, config_source = nil)
        Registry.register_adapter(key, config_source)
      end

      # The registered adapter keys. The read-companion to `register_adapter`, and the set every
      # method here validates against.
      def adapters = Registry.adapters

      # An adapter's tools: the latest version per `tool_name` by default, sorted by `tool_name`;
      # every version (by name, then ascending version) with `all_versions: true`.
      def for(adapter, all_versions: false)
        Registry.members(_registered_adapter!(adapter), all_versions:)
      end

      # One logical tool's version group under `adapter` (`.all` ascending, `.latest`), or nil when
      # nothing matches — for an adapter resolving a single name rather than walking the enumeration.
      def versions(adapter, tool_name)
        Registry.version_group(_registered_adapter!(adapter), tool_name)
      end

      # Validates every tool axn's contract, once each, and raises on the first invalid one.
      #
      # A colliding or unrenderable property name is only harmful to a JSON projection, and for a tool axn the
      # projection is what an adapter hands a model — so the moment to learn about it is app setup, not a user's
      # tool call. This loads the configured tool directories and projects each tool once; the per-class memo means a
      # later `input_schema` from an adapter pays nothing.
      #
      # Under Rails this runs automatically (`config.after_initialize`, and again on each `config.to_prepare` so a
      # dev reload re-validates). Without Rails there is no boot to hook, so an app calls this itself — typically
      # right after requiring its action files. Nothing else changes if it is never called: the same errors still
      # raise on first projection.
      #
      # WHAT THIS COVERS, precisely — the guarantee is only as wide as enumeration.
      #
      # Membership is the union of a directory grant and a DECLARATION grant (`Registry#member?`), and enumeration
      # honors both: a class that declares `tool` is enumerated with no tool root configured at all. What it cannot
      # see is a class that is not LOADED yet, since it walks the classes the registry has recorded. So:
      #
      # - Nothing at all is validated unless at least one tool adapter is registered. With no adapter there are no
      #   tool roots and no membership to test, so this is a no-op — an app that expects setup validation must
      #   register the adapter its tools are for.
      # - A tool inside a configured tool root is loaded here (`ensure_loaded!`) and validated, declaration-granted
      #   or directory-granted alike.
      # - A `tool`-DSL axn OUTSIDE every configured root is validated only if something already loaded it. Under
      #   eager loading (production) everything is loaded, so it is covered; in a lazily-loading development
      #   environment it is not, and falls back to validating on first projection.
      # - Under Rails, Zeitwerk's `eager_load_dir` loads a directory as one unit (it has no public API to load a
      #   managed file in isolation), so a file that raises aborts the rest of THAT directory — warn-logged by the
      #   registry, and the siblings it skipped are not validated here.
      #
      # None of these makes an invalid contract reachable with no error at all: every gap falls back to the first
      # projection, which is where every non-tool axn is validated anyway.
      def validate_contracts!
        Registry.tool_classes.each do |klass|
          # BOTH sides go through PropertyNames rather than through `input_schema`/`output_schema`. Those names
          # belong to the class, and an adapter base that already defines them keeps them (see
          # Core::SchemaReflection) — so a tool subclassing its adapter's base class, which is the ordinary shape
          # of one, would have had its transport reader called and its contract validated by nothing at all.
          # PropertyNames performs the same builds and the same validations against axn's own projections, and the
          # outbound call additionally records the verdict `render` reads — so a tool validated at setup also
          # renders without paying for an output-schema build on its first result.
          Axn::Internal::Reflection::PropertyNames.validate_inbound!(klass)
          Axn::Internal::Reflection::PropertyNames.validate_outbound!(klass)
        rescue Axn::ContractViolation, ArgumentError => e
          # Named, because this runs over every tool at once: the underlying error describes the property and the
          # declarations that collide, but at boot the first thing an author needs is WHICH tool. Both families are
          # caught: a collision is an Axn::ContractViolation, an unrenderable name or an oversized schema an
          # ArgumentError. Either is reported as ITSELF, renamed — except where renaming would mean running the
          # exception's own code, which surfaces as Axn::Tools::InvalidContract (see _named_invalid_contract).
          # `cause:` explicitly, rather than leaving it to `$!`: reading a hostile `#message` means rescuing inside
          # this rescue, and Ruby does not restore `$!` to `e` afterwards — so the implicit cause was nil on exactly
          # the degraded paths where knowing the original matters most.
          raise _named_invalid_contract(klass, e), cause: e
        end
        nil
      end

      private

      # Symbolizes and vets the adapter key, so a typo names the mistake instead of quietly
      # enumerating nothing.
      def _registered_adapter!(adapter)
        adapter = adapter.to_sym
        unless Registry.adapters.include?(adapter)
          raise ArgumentError, "#{adapter.inspect} is not a registered tool adapter (registered: #{Registry.adapters.to_a.inspect})"
        end

        adapter
      end

      # The exception to report for `klass` — the contract failure itself, renamed to say which tool it came from.
      #
      # This is a REPORTING path, so every method it needs is one the exception's own class may override, and an
      # override that raises (outside StandardError included) would replace the failure being reported with the
      # offending class's exception, at boot, with nothing left naming the tool. Three rules keep it bounded, and
      # together they are the whole design:
      #
      # 1. Every dispatch of the exception's own code sits behind a guard (see `Internal::ExceptionMessage`). What a guard
      #    cannot cover is the 0-arg `#exception` that `raise` itself makes on whatever object it is handed — Ruby
      #    has no re-raise that skips it, a bare `raise` in a rescue included — so that dispatch is AVOIDED instead:
      #    the object handed to `raise` is only ever the original when its class does not own `#exception`.
      # 2. The decision is made by OWNERSHIP, not by behavior (`NativeMethods.native_exception_reporting?`). An
      #    exception that has already been raised once proves nothing about the second call: an `#exception` that
      #    answers itself the first time and raises the second defeated exactly that argument, because
      #    `Exception#exception(message)` clones and `raise` then asks the CLONE.
      #
      # 3. Every foreign STRING it writes into the message is RENDERED into UTF-8 rather than joined to it, through
      #    the one path axn renders foreign text with (`Internal::Reflection::PropertyNames`). A guarded dispatch is only half
      #    of what a report needs: a `#message` that behaves perfectly and returns a String whose bytes are not
      #    UTF-8-compatible — the stored message of an ordinary ArgumentError is enough, no override required — made
      #    the interpolation itself raise Encoding::CompatibilityError, destroying the contract failure at boot and
      #    losing the tool name, by a path both rules above cover fully. Neither of the two foreign strings here is
      #    exempt: the tool's own name is a constant path, and a constant may hold non-UTF-8 bytes too.
      #
      # So a class that owns none of `#exception` or the duplication hooks (the overwhelmingly common case, an
      # ordinary ArgumentError or DuplicateFieldError included) is renamed and reported as itself, class and state
      # intact, through a BOUND `Exception#exception`: the C implementation clones the object and sets the message,
      # running no initializer, where a dispatched `exception` is caller code free to return a different object or to
      # raise. Naming the CLASS (`raise e.class, message`) is a third thing and worse than either — it CONSTRUCTS an
      # instance, which fails outright for any exception whose initializer takes more than a message
      # (`Axn::Extensions::Serialization::UnserializableValue` requires `path:`/`value:`), destroying both the
      # contract error and the class the wrapper promised to preserve.
      #
      # Anything else — an owned `#exception`, an owned duplication hook, a frozen exception whose clone cannot take
      # a new message — is reported as `Axn::Tools::InvalidContract`, naming the tool, repeating the original's message,
      # and carrying the original as `cause`. Only the CLASS degrades there, and `#message` is a separate question:
      # an exception that builds its message from its state keeps that message on either branch.
      def _named_invalid_contract(klass, error)
        tool = Axn::Internal::Reflection::PropertyNames.renderable_module_name(klass)
        reason = Axn::Internal::ExceptionMessage.of(error)
        unless Axn::Internal::NativeMethods.native_exception_reporting?(error)
          return InvalidContract.new(tool:, reason:, original_class: Axn::Internal::ClassName.of(error))
        end

        EXCEPTION_EXCEPTION.bind_call(error, "#{tool} has an invalid tool contract — #{reason}")
      end
    end
  end
end
