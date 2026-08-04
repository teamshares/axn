# best_effort cannot be taken down by the exception it swallows — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Axn::Extensions.best_effort` can only ever raise the exception its block raised — never a third exception manufactured while reporting it.

**Architecture:** The byte-rendering primitive that `Reflection::Values` owns today moves **down** into a zero-require `Axn::Internal::Text`, so files below the reflection layer can reach it. The composed "don't dispatch, then render" readers move into `Axn::Internal::Rendering` (above `axn/exceptions`, for `Internal::ClassName`). `best_effort` builds its warning from those readers and wraps the whole report path in a backstop. Then the same funnel closes every other site that writes a foreign exception into prose.

**Tech Stack:** Ruby (repo pins 3.3.6; CI runs 3.2/3.3/3.4), RSpec, RuboCop.

Spec: `internal-docs/specs/2026-08-03-best-effort-cannot-be-taken-down-design.md`. Linear: https://linear.app/teamshares/issue/PRO-3018

## Global Constraints

- Ruby: repo pins 3.3.6, CI runs 3.2, 3.3 and 3.4. Never assert `Hash#inspect` text (3.4 changed its spacing). Run the suite under 3.4.1 locally before claiming done: `ASDF_RUBY_VERSION=3.4.1 bundle exec rspec`.
- Non-Rails specs live in `spec/`; Rails-dependent behaviour in `spec_rails/dummy_app/`. Guard every `ActiveRecord`/`Rails` constant with `defined?()`.
- Markdown prose is **never** hard-wrapped: one line per paragraph, in specs, `AGENTS.md`, and `CHANGELOG.md` alike.
- Comments describe current behaviour and intrinsic why. Never "used to X / now Y", never a ticket or review reference.
- RuboCop: targeted `# rubocop:disable <Cop>` only, never blanket. `rescue Exception` needs `# rubocop:disable Lint/RescueException`.
- Pre-release gem: remove dead code outright rather than leaving a tombstone. Keep misuse guards.
- Every new `lib/` file **declares its own requires** for every constant its code references. `spec/axn/standalone_require_spec.rb` derives the list from each file's parse tree and fails on a gap.
- Test commands: `bundle exec rspec <path>` for a single file, `bundle exec rspec` for all, `bundle exec rubocop` for lint. For the Rails specs use `bundle exec rake spec_rails`, which is what CI runs — it chdirs into the dummy app. Running `rspec spec_rails` from the repo root instead reports `0 examples, 0 failures, 2 errors occurred outside of examples` and no failure count, because both `.rspec` files say `--require spec_helper` and the root cwd loads the non-Rails helper, so Rails never boots. A green-looking zero is the failure mode to watch for.

---

## File Structure

**Created:**

- `lib/axn/internal/text.rb` — `Axn::Internal::Text`. Foreign String **bytes**, rendered into UTF-8 axn can write into its own prose. Zero requires, so anything in the gem can reach it.
- `lib/axn/internal/rendering.rb` — `Axn::Internal::Rendering`. The composed readers: name a value's class, read an exception's message, locate an exception's source — none of them dispatching what the value can override, all of them rendering what they return.
- `spec/axn/internal/text_spec.rb`, `spec/axn/internal/rendering_spec.rb`.

**Modified:**

- `lib/axn/internal/reflection/values.rb` — the byte primitive and its bound String constants move out; `canonical_wire_key` and `describe_key_classes` delegate.
- `lib/axn/internal/identity.rb` — `utf8_string` delegates to the one primitive.
- `lib/axn/internal/reflection/property_names.rb` — `field_name_spelling`, `renderable_class_name`, `renderable_module_name` delegate.
- `lib/axn.rb` — `_reported_message` / `_raw_reported_message` move out; `_named_invalid_tool_contract` calls `Rendering`.
- `lib/axn/extensions.rb` — `_warn_and_swallow` and `_source_location`: the actual fix.
- `lib/axn/exceptions.rb` — `UnserializableValue#message` renders its interpolations.
- `lib/axn/core/context/facade_inspector.rb`, `lib/axn/core/executor.rb`, `lib/axn/configuration.rb`, `lib/axn/tools/registry.rb`, `lib/axn/internal/contract_error_handling.rb`, `lib/axn/internal/field_config.rb`, `lib/axn/core/flow/handlers/resolvers/message_resolver.rb`, `lib/axn/core/validation/validators/validate_validator.rb`, `lib/axn/core/field_resolvers/extract.rb` — the sweep.
- `AGENTS.md`, `CHANGELOG.md`.

---

## Task 1: `Internal::Text` — the byte primitive, moved down

