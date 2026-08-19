# frozen_string_literal: true

require "axn/error"
require "axn/internal/identity"
require "axn/internal/native_methods"
require "axn/internal/text"

module Axn
  module Internal
    # The name of a value's class, derived WITHOUT dispatching anything the value can override.
    # An error message that names the offending value's class by calling `value.class` (or `inspect`)
    # runs the value's own code at the moment the error is being built, so the value can replace the
    # failure being reported with an exception of its own — and one outside StandardError then escapes
    # the `rescue StandardError` callers map these failures with, which is the escape naming the class
    # is meant to describe. A bound base implementation cannot be intercepted.
    #
    # Not dispatching is ALL this promises. What it returns is the constant path's own bytes, and a constant
    # may hold non-UTF-8 ones (`Object.const_set(:"Caf\xE9", Class.new)` is accepted, and `Module#to_s` hands
    # those bytes back), so interpolating the result into a UTF-8 message can still raise
    # Encoding::CompatibilityError from the reporting itself. A layer writing a class name into prose therefore
    # renders it, and the composition has one owner per question: `Internal::RenderedClassName` just below for a
    # VALUE's class, which `Internal::Rendering.class_name` delegates to and which the message paths built ON
    # this file (`UnserializableValue#message` and `UnserializableArgument#message` below,
    # `Internal::Reflection::Values.describe_key_classes`) reach directly; and `Internal::RenderedModuleName`
    # for a class or module named in its own right, which `Internal::Rendering.module_name` delegates to and
    # which `UnsurrenderableInheritedMethod` below reaches directly — plus `Internal::RenderedActionName` for
    # the one receiver those two do not cover, an ACTION class, whose name axn may have installed itself and
    # which `Internal::Rendering.action_name` delegates to — over `Internal::RenderedInstalledName`, the
    # dispatch-and-absorb core it shares with `Internal::Rendering.module_type_label`. The direction is
    # forced: the reflection and rendering layers require THIS file, so a reference from here up into either
    # would leave a message path NameError-ing under the standalone loads
    # `spec/axn/standalone_require_spec.rb` pins. The byte half they all compose through, `Internal::Text`, has
    # no requires of its own and sits below every one of them.
    module ClassName
      OBJECT_CLASS = ::Object.instance_method(:class)
      MODULE_TO_S = ::Module.instance_method(:to_s)
      private_constant :OBJECT_CLASS, :MODULE_TO_S

      # `Module#to_s` rather than `#name`, which is nil for an anonymous class; to_s always returns a
      # String ("#<Class:0x…>" there).
      def self.of(value) = MODULE_TO_S.bind_call(OBJECT_CLASS.bind_call(value))

      # The name of a class or module ITSELF, rather than of a value's class — for a message that names a
      # declared type. Same reasoning: a class can define its own `to_s`, and one that raises would replace
      # the failure being reported.
      def self.of_module(mod) = MODULE_TO_S.bind_call(mod)
    end

    # A caller-supplied value's CLASS written into prose, with both halves an error path owes composed: the
    # name comes from `ClassName` so nothing the value defines runs, and the bytes it answers with are
    # RENDERED, because a constant may hold non-UTF-8 ones (`Object.const_set(:"Caf\xE9", Class.new)` is
    # accepted and `Module#to_s` hands those back) and those cannot be joined to axn's UTF-8 prose at all.
    #
    # The ONE owner of that composition, and `Internal::Rendering.class_name` delegates to it. The dependency can
    # only run that way: `rendering.rb` requires this file, so a message path here that delegated UP to it would
    # be a require cycle — and LIFTING the composition onto `ClassName` instead breaks that module's promise never
    # to render anything (see its own header). Living here is neither, and it sits in the file every caller
    # already loads: every message below that names a caller-supplied value's class,
    # `Internal::Reflection::Values.describe_key_classes`, and `Rendering` itself.
    module RenderedClassName
      def self.of(value) = Text.renderable(ClassName.of(value))
    end

    # A caller-supplied value written into one of this file's messages, whatever it turns out to be.
    #
    # `Text.renderable` is String-only by contract — it binds String methods, so anything else is a
    # `TypeError` from the message path itself — and the exceptions here are PUBLIC classes whose kwargs a
    # caller fills in. `Axn::Tools::InvalidContract.new(tool: :foo, …)` is the shape that proves it: a Symbol
    # naming the tool is the obvious thing to pass, and it must render as `foo` rather than as an error about
    # rendering.
    #
    # So the type is decided by `case`/`when` (`Module#===`, a C-level check that runs none of the value's
    # code) and each branch renders what it can honestly get:
    #
    #   * a String, through the byte renderer, since its bytes are foreign too;
    #   * a Symbol, through its own `to_s` — the one dispatch here that needs no guard, because a Symbol can
    #     carry no override at all (`Symbol.new` is undefined, `allocate` raises, and `:x.singleton_class` is a
    #     TypeError), and then rendered, because a Symbol's bytes can be non-UTF-8 as readily as a String's;
    #   * anything else by its CLASS, which is a legible stand-in and cannot raise. Dispatching `to_s` on an
    #     arbitrary object is what a message path here must never do.
    module RenderedText
      def self.of(value)
        case value
        when ::String then Text.renderable(value)
        when ::Symbol then Text.renderable(value.to_s)
        else RenderedClassName.of(value)
        end
      end
    end

    # A class or module named in its OWN right — the module that declares a method, a declared `type:` — rather
    # than a value's class. `RenderedClassName` cannot stand in for it: handed a Module, it answers with that
    # Module's CLASS, so an owner named through it reads as "Class".
    #
    # `ClassName.of_module` binds `Module#to_s`, which is a TypeError on anything that is not a Module, so what
    # arrives is type-tested first — undispatched, since a caller filling in a public exception's kwarg is
    # exactly who might hand over something else, and a message path owes an answer rather than an error about
    # rendering. Anything else falls through to `RenderedText`, which names it by its class.
    module RenderedModuleName
      def self.of(mod) = Identity.kind?(mod, ::Module) ? Text.renderable(ClassName.of_module(mod)) : RenderedText.of(mod)
    end

    # A module's INSTALLED name — the one receiver whose name is read by DISPATCH rather than bound.
    #
    # Axn installs a `name` of its own on the classes it BUILDS (`Mountable::Helpers::ClassBuilder`,
    # `Axn::Factory`, `Strategies::Form`), and `Module#to_s` does not consult it, so a bound read answers
    # `#<Class:0x…>` or `#<Class:0x…>::Axns::Inner` where axn intends `AnonymousAxn_2980` or
    # `AnonymousClient_2980::Axns::Inner`. That override is axn's own naming mechanism rather than a caller's
    # lie, so binding past it trades the prose axn deliberately put there for an object address. Only a class
    # axn may have renamed gets this treatment; an owner or a caller's exception class named alongside it is
    # one axn never renames, and reading THOSE bound through `RenderedModuleName` is what keeps a foreign
    # `self.name` out of the message.
    #
    # The dispatch is ABSORBED rather than trusted, which is what lets the exception to binding hold without
    # handing the receiver a way out of the message path. Anything it yields that is not a String — nil, which
    # is what an anonymous class answers; another type, whose rendering would dispatch again; or a raise —
    # takes the fallback. `Exception` rather than `StandardError` around it on the same terms as
    # `Rendering.value_rendering`: the failure being composed has to win over anything the class's own reader
    # raises, and a `name` is not a path a signal travels through. The bytes that DO arrive are still rendered,
    # for the reason everything here is: a constant path may hold non-UTF-8 ones, and joining those to axn's
    # UTF-8 prose raises Encoding::CompatibilityError in place of the failure being reported.
    #
    # What an unavailable name degrades TO is the caller's policy, not this module's — a sentence about an
    # action and a sentence about a declared type want different words — so it arrives as a BLOCK, which also
    # keeps a fallback that costs something off the success path. A fallback that itself raises propagates;
    # axn's own two cannot, and a fallback is not a place to be clever.
    #
    # A non-Module receiver answers `RenderedText.of` exactly as `RenderedModuleName` does, since these are
    # reached from public exception kwargs a caller fills in and a message path owes an answer about the value
    # rather than an error about rendering it.
    module RenderedInstalledName
      def self.of(mod, &fallback)
        return RenderedText.of(mod) unless Identity.kind?(mod, ::Module)

        name = mod.name
        Identity.kind?(name, ::String) ? Text.renderable(name) : fallback.call
      rescue ::Exception # rubocop:disable Lint/RescueException
        fallback.call
      end
    end

    # An ACTION class named in prose, over `RenderedInstalledName`, which owns why the name is dispatched.
    #
    # Falls back to the same `"Action"` the rest of axn spells `|| "Action"`: an anonymous action class is the
    # common case in specs, so a name that cannot be had is the ordinary case rather than the odd one, and the
    # sentence reads as intended with a generic word where an object address would only be noise.
    module RenderedActionName
      DEFAULT = "Action"
      private_constant :DEFAULT

      def self.of(klass) = RenderedInstalledName.of(klass) { DEFAULT }
    end

    # Internal only -- rescued before Axn::Result is returned
    class EarlyCompletion < StandardError
      attr_reader :standalone

      def initialize(message = nil, standalone: false)
        @standalone = standalone
        super(message)
      end
    end
  end

  # Raised when fail! is called
  class Failure < StandardError
    DEFAULT_MESSAGE = "Execution was halted"

    # The action whose `fail!` raised this. We hold the action OBJECT (compared by identity in
    # Result#_fail_standalone?), not its object_id — consistent with ExceptionClassification's
    # identity keying, which deliberately avoids the freed-then-reused-object_id collision hazard.
    # `standalone:` is scoped to that action: an ancestor that catches a bubbled child Failure still
    # applies its OWN base (the child's opt-out is local).
    # NOTE: this pins the action (and its context/inputs) for the Failure's lifetime — only relevant
    # if a bare `result.exception` is retained beyond its result; results are normally short-lived.
    attr_reader :__originating_action, :raw_reason

    def initialize(message = nil, standalone: false, action: nil)
      @raw_reason = message
      @presentation = nil
      @standalone = standalone
      @__originating_action = action
      super(message)
    end

    # Set the resolved, presentation-layer string shown by #message. Leaves raw_reason untouched so
    # the framework can keep re-resolving from the raw reason without double-prefixing.
    #
    # Normalized on assignment, undispatched, and read back plain — because what resolution produces is
    # ultimately the caller's own object when they passed one (`fail!(obj)` with no declared base `error`
    # resolves to `obj` itself). `presence` here dispatched that object's `blank?` from inside the settling
    # path, which aborted `_settle_exception!` mid-way: the `on_error` callbacks and the failure
    # classification below it never ran, and the executor's guard warned about a reporting failure instead.
    def __present_as(string) = @presentation = Axn::Internal::NativeMethods.absent_value?(string) ? nil : string

    def standalone? = @standalone

    # The reason the caller handed `fail!`, or nil when they handed none — the undispatched form of
    # `raw_reason.presence`.
    #
    # `fail!` takes an ARBITRARY object, and this is read while a failure is already being reported: from
    # `#message`, from `#inspect`, and from `Result#_user_provided_error_message`, which is what `result.error`
    # and `result.message` resolve through. So `presence` meant dispatching the caller's `blank?`/`empty?` from
    # inside axn's own reporting, where an override that raises replaces the failure being reported with its own
    # exception — and outside StandardError it escapes the rescue meant to settle it. `fail!` with an object
    # whose `blank?` raises took down `result.error`, `result.message` and `result.inspect` alike, with the
    # failure itself intact underneath.
    #
    # The spellings that mean "no reason" are decided from the value's class and its own bytes instead
    # (`NativeMethods.absent_value?`), which is the same undispatched answer a declared name gets.
    def supplied_reason = Axn::Internal::NativeMethods.absent_value?(@raw_reason) ? nil : @raw_reason

    def message = @presentation || supplied_reason || DEFAULT_MESSAGE

    # Keyed off the RAW reason, not #message: once __present_as stamps the resolved presentation,
    # #message no longer reflects whether the caller supplied a reason. Post-run consumers read this
    # on a finalized, stamped result (e.g. ContextFacadeInspector#status → "[failed]" vs "[failed with…]").
    #
    # The comparison runs on axn's OWN frozen String as receiver rather than on the reason, so no `==` the
    # caller's object defines decides this either. `String#eql?` is value equality for a String (subclass
    # included) and false for anything else, which is what a reason equal to the default message needs.
    def default_message?
      reason = supplied_reason
      Axn::Internal::Identity.nil_value?(reason) || DEFAULT_MESSAGE.eql?(reason)
    end

    def inspect = "#<#{self.class.name} '#{message}'>"
  end

  module Mountable
    class MountingError < ArgumentError
      include Axn::Error
    end
  end

  class ContractViolation < StandardError
    include Axn::Error

    class ReservedAttributeError < ContractViolation
      # `owner:` names what already holds the name, when the caller knows it (see
      # Internal::NameOwnership). Without it the message can only say the name is unavailable, which
      # leaves the author guessing at what they collided with. `name` is then the READER the
      # declaration would define, which may not be the wire key — that is what makes the `as:` advice
      # below a real way out rather than a suggestion the guard refuses.
      #
      # `kind:` picks the remedy, because the three collisions do not offer the same one. An `expects`
      # READER collision is escapable with `as:`/`prefix:`, which keep the wire key and rename only the
      # method. An `expects` WIRE KEY collision is not: those options rename the reader and leave the
      # key as written, so the key itself has to change — and saying otherwise would send the author
      # after a spelling that cannot help. `exposes` has neither option: an exposed field's name IS the
      # reader defined on the Result, so the only way out there is a different name too.
      def initialize(name, owner: nil, kind: :input)
        @name = name
        @owner = owner
        @kind = kind
        super()
      end

      def message
        # Both operands are rendered before the join, never one of them: the name is the AUTHOR's bytes
        # (ASCII-compatible is all a declared name promises) and the owner label carries a module name or
        # path, so composing either raw can raise `Encoding::CompatibilityError` out of this method and
        # replace the declaration error with a rendering failure.
        #
        # `Text.renderable` rather than `PropertyNames.renderable_label`: this file is loaded standalone by
        # `Internal::Reflection::Values` (which requires it), so reaching for PropertyNames here would close
        # a require cycle and leave the constant undefined exactly when a message needs it. Text gives the
        # same two tiers — the name's text when it renders, its escaped spelling when it does not.
        name = Axn::Internal::Text.renderable(@name.to_s)
        return "Cannot call expects or exposes with reserved field name: #{name}" if @owner.nil?

        owner = Axn::Internal::Text.renderable(@owner.to_s)

        case @kind
        when :exposure
          "Cannot expose `#{name}`: that name belongs to #{owner}, and an exposure cannot share it. " \
          "`exposes` has no reader alias, so rename the field."
        when :wire_key
          "Cannot declare an inbound field named `#{name}`: that name belongs to #{owner}. The value a " \
          "caller passes under a field's name is read back off axn's inbound context facade, which answers " \
          "to `#{name}` itself — so the caller's value would be unreachable. Rename the field; `as:` and " \
          "`prefix:` rename only the reader and leave the wire key as written."
        else
          "Cannot declare a reader named `#{name}`: that name belongs to #{owner}. A field's reader is " \
          "defined on the action itself, so declaring it would take the name over. Rename the field, or " \
          "keep the wire key and rename only the reader, with `as:` (or `prefix:`)."
        end
      end
    end

    class MethodNotAllowed < ContractViolation; end
    class PreprocessingError < ContractViolation; end
    class DefaultAssignmentError < ContractViolation; end

    # Raised by FieldResolvers::Extract when a source can hold neither the named key nor answer it
    # as a method. Inside the subfield contract machinery this is rescued and treated as "value
    # absent" (PRO-2857), so the malformed value's own validation classifies it; it surfaces
    # publicly only when a reader meets malformed data outside validation (e.g. an untyped parent
    # read in the action body).
    class UnextractableError < ContractViolation; end

    # Raised by FieldResolvers::Extract when a segment can only be resolved by INVOKING it as a
    # method (an Array method, a PORO reader, a Data behavioral method) but the declaration did not
    # opt into method dispatch with `method_call: true`. Kept DISTINCT from UnextractableError so
    # `extract_or_nil` does NOT swallow it to "absent" — a forgotten `method_call:` must surface
    # loudly rather than silently validate the field against nil. As a plain ContractViolation (not
    # a ValidationError, not user_facing:) it settles as a bug: the executor fires the global
    # on_exception and result.error shows the generic headline, while the actionable fix rides on
    # this exception's own #message (see the design at PRO-2898).
    class MethodCallNotPermittedError < ContractViolation; end

    class DuplicateFieldError < ContractViolation; end

    # A name axn dispatches on the action itself — `call` from the executor, `_run` from `.call`, `initialize`
    # from `new` — that the class's own hierarchy also declares. Unlike the helpers, this one cannot be
    # surrendered: axn's definition must answer, so the inherited one would never run, and an action whose
    # inherited `call` never runs reports success for code that did not execute.
    #
    # Every value it interpolates is rendered, for the reason every message here renders: a constant path may
    # hold bytes with no UTF-8 rendering, and joining those would replace this failure with an
    # Encoding::CompatibilityError out of the message path. The two classes are named in their own right but by
    # different readers: `klass` is the ACTION, whose name axn itself may have installed, so it goes through
    # `RenderedActionName`; `owner` is a class axn never renames, so `RenderedModuleName` reads it bound. `name`
    # goes through `RenderedText`. All three take whatever a caller of this public class actually passes rather
    # than only what it ought to.
    #
    # The two remedies are spelled out separately because they do NOT amount to the same thing, and a reader who
    # merges them lands back on the failure being reported: defining the name on the action moves the behaviour
    # into the action (a bare `super` from there reaches axn's own default, NOT the inherited implementation),
    # while composing is the branch that keeps the inherited implementation running.
    class UnsurrenderableInheritedMethod < ContractViolation
      def initialize(klass:, name:, owner:)
        klass = Axn::Internal::RenderedActionName.of(klass)
        owner = Axn::Internal::RenderedModuleName.of(owner)
        name = Axn::Internal::RenderedText.of(name)

        super("#{owner} defines ##{name}, which #{klass} cannot inherit: axn must own that name to run the " \
              "action, so the inherited definition would never be called. Either move that behaviour into " \
              "#{klass}'s own ##{name} (`super` from there reaches axn's default, not #{owner}'s), or, to keep " \
              "#{owner}'s ##{name} running, compose #{owner} in rather than inheriting from it.")
      end
    end

    # A name `prefer_inherited`/`prefer_axn` cannot choose between, because axn does not hand it over: `call`
    # and the other names axn dispatches on the action by name, an axn internal, the ambient sentinel, Ruby's
    # own — or a name that is not part of axn's public instance surface at all, which is one verdict covering
    # both a name nothing defines and a private helper of axn's.
    #
    # `belongs_to:` is the owner sentence `Internal::NameOwnership.describe` writes, composed by the caller
    # rather than here: the ownership rules live there, and this file is loaded standalone by adapter gems, so
    # reaching for that module from a message path would close a require cycle. nil is the no-owner branch.
    #
    # Every value is rendered before the join, for the reason every message here renders: a declared name is the
    # AUTHOR's bytes, which only have to be ASCII-compatible, and joining those to axn's UTF-8 prose raw can
    # replace the declaration error with an `Encoding::CompatibilityError` out of the message path.
    class UnpreferableName < ContractViolation
      def initialize(declaration:, name:, belongs_to: nil)
        declaration = Axn::Internal::RenderedText.of(declaration)
        name = Axn::Internal::RenderedText.of(name)
        owned = if belongs_to.nil?
                  "is not part of axn's public instance surface"
                else
                  "belongs to #{Axn::Internal::RenderedText.of(belongs_to)}"
                end

        super("`#{declaration} :#{name}` names something axn cannot choose for you: ##{name} #{owned}. " \
              "Remove the declaration, or check the name.")
      end
    end

    # `prefer_inherited` for a name axn never stepped aside for. The declaration names an outcome that cannot be
    # delivered: there is no inherited implementation for axn to be standing behind, so nothing would change if
    # the declaration were honoured.
    #
    # What the message can honestly assert is what the deferral record knows — that nothing above the class
    # declared the name when `include Axn` ran. A definition made AFTER the include, in the class's own body or
    # in a module included later, is the other way to land here, and it already wins on its own terms, so the
    # message names that case rather than claiming no such definition exists.
    class NothingToPrefer < ContractViolation
      def initialize(klass:, name:)
        klass = Axn::Internal::RenderedActionName.of(klass)
        name = Axn::Internal::RenderedText.of(name)

        super("`prefer_inherited :#{name}` has nothing to prefer: axn surrendered no ##{name} on #{klass}, " \
              "because nothing above it declared the name when `include Axn` ran. Remove the declaration, or " \
              "check the name — a definition made after the include, in the class's own body or in a module " \
              "included later, already wins on its own terms.")
      end
    end

    class UnknownExposure < ContractViolation
      def initialize(key)
        @key = key
        super()
      end

      def message = "Attempted to expose unknown key '#{@key}': be sure to declare it with `exposes :#{@key}`"
    end

    # Like other ContractViolations raised inside `call`, propagates from `call!` but surfaces as `result.exception` under `.call`.
    class NoMatchingExposures < ContractViolation
      def initialize(declared:, exposed:)
        @declared = declared
        @exposed = exposed
        super()
      end

      def message
        "expose(result): the result exposes #{@exposed.inspect} but this action declares " \
          "#{@declared.inspect} — no fields in common to forward"
      end
    end
  end

  module Tools
    # Raised by `Axn::Tools.validate_contracts!` for a tool whose contract failure cannot be reported AS ITSELF.
    # Reporting it as itself means renaming it to say which tool it came from, and renaming an exception runs the
    # exception's own code — `#exception`, which `raise` dispatches on whatever object it is handed, and the
    # duplication hooks `Exception#exception(message)` reaches. axn will not run that code while reporting the
    # failure it caused (an override that raises replaces the failure, and one outside StandardError escapes the
    # boot rescue entirely), so when the class owns any of it, axn reports its own error instead.
    #
    # Nothing is lost but the class: the original is this error's `cause`, and its message is repeated here.
    # Deliberately builds its text in `initialize` rather than in `#message`, as `ReraiseFailed` below
    # does for the same reason. Everything it needs is rendered text by the time it is constructed, so there is
    # nothing to defer — and this exception exists precisely because reporting must not depend on an exception's
    # own methods, so it renders identically through `#message`, through a bound `Exception#to_s`, and to
    # anything that reads the stored message directly.
    #
    # Every value it interpolates came from somewhere else's object — the tool's constant path, the original's
    # message, the original's class name — so each is RENDERED into this message rather than joined to it. Bytes
    # with no UTF-8 rendering (or in another encoding entirely) would otherwise raise
    # Encoding::CompatibilityError from `super` itself, replacing the tool-contract failure with an encoding
    # failure at boot, which is the outcome this error exists to prevent one indirection over. Rendering is
    # idempotent, so the caller having already rendered them (as `Axn::Tools.validate_contracts!` does, needing
    # the same text for its other branch) costs an allocation and changes nothing: the guarantee holds for any
    # caller rather than resting on that one's diligence.
    #
    # Rendered through `Internal::RenderedText`, which composes `Internal::Text` — the byte primitive this file
    # already requires — with the type test a public class owes its callers. Never through the reflection
    # layer's own renderer, which is built ON this file: a message path here that reached UP into that layer
    # would NameError under the standalone loads `spec/axn/standalone_require_spec.rb` pins. The type test is
    # what keeps `new(tool: :foo, …)` — a Symbol being the obvious way to name a tool — rendering as `foo`
    # rather than raising a TypeError out of the message path, since `Text.renderable` binds String methods and
    # takes Strings alone.
    class InvalidContract < ContractViolation
      def initialize(tool:, reason:, original_class:)
        tool, reason, original_class = [tool, reason, original_class].map { |text| Axn::Internal::RenderedText.of(text) }

        super("#{tool} has an invalid tool contract — #{reason} (raised as #{self.class}, and not as the original " \
              "#{original_class}, because that class supplies its own `#exception` or duplication hook, or the " \
              "object is frozen: axn does not run an exception's own code while reporting the failure it caused. " \
              "The original is this error's `cause`.)")
      end
    end
  end

  # Raised by `Axn::Extensions.best_effort` under `best_effort_raises_in_dev` for a side-effect exception that
  # `raise` cannot hand back AS ITSELF.
  #
  # The dev-loud mode re-raises what the guarded block raised, and `raise` dispatches the 0-arg `#exception` on
  # whatever object it is given — a bare `raise` re-raising `$!` included, since Ruby has no re-raise that skips
  # that dispatch. So a class that owns `#exception` decides what leaves the guard: one answering a different
  # object escaped as that object with the block's exception gone entirely, and one that raises escaped as
  # whatever it raised. Either way the guard emitted a third exception, which is the one thing it promises never
  # to do.
  #
  # The decision is by OWNERSHIP, never by behaviour (`NativeMethods.native_exception_reraise?`), and the
  # dispatch is AVOIDED rather than guarded — the doctrine `Axn::Tools._named_invalid_contract` settled for the
  # boot path, for the same reason: an `#exception` that answers itself once and raises the second time defeats
  # any probe, so the only bounded question is whether Ruby's own implementation is what will answer. When it is
  # — the overwhelmingly common case, an ordinary `ArgumentError` included, and a frozen exception too — the
  # original object is re-raised unchanged and this class never appears.
  #
  # Dev-loud stays loud where it cannot: a developer who configured a raise gets one. Only the CLASS degrades.
  # The original is this error's `cause`, its class and message are repeated here, and a `StandardError` so an
  # enclosing `rescue => e` catches it exactly where it would have caught the ordinary case.
  #
  # Every value interpolated came from someone else's object, so each is RENDERED rather than joined — the whole
  # point being that reporting must not become the failure (see `Tools::InvalidContract` above, which composes the
  # same way for the same reason). The caller renders them too, needing the same text for its warning path;
  # rendering is idempotent, so the guarantee holds for any caller rather than resting on that one's diligence.
  class ReraiseFailed < StandardError
    include Axn::Error

    def initialize(desc:, reason:, original_class:)
      desc, reason, original_class = [desc, reason, original_class].map { |text| Axn::Internal::RenderedText.of(text) }

      super("Exception raised while #{desc}, re-raised as #{self.class} and not as the original " \
            "#{original_class}, because that class supplies its own `#exception` — which `raise` dispatches on " \
            "whatever object it is handed — and axn does not run an exception's own code while re-raising it. " \
            "The original is this error's `cause`, and its message was: #{reason}")
    end
  end

  class ValidationError < ContractViolation
    attr_reader :errors, :user_facing_message

    # `user_facing:` marks an inbound validation failure that the Executor has reclassified into the
    # failure bucket (see `expects ..., user_facing:`). The structured `errors` are preserved on the
    # exception either way; `user_facing_message` carries the (possibly overridden) message that
    # surfaces on `result.error` as an attachable reason — headlined by a declared base `error` just
    # like a `fail!` reason — leaving the dev-facing `#message` (full validation errors) intact.
    def initialize(errors, user_facing: false, user_facing_message: nil)
      @errors = errors
      @user_facing = user_facing
      @user_facing_message = user_facing_message
      @presentation = nil # set by __present_as when an owned, user-facing failure is stamped (see Axn::Failure)
      super(errors)
    end

    # Single source of truth for "did this (arbitrary) exception settle into the user-facing failure
    # bucket?" — folds in the type guard so the Executor (classification) and Result (outcome +
    # surfaced reason) ask the question one way and can't drift apart.
    #
    # The type test is undispatched, because it gates a second dispatch to the same instance: an
    # exception's own answer deciding whether axn may call `user_facing?` on it means one that lies
    # routes an arbitrary object into that call, and one that raises replaces the failure being
    # classified. Once the hierarchy has answered, `user_facing?` is axn's own reader on an axn-owned
    # class and is dispatched normally.
    def self.user_facing?(exception) = Axn::Internal::Identity.kind?(exception, self) && exception.user_facing?

    def user_facing? = @user_facing

    # Normalized on assignment and read back plain, on the same terms as `Axn::Failure#__present_as` above:
    # what resolution produces can be the caller's own object, and `presence` dispatched its `blank?` from
    # inside the path settling the failure.
    def __present_as(string) = @presentation = Axn::Internal::NativeMethods.absent_value?(string) ? nil : string
    def message = @presentation || errors.full_messages.to_sentence
    def to_s = message

    # Structured per-field view of the validation errors, for callers that want to format each
    # failure individually (e.g. a tool adapter handing per-argument reasons back to a model).
    # `full_message` so each entry reads standalone; base-level errors surface with field == :base.
    def field_errors = errors.map { |error| { field: error.attribute, message: error.full_message } }
  end

  class InboundValidationError < ValidationError; end
  class OutboundValidationError < ValidationError; end

  class UnsupportedArgument < ArgumentError
    include Axn::Error

    def initialize(feature)
      @feature = feature
      super()
    end

    def message
      "#{@feature} is not currently supported.\n\n" \
        "Implementation is technically possible but very complex. " \
        "Please submit a Github Issue if you have a real-world need for this functionality."
    end
  end

  module Extensions
    module Serialization
      # Raised when an exposed value has no honest JSON representation, so a serializing adapter
      # (axn-openapi, axn-mcp, axn-ruby_llm) fails the call rather than emitting garbage or a placeholder
      # where data belongs. Six shapes, in two categories. The rendering would be WRONG, or not JSON at
      # all: a self-referential container (no JSON representation at all), two Hash keys that stringify
      # to one JSON property (a value silently dropped), a non-finite Float (no JSON literal exists), or
      # a String whose bytes have no UTF-8 rendering (JSON is a UTF-8 format). The rendering would be
      # UGLY, rejected only under `serialize_value(reject_opaque: true)`: a value or a Hash key whose
      # only `to_s` is the inherited Object#to_s, which renders an object address into a response body.
      #
      # An ArgumentError so an adapter's existing `rescue StandardError` maps it to an error response
      # with no adapter-side change; a SystemStackError, being outside StandardError, would escape the
      # adapter entirely. Names the path to the offending value.
      class UnserializableValue < ArgumentError
        include Axn::Error

        # `reason:` names the specific defect, punctuation included. It defaults to the cycle case —
        # both the original meaning of this error and the only one an external caller is likely to
        # construct — so `new(path:, value:)` remains a complete call.
        def initialize(path:, value:, reason: nil)
          @path = path
          @value = value
          @reason = reason
          super()
        end

        # The offending value's class is named through `Internal::RenderedClassName`, not `@value.class`: the
        # value is caller-supplied and may override `class`, and running that override here would replace this
        # failure with the value's own exception. Its bytes are foreign too — a constant may hold non-UTF-8
        # ones, and `Module#to_s` hands those back — so the name is RENDERED before it joins this message.
        # That module composes both halves without delegating to `Internal::Rendering` (a require cycle) and
        # without lifting the composition onto `ClassName` (which promises never to render); see its own
        # comment. Both moves stay off limits; reaching for the shared owner is the point.
        #
        # `path:` and `reason:` are rendered on the same terms, because EVERY operand of a composition owes it
        # or none of them do. Inside the gem both are axn's own UTF-8 text (a canonicalized wire path, or an
        # escaped spelling for a name that has no UTF-8 rendering), but this is a PUBLIC class an adapter
        # constructs directly — `new(path:, value:)` is documented as a complete call — so a `path` in another
        # encoding is a caller away. A raw Latin-1 path beside a raw Latin-1 class name joined fine; beside a
        # RENDERED class name it raises `Encoding::CompatibilityError` from `#message` itself, which is the
        # serialization failure destroyed by the report of it.
        # Every operand normalized AT the join, including the reason — whose two sources (the caller's `reason:`
        # and this class's own `cycle_reason`) are normalized by one call rather than one each, so which source
        # answered cannot decide whether the message composes.
        def message
          "Cannot serialize exposed value at `#{Axn::Internal::RenderedText.of(@path)}` (#{value_class_name}): " \
            "#{Axn::Internal::RenderedText.of(@reason || cycle_reason)}"
        end

        private

        def value_class_name = Axn::Internal::RenderedClassName.of(@value)

        def cycle_reason
          klass = value_class_name
          article = klass.match?(/\A[aeiou]/i) ? "an" : "a"

          "it is self-referential (#{article} #{klass} cycle), which has no JSON representation. " \
            "Expose a finite projection of it instead (e.g. ids rather than the objects that point back)."
        end
      end
    end
  end

  module Async
    # Raised at enqueue when an async argument cannot be serialized for background execution.
    # Field-aware: names the offending field, its class, and how to fix it. The fix hint is
    # delegated to the serialization layer (Axn::Internal::AsyncSerialization), resolved at
    # message time so this stays a pure exception definition.
    class UnserializableArgument < ArgumentError
      include Axn::Error

      def initialize(field:, value:)
        @field = field
        @value = value
        super()
      end

      # Same shape as `UnserializableValue#message` above, and through the same owners: `@value` is
      # caller-supplied, so its class is named via `Internal::RenderedClassName` rather than `@value.class`,
      # and `@field` is a DECLARED name — foreign bytes of its own — so it is rendered rather than joined to
      # the rendered class name beside it.
      #
      # The hint is normalized here too, at the join. It is another module's method choosing between three
      # texts, and which text that is must not be able to decide whether this message composes — the ordinary
      # reason `#message` renders every operand of a composition rather than the ones known today to need it.
      def message
        "Cannot serialize argument `#{Axn::Internal::RenderedText.of(@field)}` (#{value_class_name}) for " \
          "async execution. #{Axn::Internal::RenderedText.of(Axn::Internal::AsyncSerialization._unserializable_hint(@value))}"
      end

      private

      def value_class_name = Axn::Internal::RenderedClassName.of(@value)
    end
  end
end
