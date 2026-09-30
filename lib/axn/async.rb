# frozen_string_literal: true

# Loaded before adapters so adapter files can register their ownership predicates at require time.
require "axn/async/ownership"
require "axn/async/adapters"
require "axn/async/batch_enqueue"
require "axn/async/retry_context"

module Axn
  module Async
    extend ActiveSupport::Concern

    # The class ivar holding, per adapter module, the `_enqueue_async_job` that class's own declaration installed.
    INSTALLED_ENQUEUE_HOOKS = :@_axn_async_installed_enqueue_hooks
    # The class ivar holding, per adapter module, the names of the class-side helpers that class's own inclusions of
    # it added (see `_class_side_helpers_added`).
    ADAPTER_HELPER_NAMES = :@_axn_async_adapter_helper_names
    # The class ivar holding, per adapter module, the class-side modules that class's own inclusions of it added.
    ADAPTER_CLASS_SIDE_MODULES = :@_axn_async_adapter_class_side_modules
    private_constant :INSTALLED_ENQUEUE_HOOKS, :ADAPTER_HELPER_NAMES, :ADAPTER_CLASS_SIDE_MODULES

    included do
      class_attribute :_async_adapter, :_async_config, :_async_config_block, instance_accessor: false, default: nil
      # True when the adapter was applied via the global default (call_async/worker hook)
      # rather than an explicit `async ...` in the action body. The Sidekiq adapter uses this
      # to decide between a per-action Worker subclass (explicit: reconstructable in a worker)
      # and the shared generic Worker (global default: no per-action body to reconstruct).
      class_attribute :_async_via_default, instance_accessor: false, default: false
      class_attribute :_async_exception_reporting, instance_accessor: false, default: nil

      # Include batch enqueue functionality
      include BatchEnqueue
      extend BatchEnqueue::DSL
    end

    class_methods do
      # Sets the exception reporting mode for this action class, overriding the global config.
      # This allows library authors to configure exception reporting behavior for their actions
      # without affecting the host app's global Axn.config.async_exception_reporting setting.
      #
      # @param mode [Symbol, nil] One of :every_attempt, :first_and_exhausted, or :only_exhausted.
      #   Use nil to clear the per-class override and fall back to the global config.
      # @raise [ArgumentError] if mode is not a valid option
      #
      # @example
      #   class SlackSender::Base
      #     include Axn
      #     async_exception_reporting :only_exhausted
      #   end
      def async_exception_reporting(mode)
        if mode.nil?
          self._async_exception_reporting = nil
          return
        end

        unless Axn::Configuration::ASYNC_EXCEPTION_REPORTING_OPTIONS.include?(mode)
          raise ArgumentError,
                "async_exception_reporting must be one of: #{Axn::Configuration::ASYNC_EXCEPTION_REPORTING_OPTIONS.join(', ')}"
        end

        self._async_exception_reporting = mode
      end

      # `via_default: true` is set only by the default-application paths (call_async /
      # _ensure_default_async_configured). An explicit `async :sidekiq` from a class body — even
      # on a subclass that inherited `_async_via_default = true` — passes false and clears the
      # marker, so the Sidekiq adapter builds/uses the per-action worker (honoring explicit config)
      # rather than the shared DefaultWorker.
      def async(adapter = nil, via_default: false, **config, &block)
        adapter = Adapters.canonical(adapter)
        if adapter.nil?
          # Use default configuration, but preserve any user-provided block/config
          adapter = Adapters.canonical(Axn.config._default_async_adapter)
          config = Axn.config._default_async_config.merge(config)
          block ||= Axn.config._default_async_config_block
        end

        prior = [_async_adapter, _async_config, _async_config_block, _async_via_default]
        self._async_adapter = adapter
        self._async_config = config
        self._async_config_block = block
        self._async_via_default = via_default

        if adapter == false
          include Adapters.find(:disabled)
          return
        end

        # Look up adapter in registry
        adapter_module = Adapters.find(adapter)
        _refuse_inert_redeclaration!(adapter, adapter_module, prior) unless _include_async_adapter(adapter_module)
        # Per-action setup that must run on EVERY `async <adapter>` declaration — including a
        # subclass re-declaring it, where `include` is a no-op (module already inherited) so the
        # adapter's `included do` won't fire. The Sidekiq adapter uses this to (re)build the
        # action's per-action Worker subclass with the current config.
        adapter_module._configure_action!(self) if adapter_module.respond_to?(:_configure_action!)
      end

      def call_async(**kwargs)
        # Set up default async configuration if none is set
        if _async_adapter.nil?
          async Axn.config._default_async_adapter, via_default: true, **Axn.config._default_async_config, &Axn.config._default_async_config_block
          # Call ourselves again now that the adapter is included
          return call_async(**kwargs)
        end

        # Skip notification and logging for disabled adapter (it will raise immediately)
        return _enqueue_with_declared_adapter(kwargs) if _async_adapter == false

        # Emit notification for async call
        _emit_call_async_notification(kwargs)

        # Log async invocation if logging is enabled
        adapter_name = _async_adapter_name_for_logging
        _log_async_invocation(kwargs, adapter_name:) if adapter_name && _auto_log_before_level

        _enqueue_with_declared_adapter(kwargs)
      end

      # Ensure default async is applied when the class is first instantiated
      # This is important for Sidekiq workers which load the class in a separate process
      def new(*args, **kwargs)
        _ensure_default_async_configured
        super
      end

      private

      def _emit_call_async_notification(kwargs)
        # Best-effort so a subscriber error never interferes with async enqueueing. `self` is the
        # action class, which responds to :warn (Core::Logging), so it is the warn-target.
        Axn::Extensions.best_effort("emitting notification for axn.call_async", action: self) do
          resource = resolved_axn_name
          # Use dup to ensure kwargs modifications don't affect the notification payload
          payload = { resource:, action_class: self, kwargs: kwargs.dup, adapter: _async_adapter_name }

          ActiveSupport::Notifications.instrument("axn.call_async", payload)
        end
      end

      def _log_async_invocation(kwargs, adapter_name:)
        Axn::Internal::CallLogger.log_at_level(
          self,
          level: _auto_log_before_level,
          message_parts: ["Enqueueing async execution via #{adapter_name}"],
          join_string: " with: ",
          before: _async_log_separator,
          prefix: "[#{resolved_axn_name}]",
          error_context: "logging async invocation",
          context_direction: :inbound,
          context_data: kwargs,
        )
      end

      def _async_log_separator
        return if Axn.config.env.production?
        return if Axn::Util::ExecutionContext.background?
        return if Axn::Util::ExecutionContext.console?

        "\n------\n"
      end

      # Hook method that must be implemented by async adapter modules.
      #
      # Adapters MUST:
      # - Implement this method with adapter-specific enqueueing logic
      # - NOT override `call_async` (the base implementation handles notifications, logging, and delegates here)
      #
      # `call_async` reaches it through `_enqueue_with_declared_adapter`, never by plain method lookup.
      #
      # @param kwargs [Hash] The keyword arguments to pass to the action when it executes
      # @return The result of enqueueing (typically a job ID or similar, adapter-specific)
      def _enqueue_async_job(kwargs)
        # This will be overridden by the included adapter module
        raise NotImplementedError, "No async adapter configured. Use e.g. `async :sidekiq` or `async :active_job` to enable background processing."
      end

      # Runs the `_enqueue_async_job` this class's own adapter declaration installed, not whichever one method
      # lookup finds. A class keeps every adapter module it or an ancestor ever included, and re-including one
      # adds nothing, so lookup finds the adapter included most recently, which is not necessarily
      # `_async_adapter`. For example, a subclass returning to `:sidekiq` under an `:active_job` parent would
      # otherwise enqueue through ActiveJob.
      #
      # `_include_async_adapter` records what each declaration installed. A class whose own declaration installed
      # nothing (re-including an adapter an ancestor already added) uses the nearest ancestor that recorded one
      # for the same adapter. With no record anywhere, plain lookup decides. `async false` runs the Disabled
      # adapter's hook, which is never mixed into the class.
      def _enqueue_with_declared_adapter(kwargs)
        hook = _async_adapter == false ? _disabled_enqueue_hook : _installed_enqueue_hook(Adapters.find(_async_adapter))
        return _enqueue_async_job(kwargs) unless hook

        hook.bind_call(self, kwargs)
      end

      def _disabled_enqueue_hook
        Axn::Internal::NativeMethods.declared_instance_method(Adapters::Disabled::ClassMethods, :_enqueue_async_job)
      end

      def _installed_enqueue_hook(adapter_module)
        klass = self
        while klass
          installed = Axn::Internal::NativeMethods.ivar_get(klass, INSTALLED_ENQUEUE_HOOKS)
          hook = installed && installed[adapter_module]
          return hook if hook

          klass = klass.superclass
        end
        nil
      end

      # Includes the adapter and records what that inclusion installed: the `_enqueue_async_job` this class
      # reaches afterwards, if the inclusion changed it. That covers every way an adapter can supply the hook, and
      # it also covers an adapter whose `included` hook builds a module per class from `_async_config`. A plain
      # module's `included` runs on every `include`, so it can still install a hook when the module was already
      # in the ancestry, and that hook is recorded for this class alone.
      #
      # Returns whether the inclusion changed the reachable hook. It also records the names of the class-side
      # helpers the inclusion added, which `_warn_on_colliding_adapter_helpers` compares against other adapters'.
      def _include_async_adapter(adapter_module)
        singleton = Axn::Internal::NativeMethods.module_singleton_class(self)
        before_ancestors = Axn::Internal::NativeMethods.module_ancestors(singleton)
        before_own = _own_class_side_methods(singleton)
        before = _reachable_enqueue_hook
        include adapter_module
        after = _reachable_enqueue_hook
        added_modules = Axn::Internal::NativeMethods.module_ancestors(singleton) - before_ancestors
        unless added_modules.empty?
          record = _async_class_record(ADAPTER_CLASS_SIDE_MODULES)
          record[adapter_module] = (record[adapter_module] || []) | added_modules
        end
        helpers = _class_side_helpers_added(singleton, added_modules, before_own)
        unless helpers.empty?
          _warn_on_colliding_adapter_helpers(adapter_module, helpers)
          record = _async_class_record(ADAPTER_HELPER_NAMES)
          record[adapter_module] = (record[adapter_module] || []) | helpers
        end
        return false if after.nil? || after == before

        _async_class_record(INSTALLED_ENQUEUE_HOOKS)[adapter_module] = after
        true
      end

      # The names of the class-side helpers an inclusion added, other than the hook. An adapter adds them two ways:
      # as modules in the singleton ancestry (a Concern's ClassMethods, a module its `included` extends), or straight
      # into the singleton class's own table (`define_singleton_method` in its `included`). An own-table entry counts
      # when it is new or now resolves to a different definition than before, so a helper that replaces another
      # adapter's under the same name is counted, and a class method the class defined itself is not.
      def _class_side_helpers_added(singleton, added_modules, before_own)
        from_modules = added_modules.flat_map { |mod| Axn::Internal::NativeMethods.own_instance_method_names(mod) }
        from_own_table = _own_class_side_methods(singleton).filter_map { |name, method| name unless before_own[name] == method }
        (from_modules | from_own_table) - [:_enqueue_async_job]
      end

      def _own_class_side_methods(singleton)
        Axn::Internal::NativeMethods.own_instance_method_names(singleton).to_h do |name|
          [name, Axn::Internal::NativeMethods.declared_instance_method(singleton, name)]
        end
      end

      def _async_class_record(ivar)
        Axn::Internal::NativeMethods.ivar_get(self, ivar) ||
          Axn::Internal::NativeMethods.ivar_set(self, ivar, {}.compare_by_identity)
      end

      # A declaration that installed no hook, where no class in the chain recorded one for the declared adapter, runs
      # whatever the class already reaches (see `_enqueue_with_declared_adapter`). That is refused only when the
      # reachable hook is provably ANOTHER adapter's and not this one's: see `_hook_owned_by?` and
      # `_hook_owned_by_another_adapter?`. A hook that belongs to the declared adapter (its module was already
      # present, included by hand or through an ancestor) serves the declaration; a hook whose ownership cannot
      # be read is given the benefit of the doubt. Checked only for a re-declaration that asks for something
      # different: a first declaration, or one repeating the previous adapter and config, is left alone.
      def _refuse_inert_redeclaration!(adapter, adapter_module, prior)
        prior_adapter, prior_config, prior_block, prior_via_default = prior
        return if prior_adapter.nil?
        return if prior_adapter == adapter && prior_config == _async_config && prior_block.equal?(_async_config_block)
        return if _installed_enqueue_hook(adapter_module)

        hook = _reachable_enqueue_hook
        return if hook.nil? || _hook_owned_by?(hook, adapter_module) || !_hook_owned_by_another_adapter?(hook, adapter_module)

        message = _inert_redeclaration_message(adapter)
        self._async_adapter = prior_adapter
        self._async_config = prior_config
        self._async_config_block = prior_block
        self._async_via_default = prior_via_default
        raise ArgumentError, message
      end

      # Whether `hook` is the adapter's own: recorded as the hook one of its declarations installed on this chain, or
      # defined in one of its class-side modules, meaning its `ClassMethods` and that module's ancestry, or a module
      # an inclusion of it added on this chain. Read from ownership alone (the method's owner), never by running it.
      def _hook_owned_by?(hook, adapter_module)
        return true if _async_chain_records(INSTALLED_ENQUEUE_HOOKS)[adapter_module] == hook

        owner = hook.owner
        _adapter_class_side_modules(adapter_module).any? { |mod| mod.equal?(owner) }
      end

      # Whether `hook` provably belongs to an adapter other than `adapter_module`, by the same reading.
      def _hook_owned_by_another_adapter?(hook, adapter_module)
        _async_chain_records(INSTALLED_ENQUEUE_HOOKS).each do |other, recorded|
          return true if !other.equal?(adapter_module) && recorded == hook
        end
        Adapters.all.each_value.any? do |other|
          !other.equal?(adapter_module) && Axn::Internal::Identity.kind?(other, ::Module) && _hook_owned_by?(hook, other)
        end
      end

      def _adapter_class_side_modules(adapter_module)
        class_methods = adapter_module.const_defined?(:ClassMethods, false) && adapter_module::ClassMethods
        declared = Axn::Internal::Identity.kind?(class_methods, ::Module) ? Axn::Internal::NativeMethods.module_ancestors(class_methods) : []
        recorded = []
        klass = self
        while klass
          recorded |= (Axn::Internal::NativeMethods.ivar_get(klass, ADAPTER_CLASS_SIDE_MODULES) || {}).fetch(adapter_module, [])
          klass = klass.superclass
        end
        declared | recorded
      end

      def _inert_redeclaration_message(adapter)
        hook = _reachable_enqueue_hook
        owner = hook&.owner
        by = _adapter_that_installed(hook)
        by_clause = by ? " (by the #{by.inspect} adapter)" : ""
        declaration = "`async #{adapter.inspect}` on #{_async_class_label}"
        fix = "Define the adapter's class-side methods in a module (e.g. a ClassMethods concern) so a later declaration can replace them."
        if owner && Axn::Internal::NativeMethods.module_singleton_class(self).equal?(owner)
          "#{declaration} can't take effect — `_enqueue_async_job` is defined directly on #{_async_class_label}#{by_clause} and shadows it. #{fix}"
        else
          source = (owner && Axn::Internal::NativeMethods.declared_module_name(owner)) || "an anonymous module"
          "#{declaration} can't take effect — #{_async_class_label} already reaches `_enqueue_async_job` through #{source}#{by_clause}, " \
            "and the #{adapter.inspect} adapter adds nothing that replaces it. Give each adapter its own class-side module " \
            "that defines its hook, so a later declaration can replace it."
        end
      end

      def _async_class_label = Axn::Internal::NativeMethods.declared_module_name(self) || "this anonymous class"

      # The registry key of the adapter whose declaration, on this class or an ancestor, recorded `hook`.
      def _adapter_that_installed(hook)
        return nil unless hook

        _async_chain_records(INSTALLED_ENQUEUE_HOOKS).each do |adapter_module, recorded|
          return Adapters.all.key(adapter_module) if recorded == hook
        end
        nil
      end

      # Per adapter module, every helper name its inclusions added on this class and its superclasses.
      def _adapter_helper_names_in_chain
        names = {}.compare_by_identity
        klass = self
        while klass
          (Axn::Internal::NativeMethods.ivar_get(klass, ADAPTER_HELPER_NAMES) || {}).each do |mod, added|
            names[mod] = (names[mod] || []) | added
          end
          klass = klass.superclass
        end
        names
      end

      # Per adapter module, the nearest record (this class first, then each superclass) held in `ivar`.
      def _async_chain_records(ivar)
        records = {}.compare_by_identity
        klass = self
        while klass
          (Axn::Internal::NativeMethods.ivar_get(klass, ivar) || {}).each { |mod, value| records[mod] = value unless records.key?(mod) }
          klass = klass.superclass
        end
        records
      end

      # A class-side helper the new adapter adds under a name another adapter on this class (or an ancestor)
      # already added: the adapter included later wins for both, so the other one silently calls the wrong
      # implementation. The hook itself is excluded; it is meant to be shared by name and is dispatched by adapter.
      def _warn_on_colliding_adapter_helpers(adapter_module, names)
        _adapter_helper_names_in_chain.each do |other, other_names|
          next if other.equal?(adapter_module)

          shared = names & other_names
          next if shared.empty?

          Axn::Extensions.best_effort("warning about colliding async adapter helpers", action: self) do
            Axn.config.logger.warn do
              "[Axn] #{_async_class_label}: the #{Adapters.all.key(adapter_module).inspect} and #{Adapters.all.key(other).inspect} async " \
                "adapters both define #{shared.map { |name| "`#{name}`" }.join(', ')} as class-side methods, so the one included " \
                "later answers for both. Prefix each adapter's helper names so they cannot collide."
            end
          end
        end
      end

      def _reachable_enqueue_hook
        singleton = Axn::Internal::NativeMethods.module_singleton_class(self)
        Axn::Internal::NativeMethods.declared_instance_method(singleton, :_enqueue_async_job)
      end

      def _async_adapter_name
        if _async_adapter.nil?
          "none"
        elsif _async_adapter == false
          "disabled"
        else
          _async_adapter.to_s
        end
      end

      def _async_adapter_name_for_logging
        return nil if _async_adapter.nil? || _async_adapter == false

        _async_adapter_name
      end

      def _ensure_default_async_configured
        # Only when the adapter is genuinely unset — an explicit `async false` (disabled) must be
        # left intact so callers (e.g. enqueue_all validation) reject it upfront rather than
        # silently defaulting it (false.present? is falsy, so guard on nil explicitly).
        return unless _async_adapter.nil?
        return unless Axn.config._default_async_adapter.present?

        async Axn.config._default_async_adapter, via_default: true, **Axn.config._default_async_config, &Axn.config._default_async_config_block
      end

      # Extracts and normalizes _async options from kwargs.
      # Returns normalized options hash (with string keys and converted durations) and removes _async from kwargs.
      #
      # @param kwargs [Hash] The keyword arguments (modified in place)
      # @return [Hash, nil] Normalized async options hash, or nil if no _async options present
      def _extract_and_normalize_async_options(kwargs)
        async_options = kwargs.delete(:_async) if kwargs[:_async].is_a?(Hash)
        _normalize_async_options(async_options) if async_options
      end

      # Normalizes _async options hash:
      # - Converts symbol keys to string keys
      # - Converts ActiveSupport::Duration values to integer seconds (for wait)
      # - Preserves Time objects (for wait_until)
      #
      # @param async_hash [Hash, nil] The async options hash
      # @return [Hash, nil] Normalized hash with string keys, or nil if input is not a hash
      def _normalize_async_options(async_hash)
        return nil unless async_hash.is_a?(Hash)

        normalized = {}
        async_hash.each do |key, value|
          string_key = key.to_s

          normalized[string_key] = case string_key
                                   when "wait"
                                     # Convert ActiveSupport::Duration to integer seconds
                                     value.respond_to?(:to_i) ? value.to_i : value
                                   else
                                     # Preserve wait_until and other keys/values as-is
                                     value
                                   end
        end

        normalized
      end
    end
  end
end
