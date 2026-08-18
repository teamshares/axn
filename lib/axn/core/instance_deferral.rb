# frozen_string_literal: true

module Axn
  module Core
    # `include Axn` puts axn's user-facing helpers in modules included into the user's class, and Ruby places
    # those above the superclass — so an `ApplicationService#log` would lose to axn's with nothing said. Where
    # the user's own hierarchy already owns one of the surrenderable names, axn steps aside instead.
    #
    # Stepping aside cannot be a non-definition: the sugar modules are shared by every action class, so there is
    # no per-class version of them to leave a name out of. It is instead one anonymous module per colliding
    # class, included last so it outranks axn's, holding a wrapper that `bind_call`s the definer's own
    # UnboundMethod. Classes with no collision get no module and no extra frame.
    #
    # The names axn CANNOT step aside for live here too (`assert_dispatchable_names_free!`), so which names axn
    # yields and which it refuses outright are one subject in one place rather than two.
    module InstanceDeferral
      DEFERRALS_IVAR = :@__axn_instance_deferrals
      KERNEL_IVAR_GET = ::Kernel.instance_method(:instance_variable_get)
      KERNEL_IVAR_SET = ::Kernel.instance_method(:instance_variable_set)
      private_constant :KERNEL_IVAR_GET, :KERNEL_IVAR_SET

      NO_DEFERRALS = {}.freeze

      CHECKED_IVAR = :@__axn_dispatchable_names_checked

      # `Axn::Internal::NameOwnership::UNSURRENDERABLE` names what is dispatched on the action BY NAME from
      # outside the module that defines it, so axn cannot step aside for an inherited version the way it does
      # for the helpers — and taking one silently is worse than refusing it: an action whose inherited `call` is
      # shadowed reports success for code that never ran.
      #
      # Asked at execution rather than at include time because only the finished class answers it. A class may
      # legitimately define one of these itself AFTER `include Axn` — `Axn::Factory` builds exactly that shape —
      # and its own definition outranks both the inherited one and axn's, so an include-time check would refuse a
      # legal build. `Core::ClassMethods#call` is the only funnel there is; nothing reaches `_run` around it.
      #
      # Two questions, because either answer alone permits the wrong verdict: axn must be the definition that
      # ANSWERS (a `def call` of the author's own takes the name over on its own terms, whether it appears in the
      # class body or in a module included after `include Axn`), and there must be an inherited declaration for it
      # to be standing in front of.
      #
      # The memo is a class-level ivar, which a subclass does not inherit, so a subclass re-checks itself. That
      # is what it needs: it may have introduced a definition of its own, or a new superclass in between.
      def self.assert_dispatchable_names_free!(klass)
        return if KERNEL_IVAR_GET.bind_call(klass, CHECKED_IVAR)

        Axn::Internal::NameOwnership::UNSURRENDERABLE.each do |name|
          next unless MethodShadowing.core_definition_answers?(klass, name)

          owner = MethodShadowing.inherited_definer(klass, name)
          next if owner.nil?

          raise Axn::ContractViolation::UnsurrenderableInheritedMethod.new(klass:, name:, owner:)
        end

        KERNEL_IVAR_SET.bind_call(klass, CHECKED_IVAR, true)
      end

      # Bound rather than dispatched, and stored in an ivar rather than a class method, for the same reason the
      # rest of this area is: whatever axn reads back has to be axn's own, on a class whose method table the
      # user owns. An ivar carries no dispatchable name.
      def self.install(base)
        deferrals = _collect(base)
        return NO_DEFERRALS if deferrals.empty?

        shim = ::Module.new
        deferrals.each_value do |(_definer, impl, visibility)|
          Axn::Internal::NativeMethods.define_own_instance_method(shim, impl.name) do |*args, **kwargs, &blk|
            impl.bind_call(self, *args, **kwargs, &blk)
          end
          # `define_method` defines public, so without this a definer's `private def log` would come back out of
          # the deferral as part of the action's public surface — the opposite of stepping aside.
          Axn::Internal::NativeMethods.set_declared_visibility(shim, impl.name, visibility)
        end
        Axn::Internal::NativeMethods.include_module(base, shim)

        definers = deferrals.transform_values(&:first)
        KERNEL_IVAR_SET.bind_call(base, DEFERRALS_IVAR, { shim:, definers: })
        definers
      end

      # Which module axn stepped aside for, per name. The recorded answer rather than a fresh walk: once the
      # shim is installed it is itself the nearest declaration of the name, so a re-walk would report the shim.
      def self.definers(klass) = _state(klass)&.fetch(:definers) || NO_DEFERRALS

      def self.shim(klass) = _state(klass)&.fetch(:shim)

      # The nearest `{shim:, definers:}` in `klass`'s ancestry, or nil, for a caller that only ASKS who a name
      # belongs to. `install` runs on the class that includes Axn, so a subclass of an action inherits the shim in
      # its ancestry while owning no record — asked about its own record alone, it would report the anonymous shim
      # as the owner of a name its base class actually declares.
      #
      # Kept apart from `shim`/`definers` rather than folded into them, because those two are what a caller that
      # MUTATES a record must use: removing a wrapper from an ancestor's shim, or dropping a name from its map,
      # would take the helper away from that ancestor and from every other class beneath it. Own record to change,
      # nearest record to read.
      def self.nearest_record(klass)
        Axn::Internal::NativeMethods.module_ancestors(klass).each do |mod|
          state = _state(mod)
          return state unless state.nil?
        end
        nil
      end

      def self._state(klass) = KERNEL_IVAR_GET.bind_call(klass, DEFERRALS_IVAR)
      private_class_method :_state

      # Captured — implementation and visibility both — at include time, which cuts two ways and deliberately
      # so. A definer reopened afterwards cannot silently retarget a deferral the class already committed to;
      # by the same token, a body redefined on that definer, or a module `prepend`ed to it, AFTER the action
      # class was defined is not picked up, because the wrapper keeps calling the implementation that was there
      # at include time where a plain dispatch would reach the new one. A Zeitwerk reload re-creates the action
      # class and so re-captures, which covers the common Rails path; a post-boot monkeypatch or an
      # instrumentation `prepend` does not.
      def self._collect(base)
        MethodShadowing.deferrable_names.each_with_object({}) do |name, acc|
          definer = MethodShadowing.inherited_definer(base, name)
          next if definer.nil?

          impl = Axn::Internal::NativeMethods.declared_instance_method(definer, name)
          next if impl.nil?

          acc[name] = [definer, impl, Axn::Internal::NativeMethods.declared_visibility(definer, name)]
        end
      end
      private_class_method :_collect
    end
  end
end