**Files:**
- Create: `lib/axn/internal/text.rb`
- Create: `spec/axn/internal/text_spec.rb`
- Modify: `lib/axn/internal/reflection/values.rb` (remove the five bound String constants and `utf8_rendering`/`transcode_to_utf8`; delegate)
- Modify: `lib/axn/internal/identity.rb` (`utf8_string`)
- Modify: `lib/axn/internal/reflection/property_names.rb` (`field_name_spelling`'s String branch)

**Interfaces:**
- Consumes: nothing.
- Produces: `Axn::Internal::Text.utf8_rendering(string) -> String | nil`, `.escaped(string) -> String`, `.renderable(string) -> String` (frozen, UTF-8). All three are String-only: callers type-test first.

- [ ] **Step 1: Write the failing spec**

Create `spec/axn/internal/text_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Internal::Text do
  # A String SUBCLASS can override every method a byte check reads, and one whose `valid_encoding?`
  # returns true over bytes that aren't valid would defeat the check on precisely the value it exists to
  # catch — so every read here is a BOUND String method.
  let(:hostile) do
    Class.new(String) do
      def encoding = ::Encoding::UTF_8
      def valid_encoding? = true
      def ascii_only? = true
      def encode(*) = raise("encode explodes")
      def inspect = raise("inspect explodes")
    end
  end

  describe ".utf8_rendering" do
    it "hands back an ASCII string unchanged" do
      value = "plain"
      expect(described_class.utf8_rendering(value)).to be(value)
    end

    it "hands back valid multibyte UTF-8 unchanged" do
      expect(described_class.utf8_rendering("café")).to eq("café")
    end

    it "transcodes another encoding to its text" do
      expect(described_class.utf8_rendering("caf\xE9".dup.force_encoding("ISO-8859-1"))).to eq("café")
    end

    it "answers nil for bytes with no UTF-8 rendering" do
      expect(described_class.utf8_rendering("bad\xFF".dup.force_encoding("ASCII-8BIT"))).to be_nil
    end

    it "answers nil for a String tagged UTF-8 whose bytes are not valid" do
      expect(described_class.utf8_rendering("bad\xFF".dup.force_encoding("UTF-8"))).to be_nil
    end

    it "reads a subclass through bound String methods rather than its own" do
      value = hostile.new("bad\xFF".dup.force_encoding("ASCII-8BIT"))

      expect(described_class.utf8_rendering(value)).to be_nil
    end
  end

  describe ".renderable" do
    it "returns a frozen UTF-8 String for renderable bytes" do
      rendered = described_class.renderable("café")

      expect(rendered).to eq("café")
      expect(rendered.encoding).to eq(::Encoding::UTF_8)
      expect(rendered).to be_frozen
    end

    it "escapes bytes with no UTF-8 rendering rather than dropping them" do
      rendered = described_class.renderable("bad\xFF".dup.force_encoding("ASCII-8BIT"))

      expect(rendered).to include('\xFF')
      expect(rendered.encoding).to eq(::Encoding::UTF_8)
    end

    it "escapes through a bound inspect, so a subclass cannot raise instead" do
      value = hostile.new("bad\xFF".dup.force_encoding("ASCII-8BIT"))

      expect(described_class.renderable(value)).to include('\xFF')
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bundle exec rspec spec/axn/internal/text_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Internal::Text`.

- [ ] **Step 3: Create the primitive**

Create `lib/axn/internal/text.rb`. The bodies of `utf8_rendering` and `transcode_to_utf8` are moved verbatim from `Reflection::Values`; keep their reasoning with them.

```ruby
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
```

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `bundle exec rspec spec/axn/internal/text_spec.rb`
Expected: PASS (9 examples).

- [ ] **Step 5: Delegate from `Reflection::Values`**

In `lib/axn/internal/reflection/values.rb`: add `require "axn/internal/text"` beside the existing requires. Delete the constants `STRING_ENCODING`, `STRING_VALID_ENCODING`, `STRING_ASCII_ONLY`, `STRING_ENCODE` and their `private_constant` line, and delete the `utf8_rendering` and `transcode_to_utf8` method bodies. Replace the two methods with delegations, keeping only the reasoning specific to this layer:

```ruby
      # The byte half of a wire key, from the one primitive that owns it. Kept as a named method here
      # because this layer's callers ask a serialization question ("is there an honest rendering, or must
      # this value be refused?") and the nil answer is what they branch on.
      def utf8_rendering(string) = Axn::Internal::Text.utf8_rendering(string)
```

Delete `transcode_to_utf8` outright — `Text` owns it and nothing else in `Values` calls it. Verify with `grep -n "transcode_to_utf8" lib/` before deleting.

`canonical_wire_key` is unchanged: it keeps its own `::String.new(utf8).force_encoding(...).freeze`, because the copy is the wire-key contract rather than a safety measure.

- [ ] **Step 6: Delegate from `Identity.utf8_string`**

In `lib/axn/internal/identity.rb`: add `require "axn/internal/text"` at the top. Delete the `ENCODE`, `SCRUB`, `VALID_ENCODING` constants (keep `DUP` and `FORCE_ENCODING` — the scrub fallback still needs them, and check whether `SCRUB` is used elsewhere in the file before removing it; if the fallback below still uses it, keep it). Replace `utf8_string` with:

```ruby
      # A caller-supplied String rendered so it can be interpolated into a UTF-8 message. ALWAYS returns
      # valid UTF-8, which is the contract callers depend on.
      #
      # The fallback is a SCRUB rather than the escape `Internal::Text.renderable` takes, and the difference
      # is the point: this renders text that has to appear at any cost — a reason string from a caller's
      # `validate:` lambda, joined into the validation message a user reads — where a lossy `caf<?>` beats
      # both an escaped spelling and no message. A layer naming an OFFENDER wants the escape instead, since
      # it must not quietly alter what it names.
      def self.utf8_string(value)
        Text.utf8_rendering(value) || SCRUB.bind_call(FORCE_ENCODING.bind_call(DUP.bind_call(value), Encoding::UTF_8))
      end
```

- [ ] **Step 7: Write the equivalence spec for `utf8_string`**

The consolidation must not move a single output. Add to `spec/axn/internal/identity_spec.rb` (create the describe block if the file has none for `utf8_string`):

```ruby
  describe ".utf8_string" do
    # One primitive, two fallbacks: this one scrubs so the text always renders. These are the outputs the
    # method had before the byte check moved into `Internal::Text`, pinned input by input so a future change
    # to the primitive cannot move them silently.
    {
      "ASCII" => ["plain", "plain"],
      "valid multibyte UTF-8" => ["café", "café"],
      "transcodable Latin-1" => ["caf\xE9".dup.force_encoding("ISO-8859-1"), "café"],
      "UTF-16" => ["hi".encode("UTF-16"), "hi"],
      "empty" => ["", ""],
      "untranscodable binary" => ["bad\xFF".dup.force_encoding("ASCII-8BIT"), "bad�"],
      "UTF-8-tagged invalid bytes" => ["bad\xFF".dup.force_encoding("UTF-8"), "bad�"],
    }.each do |label, (input, expected)|
      it "renders #{label} as valid UTF-8" do
        rendered = described_class.utf8_string(input)

        expect(rendered).to eq(expected)
        expect(rendered.encoding).to eq(::Encoding::UTF_8)
        expect(rendered.valid_encoding?).to be(true)
      end
    end
  end
```

- [ ] **Step 8: Delegate from `PropertyNames.field_name_spelling`**

In `lib/axn/internal/reflection/property_names.rb`: add `require "axn/internal/text"`. Delete the `STRING_NAME_INSPECT` constant and change the String branch:

```ruby
      def field_name_spelling(name)
        case name
        when ::Symbol then SYMBOL_NAME_INSPECT.bind_call(name)
        when ::String then Axn::Internal::Text.escaped(name)
        end
      end
```

Leave `SYMBOL_NAME_INSPECT` alone: a Symbol has no singleton class, so nothing can override its `inspect`, and `Text` is String-only.

- [ ] **Step 9: Run the affected suites**

Run: `bundle exec rspec spec/axn/internal spec/axn/reflection spec/axn/standalone_require_spec.rb`
Expected: PASS. A failure in `standalone_require_spec` means a new `require` is missing — add it to the file whose code references the constant, not to the entry point.

- [ ] **Step 10: Run the full suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS both.

- [ ] **Step 11: Commit**

```bash
git add lib/axn/internal/text.rb lib/axn/internal/identity.rb lib/axn/internal/reflection/values.rb lib/axn/internal/reflection/property_names.rb spec/axn/internal/text_spec.rb spec/axn/internal/identity_spec.rb
git commit -m "PRO-3018: move the byte primitive down into Internal::Text

One implementation of the UTF-8-rendering question, in a zero-require file every
layer can reach, with two documented fallbacks: escape for a name or a message
that must not alter what it names, scrub for text that has to render at any cost."
```

---

## Task 2: `Internal::Rendering` — the composed readers

**Files:**
- Create: `lib/axn/internal/rendering.rb`
- Create: `spec/axn/internal/rendering_spec.rb`
- Modify: `lib/axn.rb` (delete `_reported_message` and `_raw_reported_message`; `_named_invalid_tool_contract` calls `Rendering`)
- Modify: `lib/axn/internal/reflection/property_names.rb` (`renderable_class_name`, `renderable_module_name`)

**Interfaces:**
- Consumes: `Axn::Internal::Text.renderable` (Task 1).
- Produces: `Axn::Internal::Rendering.class_name(value) -> String`, `.module_name(mod) -> String`, `.exception_message(exception) -> String`, `.exception_source_location(exception) -> String`. All return frozen UTF-8 Strings and dispatch nothing the argument can override, except the one deliberately-guarded `#message`.

- [ ] **Step 1: Write the failing spec**

Create `spec/axn/internal/rendering_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Internal::Rendering do
  describe ".class_name" do
    it "names an ordinary value's class" do
      expect(described_class.class_name("x")).to eq("String")
    end

    it "names the class without dispatching the value's own `class`" do
      liar = Class.new { def class = :not_a_class }.new

      expect(described_class.class_name(liar)).to match(/\A#<Class:/)
    end

    it "names an anonymous class rather than answering nil" do
      expect(described_class.class_name(Class.new.new)).to match(/\A#<Class:/)
    end
  end

  describe ".module_name" do
    it "names a module without dispatching its own `to_s`" do
      mod = Class.new { def self.to_s = raise("to_s explodes") }

      expect(described_class.module_name(mod)).to match(/\A#<Class:/)
    end
  end

  describe ".exception_message" do
    it "returns an ordinary message verbatim" do
      expect(described_class.exception_message(ArgumentError.new("bad input"))).to eq("bad input")
    end

    it "keeps a valid multibyte message verbatim" do
      expect(described_class.exception_message(ArgumentError.new("café"))).to eq("café")
    end

    it "renders a Latin-1 message as its text" do
      message = "caf\xE9".dup.force_encoding("ISO-8859-1")

      expect(described_class.exception_message(ArgumentError.new(message))).to eq("café")
    end

    it "escapes a message whose bytes have no UTF-8 rendering" do
      message = "bad\xFF".dup.force_encoding("ASCII-8BIT")

      expect(described_class.exception_message(ArgumentError.new(message))).to include('\xFF')
    end

    it "falls back to the bound Exception#to_s when #message raises" do
      klass = Class.new(StandardError) do
        def message = raise(NotImplementedError, "message explodes")
      end

      expect(described_class.exception_message(klass.new("stored"))).to eq("stored")
    end

    it "falls back to the class name when even the bound to_s cannot answer" do
      klass = Class.new(StandardError) do
        def message = raise(NotImplementedError, "message explodes")
        def to_s = raise(NotImplementedError, "to_s explodes")
      end
      # The stored message is the value `to_s` renders, so a value whose own `to_s` raises defeats the
      # bound Exception#to_s too — the class is what is left.
      exception = klass.new(Object.new.tap { |o| o.define_singleton_method(:to_s) { raise "value to_s" } })

      expect(described_class.exception_message(exception)).to match(/\A#<Class:/)
    end

    it "renders a non-String #message without dispatching its to_s outside the guard" do
      klass = Class.new(StandardError) do
        def message = Object.new.tap { |o| o.define_singleton_method(:to_s) { raise "to_s explodes" } }
      end

      expect { described_class.exception_message(klass.new("stored")) }.not_to raise_error
    end
  end

  describe ".exception_source_location" do
    it "names the file and line an exception came from" do
      exception = ArgumentError.new("x")
      exception.set_backtrace(["/app/lib/thing.rb:42:in `block'"])

      expect(described_class.exception_source_location(exception)).to eq("thing.rb:42")
    end

    it "tolerates a nil backtrace" do
      expect(described_class.exception_source_location(ArgumentError.new("x"))).to eq("unknown location")
    end

    it "tolerates an empty backtrace" do
      exception = ArgumentError.new("x")
      exception.set_backtrace([])

      expect(described_class.exception_source_location(exception)).to eq("unknown location")
    end

    it "tolerates a blank frame, which a rebuilt backtrace can hold" do
      # What a death handler reconstructing a backtrace from job data hands us. `raise` repopulates a nil
      # backtrace, but a `set_backtrace` value is kept exactly as given.
      exception = ArgumentError.new("x")
      exception.set_backtrace([""])

      expect(described_class.exception_source_location(exception)).to eq("unknown location")
    end

    it "tolerates a whitespace-only frame" do
      exception = ArgumentError.new("x")
      exception.set_backtrace(["   "])

      expect(described_class.exception_source_location(exception)).to eq("unknown location")
    end

    it "reads the backtrace through a bound reader, so an override cannot substitute a non-Array" do
      klass = Class.new(StandardError) do
        def backtrace = "not an array"
      end
      exception = begin
        raise klass, "x"
      rescue StandardError => e
        e
      end

      expect(described_class.exception_source_location(exception)).to eq("unknown location")
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bundle exec rspec spec/axn/internal/rendering_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Internal::Rendering`.

- [ ] **Step 3: Create the readers**

Create `lib/axn/internal/rendering.rb`. `raw_exception_message` is `Axn._raw_reported_message` moved verbatim; carry its comment across.

```ruby
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
```

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `bundle exec rspec spec/axn/internal/rendering_spec.rb`
Expected: PASS (17 examples).

- [ ] **Step 5: Move the reader off `Axn` and delegate from `PropertyNames`**

In `lib/axn.rb`: add `require "axn/internal/rendering"` beside the other internal requires. Delete `self._reported_message` and `self._raw_reported_message` (lines 182–218) and the now-unused `EXCEPTION_TO_S` constant, leaving `EXCEPTION_EXCEPTION` and its `private_constant`. In `_named_invalid_tool_contract`, replace the two calls:

```ruby
    tool = Axn::Internal::Rendering.module_name(klass)
    reason = Axn::Internal::Rendering.exception_message(error)
```

Keep the long comment above `_named_invalid_tool_contract` — its point 3 still describes what the code does; update the parenthetical `(Reflection::PropertyNames)` to `(Internal::Rendering)` so it names the seam it now uses.

In `lib/axn/internal/reflection/property_names.rb`: add `require "axn/internal/rendering"` and replace the two composers, keeping the comment above them (it explains the two hazards, which is still exactly right):

```ruby
      def renderable_class_name(value) = Axn::Internal::Rendering.class_name(value)

      def renderable_module_name(mod) = Axn::Internal::Rendering.module_name(mod)
```

`renderable_label` is unchanged.

- [ ] **Step 6: Confirm nothing referenced the moved methods**

Run: `grep -rn "_reported_message\|_raw_reported_message\|EXCEPTION_TO_S" lib/ spec/ spec_rails/`
Expected: hits only inside `lib/axn/internal/rendering.rb`. Any hit in `spec/` is a spec calling the moved method — repoint it at `Axn::Internal::Rendering.exception_message`.

- [ ] **Step 7: Run the affected suites**

Run: `bundle exec rspec spec/axn/internal spec/axn/reflection spec/axn/tools spec/axn/standalone_require_spec.rb`
Expected: PASS. The tool-contract specs from #208 exercise the moved reader through `Axn::Tools.validate_contracts!` and must stay green unchanged — if one fails, the move was not behaviour-preserving.

- [ ] **Step 8: Run the full suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS both.

- [ ] **Step 9: Commit**

```bash
git add lib/axn/internal/rendering.rb lib/axn.rb lib/axn/internal/reflection/property_names.rb spec/axn/internal/rendering_spec.rb
git commit -m "PRO-3018: one reader for facts about a foreign object

Internal::Rendering composes both halves an error path owes — no dispatch of what
the object can override, then render the bytes it answers with — and adds the
source-location read best_effort needs. The boot-path message reader moves here
from Axn so there is one owner rather than two."
```

---

## Task 3: `best_effort` cannot be taken down

**Files:**
- Modify: `lib/axn/extensions.rb` (`_warn_and_swallow`, `_source_location`)
- Modify: `spec/axn/extensions_spec.rb`
- Create: `spec/axn/core/validations/validate_lambda_misattribution_spec.rb`

**Interfaces:**
- Consumes: `Axn::Internal::Rendering.exception_message`, `.class_name`, `.exception_source_location` (Task 2); `Axn::Internal::Text.renderable` (Task 1).
- Produces: nothing new. The invariant: `best_effort` raises only the exception its block raised.

- [ ] **Step 1: Write the failing property spec**

Add to `spec/axn/extensions_spec.rb`, inside `describe ".best_effort"`. Note the existing `before` block stubs `backtrace` on every `StandardError` instance — these examples build their own exceptions and must not rely on that.

```ruby
    describe "the guarantee that reporting cannot replace the block's exception" do
      # `best_effort` builds its warning FROM the exception it caught, inside the rescue, so every read of
      # that exception is a second chance for it to escape through the code meant to contain it. This is the
      # invariant as a property rather than as a list of inputs: whatever the block raises, the only thing
      # that can come out is that same object.
      hostile_message = Class.new(StandardError) do
        def message = raise(NotImplementedError, "message explodes")
      end
      hostile_class_name = Class.new(StandardError) do
        def self.name = raise(NotImplementedError, "name explodes")
      end
      hostile_backtrace = Class.new(StandardError) do
        def backtrace = "not an array"
      end
      non_string_message = Class.new(StandardError) do
        def message = Object.new.tap { |o| o.define_singleton_method(:to_s) { raise "to_s explodes" } }
      end

      # Every shape is built INSIDE its lambda. These lambdas are created in the example-group body, so
      # their `self` is the group CLASS rather than an example instance — a helper defined with `def` here
      # would be an instance method and unreachable from them.
      shapes = {
        "an ordinary exception" => -> { raise ArgumentError, "ordinary" },
        "a message that raises" => -> { raise hostile_message },
        "a message holding bytes with no UTF-8 rendering" => lambda {
          raise ArgumentError, "bad\xFF".dup.force_encoding("ASCII-8BIT")
        },
        "a message that is not a String and whose to_s raises" => -> { raise non_string_message },
        "a class whose name raises" => -> { raise hostile_class_name },
        "a backtrace override answering a non-Array" => -> { raise hostile_backtrace },
        "a rebuilt backtrace holding a blank frame" => lambda {
          raise ArgumentError.new("rebuilt").tap { |e| e.set_backtrace([""]) }
        },
        "a valid multibyte message" => -> { raise ArgumentError, "café" },
        "a Latin-1 message" => -> { raise ArgumentError, "caf\xE9".dup.force_encoding("ISO-8859-1") },
      }

      %i[production development test].each do |environment|
        context "in #{environment}" do
          before do
            allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(environment == :production)
          end

          shapes.each do |label, block|
            it "swallows #{label} and returns nil" do
              expect(described_class.best_effort("guarding", &block)).to be_nil
            end
          end
        end
      end

      context "with best_effort_raises_in_dev enabled" do
        before do
          allow(Axn).to receive_message_chain(:config, :best_effort_raises_in_dev).and_return(true)
          allow(Axn).to receive_message_chain(:config, :env, :development?).and_return(true)
          allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)
        end

        shapes.each do |label, block|
          it "re-raises #{label} itself, never a reporting failure" do
            raised = begin
              described_class.best_effort("guarding", &block)
              nil
            rescue ::Exception => e # rubocop:disable Lint/RescueException
              e
            end

            expected = begin
              block.call
              nil
            rescue ::Exception => e # rubocop:disable Lint/RescueException
              e
            end

            expect(Axn::Internal::Identity.class_of(raised)).to eq(Axn::Internal::Identity.class_of(expected))
          end
        end
      end

      it "keeps a valid multibyte message verbatim in the warning" do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        expect(logger).to receive(:warn).with(/café/)

        described_class.best_effort("guarding") { raise ArgumentError, "café" }
      end

      it "renders a Latin-1 message as its text rather than as escapes" do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        expect(logger).to receive(:warn).with(/café/)

        described_class.best_effort("guarding") { raise ArgumentError, "caf\xE9".dup.force_encoding("ISO-8859-1") }
      end

      it "escapes a message with no UTF-8 rendering rather than losing the line" do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        expect(logger).to receive(:warn).with(/\\xFF/)

        described_class.best_effort("guarding") { raise ArgumentError, "bad\xFF".dup.force_encoding("ASCII-8BIT") }
      end

      it "tolerates a desc that is not a String" do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)

        expect(described_class.best_effort(Object.new) { raise ArgumentError, "ordinary" }).to be_nil
      end
    end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bundle exec rspec spec/axn/extensions_spec.rb -e "reporting cannot replace"`
Expected: FAIL on the hostile-message, binary-message, non-String-message, hostile-class-name, non-Array-backtrace, blank-frame and non-String-desc examples. The ordinary and multibyte ones pass already. Record which fail — that list is what the fix must flip.

- [ ] **Step 3: Harden the reads and add the backstop**

In `lib/axn/extensions.rb`: add `require "axn/internal/rendering"` beside the existing `require "axn/internal/identity"`. Replace `_warn_and_swallow` and `_source_location`:

```ruby
      # Warn about a swallowed exception and return nil (best_effort's documented failure return).
      # Re-raises first in development when configured, keeping the guard dev-loud.
      #
      # Every fact about the exception comes from `Internal::Rendering`, never from raw interpolation: this
      # code runs INSIDE the rescue, so a `message`, a `class`, or a backtrace read here is a second chance
      # for the exception to escape through the guard meant to contain it — and since the guard is called
      # from `ensure` all over the executor, an escape does not just lose a log line, it replaces the
      # exception already in flight. Two shapes reached it, neither needing a hostile author: an exception
      # whose `#message` raises, and an ordinary one whose STORED message holds bytes that cannot be joined
      # to axn's own prose.
      def _warn_and_swallow(exception, desc, action)
        raise exception if raises_in_dev?

        _emit_warning(action, _warning_message(exception, desc))

        nil
      rescue StandardError, *SWALLOWABLE_BEYOND_STANDARD_ERROR
        nil
      end

      # The backstop, deliberately absorbing everything the report path can raise, `SWALLOWABLE_BEYOND_STANDARD_ERROR`
      # aside — see `_warn_and_swallow`'s rescue, which is narrower on purpose so the dev-loud `raise` above
      # is never caught by it.
      #
      # Nothing above this line may raise a class the guard would otherwise pass through, because a
      # side-channel warning is not worth an exception of any kind. The dev-loud `raise exception` sits
      # BEFORE the reporting for the same reason: it is the block's own exception, and it must leave through
      # `_warn_and_swallow`'s caller rather than be caught here.
      def _warning_message(exception, desc)
        described = _describe(desc)
        klass = Internal::Rendering.class_name(exception)
        message = Internal::Rendering.exception_message(exception)
        src = Internal::Rendering.exception_source_location(exception)

        if Axn.config.env.production?
          "Ignoring exception raised while #{described}: #{klass} - #{message} (from #{src})"
        else
          msg = "!! IGNORING EXCEPTION RAISED WHILE #{described.upcase} !!\n\n" \
                "\t* Exception: #{klass}\n" \
                "\t* Message: #{message}\n" \
                "\t* From: #{src}"
          "#{'⌵' * 30}\n\n#{msg}\n\n#{'^' * 30}"
        end
      end

      # `desc` names the intent and is a String by contract, but it is EXTENSION-AUTHOR input reaching the
      # gem's lowest guard, and the non-production wording calls `upcase` on it — so it is type-tested and
      # rendered on the same terms as everything else here. Anything that is not a String is named by its
      # class instead, which is a legible desc and cannot raise.
      def _describe(desc)
        return Internal::Text.renderable(desc) if Internal::Identity.kind?(desc, ::String)

        Internal::Rendering.class_name(desc)
      end
