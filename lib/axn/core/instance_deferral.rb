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
    module InstanceDeferral
      DEFERRALS_IVAR = :@__axn_instance_deferrals
      KERNEL_IVAR_GET = ::Kernel.instance_method(:instance_variable_get)
      KERNEL_IVAR_SET = ::Kernel.instance_method(:instance_variable_set)
      private_constant :KERNEL_IVAR_GET, :KERNEL_IVAR_SET

      NO_DEFERRALS = {}.freeze

      # Bound rather than dispatched, and stored in an ivar rather than a class method, for the same reason the
      # rest of this area is: whatever axn reads back has to be axn's own, on a class whose method table the
      # user owns. An ivar carries no dispatchable name.
      def self.install(base)
        deferrals = _collect(base)
        return NO_DEFERRALS if deferrals.empty?

        shim = ::Module.new
        deferrals.each_value do |(_definer, impl)|
          Axn::Internal::NativeMethods.define_own_instance_method(shim, impl.name) do |*args, **kwargs, &blk|
            impl.bind_call(self, *args, **kwargs, &blk)
          end
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

      def self._state(klass) = KERNEL_IVAR_GET.bind_call(klass, DEFERRALS_IVAR)
      private_class_method :_state

      # Captured as an UnboundMethod at include time, so a later reopening of the definer cannot silently
      # retarget a deferral the class already committed to.
      def self._collect(base)
        MethodShadowing.deferrable_names.each_with_object({}) do |name, acc|
          definer = MethodShadowing.inherited_definer(base, name)
          next if definer.nil?

          impl = Axn::Internal::NativeMethods.declared_instance_method(definer, name)
          acc[name] = [definer, impl] unless impl.nil?
        end
      end
      private_class_method :_collect
    end
  end
end
