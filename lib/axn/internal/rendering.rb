# frozen_string_literal: true

require "axn/exceptions"
require "axn/internal/identity"
require "axn/internal/text"

module Axn
  module Internal
    # Facts about a foreign object, for a message being built ABOUT it.
    #
    # An error path owes two obligations and every site that met one of them by hand met only that one.
    # First, do not DISPATCH what the object can override: an `inspect`, a `class`, a `message` or a
    # `backtrace` called to build the message can raise and replace the failure being reported, and outside
    # StandardError that escapes the rescue meant to settle it. Second, do not join raw foreign BYTES: what
    # a class name or a message HOLDS is foreign too, and a String with no UTF-8-compatible rendering cannot
    # be joined to axn's own UTF-8 prose at all. Both halves live here so no caller can meet one and miss
    # the other.
    #
    # Sits above `axn/exceptions` because it needs `Internal::ClassName`; the byte half it renders through
    # is one layer further down (`Internal::Text`) precisely so `axn/exceptions` can render its own messages
    # without requiring the file that requires it.
    module Rendering
      EXCEPTION_TO_S = ::Exception.instance_method(:to_s)
      EXCEPTION_BACKTRACE = ::Exception.instance_method(:backtrace)
      STRING_SPLIT = ::String.instance_method(:split)
      ARRAY_FIRST = ::Array.instance_method(:first)
      private_constant :EXCEPTION_TO_S, :EXCEPTION_BACKTRACE, :STRING_SPLIT, :ARRAY_FIRST

      UNKNOWN_LOCATION = "unknown location"

      # Bound so a Symbol's name is read without dispatching anything redefinable.
      SYMBOL_NAME = ::Symbol.instance_method(:name)
      private_constant :SYMBOL_NAME

      class << self
        # A value's CLASS named in prose, both halves composed: `ClassName` answers from bound base
        # implementations so nothing the value defines runs, and the constant path it answers with is
        # rendered because a constant may hold non-UTF-8 bytes (`Object.const_set(:"Caf\xE9", Class.new)` is
        # accepted, and `Module#to_s` hands those bytes back).
        #
        # DELEGATED to `Internal::RenderedClassName`, which owns that composition for the message paths built on
        # `axn/exceptions` — they cannot reach this file (it requires theirs), but this file requires theirs, so
        # the dependency runs one way and there is one composer rather than two identical ones.
        def class_name(value) = RenderedClassName.of(value)

        # A class or module named in its own right — a declared `type:`, a tool axn — rather than a value's
        # class. Same two halves, and DELEGATED for the same reason `class_name` is: the message paths built on
        # `axn/exceptions` name owners too and cannot reach this file.
        def module_name(mod) = RenderedModuleName.of(mod)

        # A DECLARED type written into a runtime validation message — a class, or one of the pseudo-types
        # (`:boolean`/`:uuid`/`:params`) a contract may name instead of one. Interpolating the token ran its own
        # `to_s`, and a declared class whose `to_s` raises replaced the validation failure with its exception:
        # the contract violation then settled as an `exception` outcome reading "Something went wrong", and the
        # bad input was reported through `on_exception` as though it were an internal error.
        #
        # A pseudo-type renders as its bare name rather than `:name`, which is what a validation message has
        # always said ("is not a boolean"); the declaration-time label spells the colon, because there the token
        # is being quoted back to the author rather than described to a caller.
        def type_label(token)
          return module_type_label(token) if Identity.kind?(token, ::Module)
          return Text.renderable(SYMBOL_NAME.bind_call(token)) if Identity.kind?(token, ::Symbol)

          class_name(token)
        end

        # A declared class named the way axn intends it to be named. `#name` is DISPATCHED, which is the
        # documented exception to reading a caller's class through bound implementations: axn installs a `name`
        # of its own on the classes it builds (`ClassBuilder#configure_class_name`, `Strategies::Form`), and
        # `Module#to_s` does not consult it — bound or dispatched, `to_s` answers `#<Class:0x…>` for a mounted
        # axn where axn intends `AnonymousClient_2980::Axns::Inner`. Binding here would substitute an object
        # address for prose that axn itself installed.
        #
        # The dispatch is absorbed rather than trusted, which is what lets both rules hold at once: a class
        # whose `name` raises (or answers with something that is not a String) degrades to the bound rendering
        # instead of replacing the validation failure being reported with its own exception. An anonymous class
        # with no installed name answers nil and takes the same fallback.
        def module_type_label(mod)
          name = mod.name
          Identity.kind?(name, ::String) ? Text.renderable(name) : module_name(mod)
        rescue ::Exception # rubocop:disable Lint/RescueException
          module_name(mod)
        end

        # An ACTION class named in prose, where `module_name` would name it wrongly: axn installs a `name` of
        # its own on the classes it builds, so the bound reader answers with an object address in place of the
        # name axn put there. DELEGATED like the other two, and for the same reason.
        def action_name(klass) = RenderedActionName.of(klass)

        # An exception's own message, as a UTF-8 String this method owns.
        def exception_message(exception) = Text.renderable(raw_exception_message(exception))

        # A VALUE's own rendering, as a UTF-8 String this method owns — or nil when it has none.
        #
        # For a value that IS the message rather than one being described: a `fail!` reason, a declared
        # `error`/`success` handler's return, a `user_facing:` handler's return. `to_s` is DISPATCHED,
        # deliberately, on the same terms as `exception_message` dispatches `#message` — the object's own
        # rendering is what makes the message useful, and routing everything through `Object#to_s` would
        # degrade every well-behaved value to defend against broken ones. But these values are rendered while
        # a failure is being SETTLED, and again on every later `result.error`/`result.message` read, and
        # interpolating one dispatches its `to_s` under no guard at all. So the call is made here and its
        # failure absorbed.
        #
        # Absorbs every class, including those axn never swallows: the outcome being settled has to win over
        # anything raised while rendering it, and a value's `to_s` is not a path a signal travels through. A
        # non-String `to_s` is a failure too, since rendering its answer would dispatch again.
        #
        # A String is rendered from its BYTES with nothing dispatched, which is what interpolation itself does
        # (`"#{}"` takes a String as it stands), so a subclass whose `to_s` raises still renders as its text.
        #
        # nil rather than a fallback of its own, because what an unrenderable value should degrade TO belongs
        # to the caller: a composed message names the value's class (`class_name`, the fallback this module and
        # `Identity.describe` both take), while a user-facing message has a better answer to fall back on.
        def value_rendering(value)
          return Text.renderable(value) if Identity.kind?(value, ::String)

          rendered = value.to_s
          Identity.kind?(rendered, ::String) ? Text.renderable(rendered) : nil
        rescue ::Exception # rubocop:disable Lint/RescueException
          nil
        end

        # Just the filename and line an exception came from, for a warning that names where a swallowed
        # failure happened.
        #
        # Read through a BOUND `Exception#backtrace`, which settles two things at once. An override cannot
        # substitute a non-Array or a non-String frame — and an override that answers non-nil stops Ruby
        # recording a real backtrace at all, so the bound reader sees nil and this degrades to
        # UNKNOWN_LOCATION instead of crashing on the override's answer.
        #
        # An empty backtrace has to be tolerated, and so does a BLANK frame inside one: `raise` repopulates
        # a nil backtrace, but a backtrace reconstructed with `set_backtrace` (what a death handler
        # rebuilding one from job data hands us) is kept exactly as given, `[""]` included. This runs from
        # inside an `ensure` often enough that a raise here would replace the exception already in flight.
        def exception_source_location(exception)
          frame = first_frame(exception)
          return UNKNOWN_LOCATION unless frame

          path = STRING_SPLIT.bind_call(frame).first
          return UNKNOWN_LOCATION unless Identity.kind?(path, ::String)

          basename = STRING_SPLIT.bind_call(path, "/").last
          Text.renderable(STRING_SPLIT.bind_call(basename, ":")[0, 2].join(":"))
        end

        private

        # The message bytes, before rendering. Private: nothing outside this module reads unrendered bytes,
        # and `exception_message` is the whole contract — verified with
        # `grep -rn "_raw_reported_message" lib/ spec/ spec_rails/` before the move.
        #
        # Dispatched deliberately — an exception that derives its message from its state
        # (`UnserializableValue`) has no other way to be reported richly — but behind a guard, because that
        # is caller code in an error path, and the guard has to cover an ordinary class too: `Exception#to_s`
        # renders the message OBJECT the exception was raised with (`rb_String`), so a plain ArgumentError
        # carrying a value whose `to_s` raises raises here.
        #
        # The result is type-tested rather than returned as-is, because an owned `#message` may return
        # anything, and rendering a non-String dispatches its `to_s` — outside the guard, which is the escape
        # this exists to prevent. (A String SUBCLASS is safe: it is type-tested and rendered through bound
        # String methods, and the renderer hands back a plain String either way.) `Exception#to_s` is the
        # non-dispatching second choice, and the class is what is left when even that will not answer.
        def raw_exception_message(exception)
          case (reported = exception.message)
          when ::String then reported
          else EXCEPTION_TO_S.bind_call(exception)
          end
        rescue ::Exception # rubocop:disable Lint/RescueException
          begin
            EXCEPTION_TO_S.bind_call(exception)
          rescue ::Exception # rubocop:disable Lint/RescueException
            ClassName.of(exception)
          end
        end

        # The first usable frame, or nil. Type-tested rather than trusted: `set_backtrace` accepts
        # `Thread::Backtrace::Location` objects on Ruby 3.4 (and refuses them on 3.3), and while 3.4 hands
        # them back from `backtrace` as Strings, a type test costs one `Module#===` and does not depend on
        # which version is running.
        # The CONTAINER is foreign too, not only the frames it holds: `set_backtrace` keeps the very object it
        # was handed, subclass and all, so an Array subclass overriding `first` would run its own code here —
        # while this method is reporting a failure, and outside anything that could absorb a class the guard
        # does not swallow. Read through `Array`'s own `first` for the same reason the backtrace itself is read
        # through `Exception`'s own reader.
        def first_frame(exception)
          backtrace = EXCEPTION_BACKTRACE.bind_call(exception)
          return nil unless Identity.kind?(backtrace, ::Array)

          frame = ARRAY_FIRST.bind_call(backtrace)
          return nil unless Identity.kind?(frame, ::String)
          return nil if Identity.blank_string?(frame)

          frame
        end
      end
    end
  end
end