```

`_emit_warning` is unchanged. Delete `_source_location` — `Rendering.exception_source_location` owns it now; confirm with `grep -n "_source_location" lib/ spec/` first.

Note on the `⌵` decoration: keep it. It is what made the encoding half raise in development and test while production merely mistagged the log line, and now that both sides are rendered UTF-8 it is safe — losing it would drop the visual marker for no gain.

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `bundle exec rspec spec/axn/extensions_spec.rb`
Expected: PASS, all examples including the pre-existing ones.

- [ ] **Step 5: Write the misattribution regression spec**

This is the user-visible bug: the guard's own reporting failure replaced the real error on the result. Create `spec/axn/core/validations/validate_lambda_misattribution_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "a validate: lambda that raises an exception axn cannot describe" do
  # `validate_validator` reports the lambda's exception through `best_effort { raise e }`. When the report
  # itself raised, the escape landed in the executor one layer out and REPLACED the settled outcome: the
  # caller's `Axn::InboundValidationError` was destroyed, no per-field message was ever added, and
  # `result.exception` named a stack with nothing to do with the failure. Reachable with three lines of
  # ordinary DSL, and in every environment for the hostile-`#message` shape.
  def action_validating_with(&raiser)
    build_axn do
      expects :n, validate: ->(_value) { raiser.call }
    end
  end

  let(:hostile_message) do
    Class.new(StandardError) do
      def message = raise(NotImplementedError, "message explodes")
    end
  end

  it "settles on the validation error for an ordinary raise (control)" do
    result = action_validating_with { raise ArgumentError, "ordinary" }.call(n: 1)

    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
  end

  it "settles on the validation error when the lambda's exception has a raising #message" do
    result = action_validating_with { raise hostile_message }.call(n: 1)

    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
  end

  it "settles on the validation error when the lambda's exception holds unrenderable message bytes" do
    result = action_validating_with { raise ArgumentError, "bad\xFF".dup.force_encoding("ASCII-8BIT") }.call(n: 1)

    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
  end
