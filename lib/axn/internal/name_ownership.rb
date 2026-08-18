# frozen_string_literal: true

require "axn/internal/text"
require "axn/internal/reflection/property_names"

module Axn
  module Internal
    # Whether a declared reader may take a name, decided by who currently OWNS it rather than by a
    # list of names kept by hand.
    #
    # A declared reader is defined directly on the action class (and the field's value is read off a
    # reader on the inbound facade's singleton), so it outranks everything — axn's helpers, Ruby's own
    # methods, and anything the user wrote. Surrendering an axn CONVENIENCE is fine and deliberate:
    # internals never dispatch those names (they bind through Internal::ActionState), so the cost is the
    # helper and nothing more. Surrendering anything else is not, and is refused at declaration, naming
    # the owner.
    module NameOwnership
      # Axn's user-facing sugar — the surface a declaration may take over. Modules, not names: a helper
      # added to one of these is covered without editing anything here.
      #
      # Axn::Core::AmbientContext is deliberately absent. `ambient_context` is not a convenience but a
      # sentinel: the subfield resolver decides whether a parent is the ambient hash by comparing the
      # route's root against AmbientContext::PARENT, so a field that took the name would be answered by
      # the ambient branch and hand back the ambient context instead of the declared value — a wrong
      # answer rather than a lost helper.
      SURRENDERABLE_OWNERS = [
        Axn::Core,
        Axn::Core::Contract::InstanceMethods,
        Axn::Core::Logging::InstanceMethods,
      ].freeze

      # Dispatched on the object by name from outside the module that defines them, where an
      # UnboundMethod cannot stand in: Ruby invokes `initialize` from `new`, the executor invokes the
      # action body through `call`, and `.call` enters through `_run`. Taking one of these does not cost
      # a helper — it makes the action never run, or never build.
      UNSURRENDERABLE = %i[call _run initialize].freeze

      module_function

      # nil when `name` is free to take; otherwise what stands in the way — the owning Module, or a
      # Symbol for a name no owner could make available.
      def conflict_for(klass, name)
        name = name.to_sym
        return :unsurrenderable if UNSURRENDERABLE.include?(name)

        owner = owner_of(klass, name)
        return nil if owner.nil?
        return internal_name?(name) ? :internal : nil if surrenderable?(owner)

        owner
      end

      # Private methods count: they are as shadowable as public ones (a generated reader lands in front
      # of either), and several of them — `internal_context`, `_build_context_facade` — are exactly the
      # ones whose loss would matter.
      # Read natively: `klass` is the CALLER's action class, so a singleton `method_defined?` or
      # `instance_method` of its own — a metaprogramming base is the realistic shape — would otherwise
      # decide this guard's verdict, and one answering "free" admits the declaration whose reader then
      # replaces `Object#class`. `declared_instance_method` is one bound lookup at any visibility, which is
      # both questions the two predicates used to ask.
      def owner_of(klass, name)
        Axn::Internal::NativeMethods.declared_instance_method(klass, name.to_sym)&.owner
      end

      # What `klass` ITSELF contributes under `name` — its own ancestors up to (not including) Object,
      # so Ruby's universal methods are excluded. For a second receiver that is not where the user's
      # helpers live, that is the whole of the question: `Object`/`Kernel` names are judged once, on the
      # action class, where a reader also lands and where nothing of axn's overrides them. Asking them
      # here too would refuse `warn` — a logging helper axn owns on the action and the facade never
      # calls — for a collision that exists only in Kernel.
      def owner_within(klass, name)
        owner = owner_of(klass, name)
        return nil if owner.nil?
        return nil unless Axn::Internal::NativeMethods.module_ancestors(klass).take_while { |mod| mod != ::Object }.include?(owner)

        owner
      end

      def surrenderable?(owner) = SURRENDERABLE_OWNERS.include?(owner)

      # A leading underscore is how axn marks its own internals, and those sit in the same modules as
      # the sugar. They are not part of the surface a declaration may take: axn's own code reaches them
      # by name (`forward!` calls `_forward_to_class`, the step orchestrator calls
      # `_propagate_sub_result_outcome!`), so surrendering one costs the framework rather than the user.
      # Derived from the convention rather than listed, so an internal helper added to a sugar module
      # later is covered without editing anything here.
      def internal_name?(name) = name.to_s.start_with?("_")

      # `name` is optional and used only to locate an anonymous owner's source (see owner_label).
      # Every name and module written into the prose below goes through `PropertyNames`' renderers first.
      # A declared name is the AUTHOR's bytes and only has to be ASCII-COMPATIBLE, so a Latin-1 name beside
      # a UTF-8 module name would otherwise raise `Encoding::CompatibilityError` out of the message and hide
      # the declaration error it was written to report.
      def describe(conflict, name: nil)
        name = Axn::Internal::Reflection::PropertyNames.renderable_label(name) unless name.nil?

        case conflict
        when :unsurrenderable then "axn itself (the framework dispatches that name to run the action)"
        when :internal then "axn's internals (a leading underscore marks a name axn dispatches on itself)"
        when :pattern_match_key
          "the keys a Result reports for pattern matching (an exposure of that name would be bound by " \
          "`case result in { #{name}: }` instead of the outcome)"
        when :settlement_control_kwarg
          "a control keyword of `fail!`/`done!` (it binds ahead of their exposures, so `fail!(\"...\", " \
          "#{name}: value)` would set the control and leave the exposure unset)"
        else "#{owner_label(conflict, name)} (not axn's to surrender)"
        end
      end

      # Bound rather than dispatched, because this runs while an error message is being COMPOSED: a class
      # that defines its own `self.name`, `inspect`, or `instance_method` would otherwise have that code
      # run here, and one that raises would replace the declaration error being reported with its own
      # failure. `Module#name` is nil for an anonymous module, which is exactly the branch below.
      MODULE_NAME = ::Module.instance_method(:name)
      MODULE_INSTANCE_METHOD = ::Module.instance_method(:instance_method)
      private_constant :MODULE_NAME, :MODULE_INSTANCE_METHOD

      # An anonymous module — the shape a monkeypatch of Object usually takes — inspects as
      # `#<Module:0x…>`, which tells an author nothing about what they collided with. Point at where the
      # method was written instead; the owner is by definition the module that defines it.
      def owner_label(owner, name)
        return Axn::Internal::Reflection::PropertyNames.renderable_module_name(owner) if MODULE_NAME.bind_call(owner)
        return _anonymous_label(owner) if name.nil?

        file, line = MODULE_INSTANCE_METHOD.bind_call(owner, name).source_location
        return _anonymous_label(owner) unless file

        "an anonymous module (#{Axn::Internal::Text.renderable(file)}:#{line})"
      rescue ::StandardError
        # Naming where an anonymous owner came from is a courtesy; losing it must not cost the caller the
        # collision error itself.
        _anonymous_label(owner)
      end

      # `Module#to_s` bound, which answers "#<Module:0x…>" for an anonymous module and never nil.
      def _anonymous_label(owner) = Axn::Internal::Reflection::PropertyNames.renderable_module_name(owner)
    end
  end
end
