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
      private_constant :EXCEPTION_TO_S, :EXCEPTION_BACKTRACE, :STRING_SPLIT

      UNKNOWN_LOCATION = "unknown location"

      class << self
        # A value's CLASS named in prose, both halves composed: `ClassName` answers from bound base
        # implementations so nothing the value defines runs, and the constant path it answers with is
        # rendered because a constant may hold non-UTF-8 bytes (`Object.const_set(:"Caf\xE9", Class.new)` is
        # accepted, and `Module#to_s` hands those bytes back).
        def class_name(value) = Text.renderable(ClassName.of(value))

        # A class or module named in its own right — a declared `type:`, a tool axn — rather than a value's
        # class. Same two halves.
        def module_name(mod) = Text.renderable(ClassName.of_module(mod))

        # An exception's own message, as a UTF-8 String this method owns.
        def exception_message(exception) = Text.renderable(raw_exception_message(exception))

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
        def first_frame(exception)
          backtrace = EXCEPTION_BACKTRACE.bind_call(exception)
          return nil unless Identity.kind?(backtrace, ::Array)

          frame = backtrace.first
          return nil unless Identity.kind?(frame, ::String)
          return nil if Identity.blank_string?(frame)

          frame
        end
      end
    end
  end
end