end
```

- [ ] **Step 6: Run it and confirm it passes, and confirm it would have failed**

Run: `bundle exec rspec spec/axn/core/validations/validate_lambda_misattribution_spec.rb`
Expected: PASS (3 examples).

Then A/B it against the pre-fix tree, which is what proves the spec pins the bug rather than describing the fix. Use a throwaway worktree, **never** `git stash` — on a clean tree `git stash -u` creates no entry, so the matching `git stash pop` applies whatever is already on the stack, and this repo carries three unrelated pre-existing entries (`WIP on inheritance`, `WIP on alpha-3`, `WIP on working`).

```bash
git worktree add -f --detach /tmp/axn-ab HEAD          # HEAD is the pre-fix tree: this task is not committed yet
cp spec/axn/core/validations/validate_lambda_misattribution_spec.rb /tmp/axn-ab/spec/axn/core/validations/
(cd /tmp/axn-ab && bundle exec rspec spec/axn/core/validations/validate_lambda_misattribution_spec.rb)
git worktree remove --force /tmp/axn-ab
```

Expected in the worktree: the control passes, the other two FAIL with `result.exception` being `NotImplementedError` and `Encoding::CompatibilityError`. An example that fails in BOTH trees is a broken fixture rather than a finding — that is the distinction that repeatedly matters here. If all three pass there, the spec is not exercising the bug: check that `Axn.config.env` is not production in the suite, since the encoding half only raises where axn's own prose is non-ASCII.

`bundle exec` needs no `bundle install` in the worktree while `Gemfile.lock` is unchanged, which it is at the same SHA.

- [ ] **Step 7: Audit the guard by mutating it**

Delete the `rescue StandardError, *SWALLOWABLE_BEYOND_STANDARD_ERROR` backstop from `_warn_and_swallow`, run `bundle exec rspec spec/axn/extensions_spec.rb`, and confirm examples FAIL. If the suite stays green, the backstop is unguarded — the property table is not reaching it, so add a shape that does. Restore the backstop afterwards.

- [ ] **Step 8: Run the full suite, both Rubies, and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop && ASDF_RUBY_VERSION=3.4.1 bundle exec rspec`
Expected: PASS all three.

