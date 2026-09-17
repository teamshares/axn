# frozen_string_literal: true

require "timeout"
require "memory_profiler"

RSpec.describe Axn::Internal::CallLogger do
  describe "#format_object" do
    # `value(n)` nests to depth `n` with exactly one element at each rung — the shape PRO-3203 measured
    # the exponential blowup with (`{f: [{f: [...]}]}`), so a regression here reproduces the same curve.
    def value(n) = n.zero? ? { leaf: "x" } : { f: [value(n - 1)] }

    it "renders each nesting rung once, rather than re-inspecting an already-formatted child" do
      formatted = described_class.send(:format_object, value(2))

      expect(formatted).to eq('{f: [{f: [{leaf: "x"}]}]}')
    end

    # Before the fix, the Array branch handed its parent a raw Array of already-formatted Strings
    # instead of a String — so the parent's string interpolation ran Array#to_s (== #inspect) over
    # already-rendered children, escaping their quotes/backslashes again on every level up. That
    # doubling made rendering (and the emitted line's length) exponential in nesting depth: depth 29
    # measured ~23s with no `shape:`/`of:` declared at all. Depth 30 here is comfortably past where the
    # unfixed code would blow well past the timeout; the fixed code finishes near-instantly.
    it "stays fast at a nesting depth where the exponential renderer was pathological" do
      deeply_nested = value(30)

      Timeout.timeout(2) do
        described_class.send(:format_object, deeply_nested)
      end
    end

    def be_readable_utf8
      satisfy("be readable UTF-8") { |s| s.encoding == Encoding::UTF_8 && s.valid_encoding? }
    end

    # A leaf can be any caller object, and a custom `#inspect` that interpolates a foreign-encoded
    # attribute directly (rather than calling `.inspect` on it) hands back non-ASCII bytes in that
    # attribute's own encoding, unescaped — an ordinary pattern for a domain object's inspect string.
    # Composing the Array/Hash branch's rendered children with `.join` raises
    # `Encoding::CompatibilityError` once two SIBLING leaves disagree on a non-ASCII encoding, which
    # `best_effort` then swallows, losing the log line entirely — unless each leaf is first run through
    # the shared UTF-8-safe renderer.
    def foreign_named(encoded_name)
      Struct.new(:name) { def inspect = "#<Person name=#{name}>" }.new(encoded_name)
    end

    let(:latin1_leaf) { foreign_named("caf\xE9".dup.force_encoding("ISO-8859-1")) }
    let(:utf8_leaf) { foreign_named("café") }

    it "renders array elements whose #inspect disagrees on non-ASCII encoding, rather than raising" do
      formatted = described_class.send(:format_object, [latin1_leaf, utf8_leaf])

      expect(formatted).to be_readable_utf8
      expect(formatted.scan("café").length).to eq(2)
    end

    it "renders hash values whose #inspect disagrees on non-ASCII encoding, rather than raising" do
      formatted = described_class.send(:format_object, { a: latin1_leaf, b: utf8_leaf })

      expect(formatted).to be_readable_utf8
      expect(formatted.scan("café").length).to eq(2)
    end

    # PRO-3335 review: `Text.borrowed` may hand a leaf's rendering back BY IDENTITY — the caller's own
    # mutable String — instead of a copy axn owns, whenever the bytes are already ASCII-only or valid
    # UTF-8. If `format_object` composed several leaves via a DEFERRED join (`.map { ... }.join(', ')`,
    # or a string-interpolation template — both evaluate EVERY operand before concatenating any of
    # them), a LATER sibling's `#inspect` could mutate an EARLIER leaf's already-computed-but-not-yet-
    # copied bytes out from under it before the final compose runs — verified to silently swap in the
    # mutated bytes, or raise `Encoding::CompatibilityError` composing next to a genuinely non-ASCII
    # sibling. `format_object` must instead copy each fragment into the result buffer IMMEDIATELY
    # (`buf << fragment`, which copies bytes at the point of the call, before any further caller code
    # runs) so nothing produced later can reach back and change what was already composed.
    it "is not corrupted by a later sibling's #inspect mutating an earlier VALUE's String in place" do
      shared = +"café" # UTF-8, non-ASCII, mutable, and returned (not copied) by `leaf`'s #inspect below
      leaf = Object.new
      leaf.define_singleton_method(:inspect) { shared }

      mutator = Object.new
      mutator.define_singleton_method(:inspect) do
        shared.force_encoding("ISO-8859-1") # mutates the ALREADY-COMPOSED sibling value's bytes
        "naïve"
      end

      formatted = described_class.send(:format_object, { a: leaf, b: mutator })

      expect(formatted).to be_readable_utf8
      expect(formatted).to include("café").and include("naïve")
    end

    it "is not corrupted by a later sibling ARRAY element mutating an earlier element's String in place" do
      shared = +"café"
      leaf = Object.new
      leaf.define_singleton_method(:inspect) { shared }

      mutator = Object.new
      mutator.define_singleton_method(:inspect) do
        shared.force_encoding("ISO-8859-1")
        "naïve"
      end

      formatted = described_class.send(:format_object, [leaf, mutator])

      expect(formatted).to be_readable_utf8
      expect(formatted).to include("café").and include("naïve")
    end

    # PRO-3335: `format_object` composes each leaf into `full_message_parts` and drops it once the line
    # is emitted — it never needs the owned-String guarantee `Text.renderable` exists to provide, so it
    # must route through the composition-only twin instead. Observed with `TracePoint`, filtered on
    # `defined_class` — never by prepending onto `Text`'s method table, which would trip axn's own
    # ownership guards and manufacture the calls it is trying to observe.
    it "never calls Text.renderable — only the borrowed rendering, Text.borrowed" do
      renderable_calls = 0
      tp = TracePoint.new(:call) do |t|
        renderable_calls += 1 if t.method_id == :renderable && t.defined_class == Axn::Internal::Text.singleton_class
      end

      tp.enable { described_class.send(:format_object, { name: "Kali", count: 3, nested: [1, "two"] }) }

      expect(renderable_calls).to eq(0)
    ensure
      tp&.disable
    end
  end

  describe "#would_log?" do
    it "asks the configured logger's own severity predicate" do
      logger = instance_double(Logger, info?: false)
      allow(Axn.config).to receive(:logger).and_return(logger)

      expect(described_class.would_log?(:info)).to be(false)
    end

    it "assumes yes when the logger doesn't expose a severity predicate" do
      logger = double("bare logger") # -- deliberately non-conforming
      allow(Axn.config).to receive(:logger).and_return(logger)

      expect(described_class.would_log?(:info)).to be(true)
    end

    it "still answers correctly for every declared level" do
      Axn::Core::Logging::LEVELS.each do |level|
        logger = instance_double(Logger, "#{level}?": true)
        allow(Axn.config).to receive(:logger).and_return(logger)

        expect(described_class.would_log?(level)).to be(true)
      end
    end

    # PRO-3335 (Change 3) calls this from BOTH the Executor's before/after hooks AND from inside
    # `log_at_level` itself — twice per emitted line in the common (level-on) case, which is exactly
    # the benchmark's case (its logger sits at DEBUG). `:"#{level}?"` allocates a fresh String on every
    # call; on a per-call log path that is a net allocation REGRESSION for the very benchmark this
    # ticket is trying to improve, so the predicate lookup must not allocate for a declared level.
    # Neither an RSpec double nor `allow(...).to receive` is used here — both have per-call mock
    # overhead of their own that would swamp the few objects this is actually trying to isolate.
    it "does not allocate building the severity predicate for a declared level" do
      previous = Axn.config.logger
      Axn.config.logger = Object.new.tap { |o| def o.info? = true }
      described_class.would_log?(:info) # warm any one-time setup (e.g. a LEVEL_PREDICATES Hash)

      report = MemoryProfiler.report { 50.times { described_class.would_log?(:info) } }

      expect(report.total_allocated).to eq(0)
    ensure
      Axn.config.logger = previous
    end
  end

  describe "#log_at_level" do
    it "skips building the log context entirely when the logger reports the level disabled" do
      logger = instance_double(Logger, info?: false)
      allow(Axn.config).to receive(:logger).and_return(logger)
      action_class = build_axn do
        expects :name
        def call; end
      end

      expect(described_class).not_to receive(:format_context)
      expect(action_class).not_to receive(:info)

      action_class.call(name: "x")
    end

    it "never lets a raising severity predicate escape — the same best_effort boundary as everything else in here" do
      logger = double("broken logger")
      allow(logger).to receive(:info?).and_raise(StandardError, "logger is misconfigured")
      allow(Axn.config).to receive(:logger).and_return(logger)
      action_class = build_axn do
        expects :name
        def call; end
      end

      expect do
        described_class.log_at_level(
          action_class,
          level: :info,
          message_parts: ["hi"],
          error_context: "test",
        )
      end.not_to raise_error
    end
  end
end
