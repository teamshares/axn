# frozen_string_literal: true

module Axn
  module Internal
    # Foreign String BYTES, rendered so axn can write them into prose of its own.
    #
    # Every message axn builds is UTF-8, and joining a String whose bytes have no UTF-8-compatible
    # rendering to one raises `Encoding::CompatibilityError` from the reporting itself — so a caller gets an
    # encoding failure instead of the failure being reported, or loses a log line entirely. Two
    # ASCII-compatible encodings concatenate fine, which is why this only bites once a message carries
    # non-ASCII text from BOTH sides: a Latin-1 `caf\xE9` beside a UTF-8 `naïve`, or axn's own decoration.
    #
    # ZERO requires, deliberately. This is the lowest layer in the gem, and it has to be: `axn/exceptions`
    # renders its own messages, the reflection layer is built on `axn/exceptions`, and `axn/extensions` — the
    # guard config boot itself runs through — can afford to require none of them. A file that reached back up
    # into the reflection layer would leave a message path NameError-ing under the standalone loads
    # `spec/axn/standalone_require_spec.rb` pins.
    #
    # Every read is a BOUND String method. A String SUBCLASS can override `encoding`, `valid_encoding?`,
    # `ascii_only?`, `encode` and `inspect`, and one whose `valid_encoding?` returns true over bytes that
    # aren't valid defeats this check on exactly the value it exists to catch (verified: the lying override
    # is believed, and a JSON::GeneratorError or an Encoding::CompatibilityError follows). Callers type-test
    # for String first; these take no responsibility for anything else.
    module Text
      ENCODING = ::String.instance_method(:encoding)
      VALID_ENCODING = ::String.instance_method(:valid_encoding?)
      ASCII_ONLY = ::String.instance_method(:ascii_only?)
      ENCODE = ::String.instance_method(:encode)
      INSPECT = ::String.instance_method(:inspect)
      private_constant :ENCODING, :VALID_ENCODING, :ASCII_ONLY, :ENCODE, :INSPECT

      class << self
        # A UTF-8 rendering of `string`'s bytes, or nil when they have none.
        #
        # The ASCII-only fast path returns the argument ITSELF, subclass and all. That is safe for every
        # consumer because interpolating a String never dispatches its `to_s` — `"#{}"` uses a String as it
        # stands — so a subclass whose `to_s` raises still renders as its bytes. A consumer that needs a
        # plain String it owns copies it (see `renderable`, `canonical_wire_key`).
        def utf8_rendering(string)
          return string if ASCII_ONLY.bind_call(string)

          case ENCODING.bind_call(string)
          when ::Encoding::UTF_8 then VALID_ENCODING.bind_call(string) ? string : nil
          else transcode_to_utf8(string)
          end
        end

        # `EncodingError` is exactly the three refusals a transcode can raise (no converter for the pair, an
        # undefined mapping, an invalid byte sequence) and nothing else. The transcoded String is the answer
        # rather than a boolean because performing the transcode IS the check — there is nothing to save by
        # throwing the result away.
        def transcode_to_utf8(string)
          ENCODE.bind_call(string, ::Encoding::UTF_8)
        rescue ::EncodingError
          nil
        end

        # The escaped spelling of `string` — `String#inspect`, bound. Every non-ASCII byte comes back as an
        # escape, so the result is ASCII and joins to anything.
        def escaped(string) = INSPECT.bind_call(string)

        # `string` as a frozen plain UTF-8 String axn owns, for writing into a message: byte-identical for
        # ASCII, its text for another encoding, and the escaped spelling when the bytes have no UTF-8
        # rendering at all. Escaping rather than scrubbing, because a message that names an offender must
        # not quietly alter what it names; `Identity.utf8_string` takes the other fallback for text that has
        # to render at any cost.
        def renderable(string)
          utf8 = utf8_rendering(string) || escaped(string)

          ::String.new(utf8).force_encoding(::Encoding::UTF_8).freeze
        end
      end
    end
  end
end