- [ ] **Step 9: Commit**

```bash
git add lib/axn/extensions.rb spec/axn/extensions_spec.rb spec/axn/core/validations/validate_lambda_misattribution_spec.rb
git commit -m "PRO-3018: best_effort can only raise the exception its block raised

Every fact the warning names now comes from Internal::Rendering rather than raw
interpolation, and the report path has a backstop, so the invariant holds by
construction. Fixes the reachable case: a validate: lambda whose exception axn
could not describe lost the caller's InboundValidationError entirely."
```

---

## Task 4: The two escapes outside the guard

**Files:**
- Modify: `lib/axn/core/context/facade_inspector.rb:22-32`
- Modify: `lib/axn/core/executor.rb:852`
- Modify: `spec/axn/core/context_facade_spec.rb` (or wherever `Result#inspect` is specced — find with `grep -rln "failed with" spec/`)

**Interfaces:**
- Consumes: `Axn::Internal::Rendering.exception_message`, `.class_name` (Task 2).
- Produces: nothing.

- [ ] **Step 1: Write the failing spec**

Find the file that specs `Result#inspect` (`grep -rln "\[failed with" spec/`) and add:

```ruby
  describe "inspecting a failed result whose exception cannot describe itself" do
    # `Result#inspect` is not on the `.call` path, so this raises nothing into an action — it poisons every
    # logger, debugger and spec-failure message that touches the result instead, which is worse to diagnose.
    let(:hostile_message) do
      Class.new(StandardError) do
        def message = raise(NotImplementedError, "message explodes")
      end
    end

    it "renders rather than raising" do
      result = build_axn { raise hostile_message }.call

      expect { result.inspect }.not_to raise_error
    end

    it "renders a message holding bytes with no UTF-8 rendering" do
      result = build_axn { raise ArgumentError, "bad\xFF".dup.force_encoding("ASCII-8BIT") }.call

      expect { result.inspect }.not_to raise_error
    end
  end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bundle exec rspec <that file> -e "cannot describe itself"`
Expected: FAIL — `NotImplementedError: message explodes`, then `Encoding::CompatibilityError`.

- [ ] **Step 3: Route the inspector through the reader**

In `lib/axn/core/context/facade_inspector.rb`, replace the `status` method's two exception reads:

```ruby
      def status
        return unless facade.is_a?(Axn::Result)

        return "[OK]" if context.ok?

        return default_message? ? "[failed]" : "[failed with '#{exception_message}']" if facade.outcome.failure?

        %([failed with #{Axn::Internal::Rendering.class_name(context.exception)}: '#{exception_message}'])
      end

      # An exception carried on a failed result is caller-supplied, and `inspect` is called from loggers,
      # debuggers and spec failure output — the places a raise is hardest to trace back. So both the class
      # and the message come from the one reader that dispatches nothing the exception can override and
      # renders the bytes it answers with.
      def exception_message = Axn::Internal::Rendering.exception_message(context.exception)

      def default_message?
        Axn::Internal::Identity.kind?(context.exception, Axn::Failure) && context.exception.default_message?
      end
```

`default_message?` is axn's own predicate, but it is DEFINED only on `Axn::Failure` — and a failed result's exception is frequently not one, so it cannot stay a bare dispatch. `fails_on Boom` and `expects …, user_facing: true` both settle into the failure bucket carrying their own class, and both made `result.inspect` raise a bare `NoMethodError` before any hostile object was involved. So the predicate is asked only of an exception that answers it, behind the same guard `Result#_resolve_error` already puts on the identical read — with the undispatched `Identity.kind?` rather than `is_a?`, since whether axn may call its own method on a caller-supplied object is a fact about the hierarchy and not that object's opinion. Those two routes need their own examples: the existing hostile-exception ones raise from the action BODY, so they settle as an exception rather than a failure and never reach this branch.

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `bundle exec rspec <that file>`
Expected: PASS, including the pre-existing `[failed with '...']` examples — the wording for an ordinary exception is byte-identical.

- [ ] **Step 5: Fix the desc evaluated before the guard**

`lib/axn/core/executor.rb:852` builds its `desc` by dispatching `class` on the caller's exception, and a `desc` is evaluated BEFORE `best_effort` is entered, so no rescue covers it:

```ruby
        Axn::Extensions.best_effort("settling #{Internal::Rendering.class_name(settling)} onto the result", action: @action) { raise e }
```

Check the file's requires (`grep -n "^require" lib/axn/core/executor.rb`) and add `require "axn/internal/rendering"` if absent.

- [ ] **Step 6: Sweep the other desc built from a dispatched name**

`lib/axn/async/enqueue_all_orchestrator.rb:154` interpolates `target.name` — a `Module#name` dispatch on an action class, which an override can make raise before the guard is entered:

```ruby
          Axn::Extensions.best_effort("on_enqueue_all callback for #{Axn::Internal::Rendering.module_name(target)}") do
```

Then confirm no other `desc` dispatches on a caller object: `grep -rn "best_effort(\"" lib/ | grep -E '#\{[a-z_]+\.(class|name)'`
Expected: no remaining hits.

- [ ] **Step 7: Run the full suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS both.

- [ ] **Step 8: Commit**

```bash
git add lib/axn/core/context/facade_inspector.rb lib/axn/core/executor.rb lib/axn/async/enqueue_all_orchestrator.rb spec/
git commit -m "PRO-3018: close the exception reads no guard covers

Result#inspect read a caller-supplied exception's message and class directly, and
two best_effort descs dispatched on a caller object — a desc is evaluated before
the guard is entered, so no rescue covered it."
```

---

## Task 5: The two message paths that carried raw bytes

**Files:**
- Modify: `lib/axn/exceptions.rb` (`UnserializableValue#message`, `cycle_reason`)
- Modify: `lib/axn/internal/reflection/values.rb` (`describe_key_classes`)
- Modify: `spec/axn/internal/reflection/values_spec.rb` (or wherever `UnserializableValue` messages are specced — `grep -rln "Cannot serialize exposed value" spec/`)

**Interfaces:**
- Consumes: `Axn::Internal::Text.renderable` (Task 1).
- Produces: nothing.

These are the two paths `AGENTS.md` records as deliberately still carrying raw bytes because they sat BELOW the renderer. The primitive is now below them, so they close.

- [ ] **Step 1: Write the failing spec**

Add to the file that specs `UnserializableValue`:

```ruby
  describe "naming a value whose class holds bytes with no UTF-8 rendering" do
    # `Module#to_s` hands back a constant path's own bytes, and a constant may hold non-UTF-8 ones — so
    # naming the offending value's class destroyed the report it was building.
    let(:unrenderable_class) do
      Object.const_set(:"Caf\xE9Value", Class.new) unless Object.const_defined?(:"Caf\xE9Value")
      Object.const_get(:"Caf\xE9Value")
    end

    it "renders the class name rather than raising from the report" do
      error = Axn::Extensions::Serialization::UnserializableValue.new(path: "thing", value: unrenderable_class.new, reason: "nope")

      expect { error.message }.not_to raise_error
      expect(error.message).to include("thing")
    end

    it "renders it in the cycle wording too" do
      error = Axn::Extensions::Serialization::UnserializableValue.new(path: "thing", value: unrenderable_class.new)

      expect { error.message }.not_to raise_error
    end
  end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bundle exec rspec <that file> -e "no UTF-8 rendering"`
Expected: FAIL — `Encoding::CompatibilityError` from building the message.

- [ ] **Step 3: Render both interpolations**

In `lib/axn/exceptions.rb`: add `require "axn/internal/text"` at the top of the file. Replace the two class-name reads:

```ruby
      # The offending value's class is named via Axn::Internal::ClassName, not `@value.class`: the value
      # is caller-supplied and may override `class`, and running that override here would replace this
      # failure with the value's own exception. Its bytes are foreign too — a constant may hold non-UTF-8
      # ones, and `Module#to_s` hands those back — so the name is RENDERED before it joins this message.
      def message
        "Cannot serialize exposed value at `#{@path}` (#{value_class_name}): #{@reason || cycle_reason}"
      end

      private

      def value_class_name = Axn::Internal::Text.renderable(Axn::Internal::ClassName.of(@value))

      def cycle_reason
        klass = value_class_name
        article = klass.match?(/\A[aeiou]/i) ? "an" : "a"

        "it is self-referential (#{article} #{klass} cycle), which has no JSON representation. " \
          "Expose a finite projection of it instead (e.g. ids rather than the objects that point back)."
      end
```

`@path` is axn's own derived path string, not a foreign value — leave it.

This composition is `Rendering.class_name`, spelled out here rather than delegated, because `exceptions.rb` is what `rendering.rb` requires. Note that in the comment so nobody "tidies" it into a delegation and creates the cycle.

- [ ] **Step 4: Render the colliding-key report**

In `lib/axn/internal/reflection/values.rb`, `describe_key_classes`:

```ruby
      def describe_key_classes(first_key, second_key)
        first = Axn::Internal::Text.renderable(Axn::Internal::ClassName.of(first_key))
        second = Axn::Internal::Text.renderable(Axn::Internal::ClassName.of(second_key))
        return "both of class #{first}" if first == second

        "one of class #{first}, one of class #{second}"
      end
```

- [ ] **Step 5: Run the specs and confirm they pass**

Run: `bundle exec rspec spec/axn/reflection spec/axn/extensions`
Expected: PASS.

- [ ] **Step 6: Run the full suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS both.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/exceptions.rb lib/axn/internal/reflection/values.rb spec/
git commit -m "PRO-3018: render the two message paths that sat below the renderer

UnserializableValue#message and the colliding-key report named a class by its raw
constant bytes because the renderer was built on their files. The byte primitive is
below them now, so both compose the two halves like every other layer."
```

---

## Task 6: The funnel sweep

**Files:**
- Modify: `lib/axn/configuration.rb:239-244`
- Modify: `lib/axn/core/executor.rb:666`
- Modify: `lib/axn/core/flow/handlers/resolvers/message_resolver.rb:121`
- Modify: `lib/axn/tools/registry.rb:156,161,249`
- Modify: `lib/axn/internal/contract_error_handling.rb:30`
- Modify: `lib/axn/internal/field_config.rb:51,66`
- Modify: `lib/axn/core/validation/validators/validate_validator.rb:52`
- Modify: `lib/axn/core/field_resolvers/extract.rb:110`

**Interfaces:**
- Consumes: `Axn::Internal::Rendering.exception_message`, `.class_name` (Task 2).
- Produces: nothing.

**`validate_validator.rb:52` is already done** — Task 3 had to bring it forward, because its own misattribution spec cannot pass while that line reads `e.message` raw. Confirm it matches the replacement below and move on.

Do not assume the rest are harmless. The claim these sites shared — "each already sits inside a guard, so a raise here degrades a log line rather than replacing a verdict" — was FALSE for `validate_validator.rb:52`, which reads the exception outside any guard. Check each remaining site for itself: find the enclosing `rescue`/`best_effort` and say in the report whether the read is actually inside it. A site that is not inside one is an escape, not defence in depth, and needs a spec of its own. `renderable` is byte-identical for ASCII, so no existing message text moves either way.

- [ ] **Step 1: Write the failing spec for the two that reach a user-visible message**

`field_config.rb` and `contract_error_handling.rb` build the text a caller reads on a failed contract. Add to `spec/axn/core/validations/validate_lambda_misattribution_spec.rb` (created in Task 3):

```ruby
  it "reports a default: proc's unrenderable failure without losing the field error" do
    action = build_axn do
      expects :n
      exposes :thing, default: -> { raise ArgumentError, "bad\xFF".dup.force_encoding("ASCII-8BIT") }
    end

    result = action.call(n: 1)

    expect { result.error }.not_to raise_error
  end
```

- [ ] **Step 2: Run it and record the result**

Run: `bundle exec rspec spec/axn/core/validations/validate_lambda_misattribution_spec.rb`
Expected: it may already PASS, because the surrounding `best_effort` is fixed. That is fine and is the point of this task's framing — record which of these sites are load-bearing and which are defence in depth, and say so in the commit message rather than claiming a fix that was already delivered.

- [ ] **Step 3: Apply the sweep**

Each edit is the same shape: replace `e.message` with `Axn::Internal::Rendering.exception_message(e)` and `e.class.name` / `e.class` with `Axn::Internal::Rendering.class_name(e)`. Add `require "axn/internal/rendering"` to any file that does not already reference it.

`lib/axn/configuration.rb:239-244`:

```ruby
        detail = resolved_error == Axn::Core::Flow::Handlers::Resolvers::MessageResolver::DEFAULT_ERROR ? Axn::Internal::Rendering.exception_message(e) : resolved_error
      else
        detail = Axn::Internal::Rendering.exception_message(e)
      end

      msg = "Handled exception (#{Axn::Internal::Rendering.class_name(e)}): #{detail}"
```

`lib/axn/core/executor.rb:666`:

```ruby
          error_message = Internal::Rendering.exception_message(result.exception)
```

The `|| result.exception.class.name` fallback goes away: `exception_message` never answers nil — it falls back to the bound `Exception#to_s` and then to the class name itself, which is what that `||` was reaching for by hand.

`lib/axn/core/flow/handlers/resolvers/message_resolver.rb:121`:

```ruby
              action.warn("join: Proc raised #{Axn::Internal::Rendering.class_name(e)}: #{Axn::Internal::Rendering.exception_message(e)} — using default join")
```

Leave `message_resolver.rb:142` (`exception.message.presence`) alone for now and check it in Step 4 — it feeds `result.error`, so its behaviour is specced and a rendering change there is a behaviour change rather than a hardening.

`lib/axn/tools/registry.rb:156,161,249` — three log lines of the same shape:

```ruby
              Axn.config.logger.warn { "[Axn] tool file skipped (#{file}): #{Axn::Internal::Rendering.class_name(e)}: #{Axn::Internal::Rendering.exception_message(e)}" }
```

`lib/axn/internal/contract_error_handling.rb:30`:

```ruby
                          format(message, field_identifier, Axn::Internal::Rendering.exception_message(e))
```

`lib/axn/internal/field_config.rb:51,66`:

```ruby
          message: ->(_field, error) { "Error applying default for #{descriptor}: #{Axn::Internal::Rendering.exception_message(error)}" },
```

```ruby
          message: ->(_field, error) { "Error preprocessing #{descriptor}: #{Axn::Internal::Rendering.exception_message(error)}" },
```

`lib/axn/core/validation/validators/validate_validator.rb:52`:

```ruby
          "failed validation: #{Axn::Internal::Rendering.exception_message(e)}"
```

`lib/axn/core/field_resolvers/extract.rb:110` is a PREDICATE, not prose — it matches the message to recognize an arity mismatch. It gets the guarded read so a raising `#message` cannot escape it, and the matching itself is untouched:

```ruby
          Axn::Internal::Rendering.exception_message(error).start_with?("wrong number of arguments", "missing keyword")
```

- [ ] **Step 4: Decide `message_resolver.rb:142` explicitly**

Read the surrounding method. `exception.message.presence` resolves what a caller reads as `result.error`, and PRO-2899 settled that `result.error` never defaults to `exception.message` — so this line runs only for an explicit opt-in (`error(&:message)`). Two obligations still apply, and the guarded read is the one that matters: a raising `#message` here means the opt-in loses its message. Use `Axn::Internal::Rendering.exception_message(exception).presence` and run `bundle exec rspec spec/axn/core/messages_spec.rb spec/axn/core/user_facing_spec.rb`. If any example moves, stop and report the diff rather than changing the expectation — an opt-in message a caller reads is behaviour, and the fallback wording is settled by PRO-2899.

- [ ] **Step 5: Run the full suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS both, with **no** existing message expectation edited. `renderable` is byte-identical for ASCII, so any moved expectation means something else changed — investigate rather than update.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/
git commit -m "PRO-3018: one funnel for every exception written into prose

These sites all sit inside a guard already, so none of them escaped — each was a
misattribution source of the same shape, one exception's report replacing another's.
Rendering is byte-identical for ASCII, so no message text moves."
```

---

## Task 7: Documentation and final verification

**Files:**
- Modify: `AGENTS.md` (the error-path rule at line 120)
- Modify: `CHANGELOG.md` (under `## 0.1.0-alpha.5`, `### Failures & messages`)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

`## 0.1.0-alpha.5` is the unreleased section: `lib/axn/version.rb` says `0.1.0-alpha.5` and the newest tag is `v0.1.0.pre.alpha.4.3`, so the version is bumped but not cut. Verify both before editing (`git tag --sort=-v:refname | head -1`).

- [ ] **Step 1: Correct the two factual claims in AGENTS.md**

Both edits are in the long error-path paragraph at line 120. Keep the single-line-per-paragraph convention — the whole paragraph is one line, so edit in place.

First, the sentence beginning "Two message paths deliberately still carry raw bytes" describes a state that no longer exists. Replace it with the record of how they were closed:

> The byte primitive lives at the BOTTOM of the gem (`Internal::Text`, zero requires) for exactly this reason: `Reflection::Values`' colliding-key report and `UnserializableValue#message` sit in the files the renderer is itself built on, so they could not reach up to it, and moving it down is what let them compose both halves like every other layer — as `Axn::Extensions.best_effort` does, from a file that requires none of the reflection stack.

Second, the paragraph's closing sentence claims that inside `best_effort` a lying value "does not replace a verdict with an exception that escapes the rescue meant to settle it." That was false: a `validate:` lambda's exception whose `#message` raised replaced the caller's `InboundValidationError` on the result. Keep the rule, replace the example — caller data is still a different category, but the reason is that the dispatch is the WORK, not that a guard makes it harmless:

> Caller data is a different category from an error path: there the dispatch IS the work (rendering a value requires its `to_s`), and a value that lies degrades a log line or masks more than necessary. But being inside a guard is not what makes it safe, and `best_effort` is the proof: it built its warning from the exception it had just caught, so a `#message` that raised or a message holding non-UTF-8 bytes escaped the guard, was absorbed one layer out, and replaced the settled outcome — `result.exception` naming the reporting failure instead of the caller's `InboundValidationError`. A guard has to hold the property in the code that REPORTS, not only in the code it wraps, which is why the warning path reads every fact through `Internal::Rendering` and backstops the rest.

Then add `Axn::Extensions`, `Internal::Text` and `Internal::Rendering` to the sentence listing the layers that hold the property ("Five layers hold this property: ...", updating the count).

- [ ] **Step 2: Add the CHANGELOG entry**

Under `## 0.1.0-alpha.5` → `### Failures & messages`, append one bullet. No hard wrapping.

```markdown
* [FIX] An exception axn cannot describe no longer replaces the failure it was raised during. `Axn::Extensions.best_effort` built its warning from the exception it had just caught — its `class.name`, its `message`, its `backtrace` — so an exception whose `#message` raises, or an ordinary one whose stored message holds bytes with no UTF-8 rendering (`raise ArgumentError, <binary string>`, no override needed), escaped the guard through the code meant to contain it. Reachable from ordinary usage: a `validate:` lambda raising either shape lost the caller's `Axn::InboundValidationError` entirely, and `result.exception` named the reporting failure instead — a `NotImplementedError` in every environment for the first shape, an `Encoding::CompatibilityError` in development and test for the second. `best_effort` can now only raise the exception its block raised, and the same funnel closes `Result#inspect` (which raised from a logger or debugger touching a failed result), the two message paths that carried raw constant bytes because they sat below the renderer, and every other site that writes a foreign exception into prose. A valid multibyte message still reads verbatim and a Latin-1 one as its text; only bytes with no UTF-8 rendering at all come back escaped.
```

- [ ] **Step 3: Verify the whole thing end to end**

Run each and confirm:

```bash
bundle exec rspec
bundle exec rubocop
ASDF_RUBY_VERSION=3.4.1 bundle exec rspec
BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails
```

Expected: all PASS. The 3.4 run is not optional — these specs assert message text, and 3.4 differs from the pinned 3.3.6 in rendering details.

- [ ] **Step 4: Confirm the ticket's done-when list, item by item**

Re-read `## Done when` in `internal-docs/specs/2026-08-03-best-effort-cannot-be-taken-down-design.md` and check each line against a spec that proves it. Any line without one is a missing spec, not a judgement call.

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md CHANGELOG.md
git commit -m "PRO-3018: record the layer move and correct the error-path rule

AGENTS.md described the two raw-byte message paths as open and asserted that a
lying value inside best_effort cannot replace a verdict. The first is closed; the
second was false, and best_effort is the counterexample."
```

---

## Self-Review

**Spec coverage.** Every numbered spec section maps to a task: §1 → Task 1; §2 → Task 2; §3 → Task 3; §4's two outside-the-guard escapes → Task 4, its #208 leftovers → Task 5, its funnel sweep → Task 6; §5's enumeration is evidence rather than work (Task 4 Step 6 acts on the one Group C site it names); §6 → Task 7. Every `Done when` bullet has a spec: the eight escapes and the invariant → Task 3 Step 1; the `validate:` misattribution → Task 3 Step 5; `café` and Latin-1 → Task 3 Step 1 and Task 2 Step 1; `result.inspect` → Task 4 Step 1; the moved-primitive equivalence → Task 1 Step 7; `standalone_require_spec` → Task 1 Step 9 and Task 2 Step 7; Ruby 3.4 → Task 3 Step 8 and Task 7 Step 3.

**Type consistency.** `Text.utf8_rendering` / `.escaped` / `.renderable` and `Rendering.class_name` / `.module_name` / `.exception_message` / `.exception_source_location` are the only new names, spelled identically in every task that consumes them. `raw_exception_message` and `first_frame` are private — nothing outside the module reads unrendered bytes, confirmed by grep before the move — so both sit below the single `private`, after `exception_source_location`, which is public and specced.

**Two known-answer steps, flagged rather than hidden.** Task 6 Step 2 may pass before its edit, because Task 3 already fixed the guard around it — the step says so and asks for that to be reported rather than dressed up as a fix. Task 6 Step 4 may move a specced message; it says stop and report rather than update the expectation.
