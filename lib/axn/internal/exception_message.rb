# frozen_string_literal: true

module Axn
  module Internal
    # An exception's own message, for a message being built ABOUT it, as a UTF-8 String this module owns.
    #
    # RENDERED rather than returned as it came, because what an exception's message HOLDS is foreign too, not
    # just the code that answers it: a String whose bytes are not UTF-8-compatible cannot be joined to axn's own
    # UTF-8 prose at all (Encoding::CompatibilityError from the interpolation), and one merely in another
    # encoding, or holding invalid bytes, silently poisons the message it lands in. Neither needs an override to
    # reach here — the STORED message of an ordinary ArgumentError is a String the raiser chose.
    # `renderable_label` is the one path axn renders foreign text with (a name in a message, a Hash key in a log
    # line, this): an ASCII message is byte-identical, a legitimate multibyte one reads as its text, and bytes
    # with no UTF-8 rendering come back escaped rather than taking the report with them. Rendering dispatches
    # nothing here — every branch below yields a genuine String, and a String is rendered through bound String
    # methods.
    #
    # The sibling of `Internal::ClassName`: both answer a question about a hostile object while a failure is
    # being reported, and neither runs code that object supplies.
    module ExceptionMessage
      # `Exception`'s own implementation, for a reporting path that must not run an exception's override of it.
      # `to_s` renders the message object the exception was raised with.
      EXCEPTION_TO_S = ::Exception.instance_method(:to_s)
      private_constant :EXCEPTION_TO_S

      def self.of(error) = Axn::Internal::Reflection::PropertyNames.renderable_label(_raw(error))

      # The message bytes, before rendering.
      #
      # Dispatched deliberately — an exception that derives its message from its state
      # (`Extensions::Serialization::UnserializableValue`) has no other way to be reported richly — but behind a
      # guard, because that is caller code in an error path, and the guard has to cover an ordinary class too:
      # `Exception#to_s` renders the message OBJECT the exception was raised with (`rb_String`), so a plain
      # ArgumentError carrying a value whose `to_s` raises raises here.
      #
      # The result is type-tested rather than returned as-is, because an owned `#message` may return anything,
      # and rendering a non-String dispatches its `to_s` — outside the guard, which is the escape this exists to
      # prevent. (A String SUBCLASS is safe: it is type-tested and rendered through bound String methods, and the
      # renderer hands back a plain String either way.) `Exception#to_s` is the non-dispatching second choice,
      # and the class is what is left when even that will not answer.
      def self._raw(error)
        case (reported = error.message)
        when ::String then reported
        else EXCEPTION_TO_S.bind_call(error)
        end
      rescue ::Exception # rubocop:disable Lint/RescueException
        begin
          EXCEPTION_TO_S.bind_call(error)
        rescue ::Exception # rubocop:disable Lint/RescueException
          Axn::Internal::ClassName.of(error)
        end
      end

      private_class_method :_raw
    end
  end
end
