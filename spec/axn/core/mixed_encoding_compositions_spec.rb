# frozen_string_literal: true

require "logger"
require "stringio"
require "tmpdir"
require "open3"
require "support/tool_adapter_helpers"

# NOTHING is required here for the `to_fs(:inspect)` date branch, deliberately: `ContextFacadeInspector`
# declares those core_exts itself, and requiring them from the spec would make these examples pass whether or
# not it does.

# An `Encoding::CompatibilityError` needs INCOMPATIBLE operands, so rendering one operand of a message can CREATE
# one where none existed. Two ISO-8859-1 non-ASCII Strings concatenate fine; transcode one to UTF-8, leave its
# neighbour in ISO-8859-1, and the join raises where it previously succeeded.
#
# So the rule for every message axn composes is all-or-nothing: if it interpolates more than one foreign value,
# every one of them goes through the renderer. A HALF-rendered composition is strictly worse than an unrendered
# one, because it converts a working join into a raise — and these joins happen while a failure is being settled
# or reported, so the raise replaces the failure being reported, which is precisely what the rendering exists to
# prevent.
#
# Each example below pins one composition. Non-ASCII on BOTH sides is what makes it fire, so each fixture puts
# Latin-1 text on either side of the join, and the all-same-encoding cases are pinned too — a future change must
# not re-break these in the other direction by dropping a render.
RSpec.describe "mixed-encoding message compositions" do
  # Valid ISO-8859-1, so each renders as real text ("café", "Basé", "bäd") rather than as an escape.
  def latin1(bytes) = bytes.dup.force_encoding("ISO-8859-1")
  def latin1_name = latin1("caf\xE9").to_sym

  def be_readable_utf8
    satisfy("be readable UTF-8") { |message| message.encoding == Encoding::UTF_8 && message.valid_encoding? }
  end

  describe "a declared error base joined by a caller's `join:` separator" do
    subject(:action) do
      base = latin1("Bas\xE9")
      separator = latin1(" \xBB ")
      reason = latin1("r\xE9ason")
      build_axn do
        error base, join: separator
        define_method(:call) { fail!(reason) }
      end
    end

    # The separator is the third foreign operand of the same composition. Rendering only the two halves left the
    # caller unable to read the error of their own deliberate failure.
    it "lets the caller read the composed message" do
      result = action.call

      expect(result).not_to be_ok
      expect { result.error }.not_to raise_error
      expect(result.error).to be_readable_utf8
    end

    it "renders the base, the separator and the reason as text" do
      expect(action.call.error).to eq("Basé » réason")
    end

    it "keeps result.message and result.inspect readable too" do
      result = action.call

      expect(result.message).to be_readable_utf8
      expect { result.inspect }.not_to raise_error
    end

    # The compositions that already worked, pinned so a future change cannot re-break them by dropping a render.
    it "still composes an all-UTF-8 declaration" do
      klass = build_axn do
        error "Basé", join: " » "
        def call = fail!("réason")
      end

      expect(klass.call.error).to eq("Basé » réason")
    end

    it "still composes an all-ASCII declaration byte-identically" do
      klass = build_axn do
        error "Base", join: " - "
        def call = fail!("reason")
      end

      expect(klass.call.error).to eq("Base - reason")
    end
  end

  describe "a field whose `default:` raises" do
    # The wrapper's message joins the field's declared NAME to the rendered message of what the default raised —
    # a UTF-8 half beside a Latin-1 name. The encoding failure replaced DefaultAssignmentError as the outcome,
    # which is a reporting failure standing in for the real one.
    it "reports the default failure rather than an encoding failure" do
      name = latin1_name
      klass = build_axn do
        expects :n
        exposes name, default: -> { raise(ArgumentError, "b\xE4d".dup.force_encoding("ISO-8859-1")) }, allow_blank: true
        def call = nil
      end

      exception = klass.call(n: 1).exception

      expect(exception).to be_a(Axn::ContractViolation::DefaultAssignmentError)
      expect(exception.message).to be_readable_utf8
      expect(exception.message).to include("café", "bäd")
    end

    it "leaves an ASCII field name's message exactly as it was" do
      klass = build_axn do
        expects :n
        exposes :plain, default: -> { raise(ArgumentError, "boom") }, allow_blank: true
        def call = nil
      end

      expect(klass.call(n: 1).exception.message).to eq("Error applying default for field 'plain': boom")
    end
  end

  describe "a field whose `preprocess:` raises" do
    it "reports the preprocessing failure rather than an encoding failure" do
      name = latin1_name
      klass = build_axn do
        expects name, preprocess: ->(_v) { raise(ArgumentError, "b\xE4d".dup.force_encoding("ISO-8859-1")) }
        def call = nil
      end

      exception = klass.call(name => "x").exception

      expect(exception).to be_a(Axn::ContractViolation::PreprocessingError)
      expect(exception.message).to be_readable_utf8
      expect(exception.message).to include("café", "bäd")
    end
  end

  describe "the shared contract-error wrapper's `format` message form" do
    # The other half of the same wrapper: a String `message:` is filled by `format`, whose two arguments are the
    # field identifier and the rendered exception message.
    it "renders both operands of the format" do
      error = ArgumentError.new(latin1("b\xE4d"))

      expect do
        Axn::Internal::ContractErrorHandling.with_contract_error_handling(
          exception_class: Axn::ContractViolation::PreprocessingError,
          message: "on %s: %s",
          field_identifier: latin1_name,
        ) { raise error }
      end.to raise_error(Axn::ContractViolation::PreprocessingError) { |raised|
        expect(raised.message).to be_readable_utf8
        expect(raised.message).to eq("on café: bäd")
      }
    end
  end

  describe "the global exception log line" do
    # `result.error` resolves to the caller's own object, and the class name beside it is rendered. This whole
    # handler runs inside `best_effort`, so an encoding failure here loses the log line AND never reaches the
    # configured `on_exception` callback — an error reporter that silently stops being called.
    let(:exotic_name) { latin1("Caf\xE9Boom").to_sym }
    let(:exotic_class) { Class.new(StandardError).tap { |k| Object.const_set(exotic_name, k) } }

    after { Object.send(:remove_const, exotic_name) if Object.const_defined?(exotic_name) }

    it "logs the line and still invokes the configured on_exception hook" do
      boom = exotic_class
      klass = build_axn do
        error "r\xE9ason".dup.force_encoding("ISO-8859-1"), standalone: true
        define_method(:call) { raise boom }
      end

      io = StringIO.new
      reported = []
      previous_logger = Axn.config.logger
      Axn.config.logger = Logger.new(io, level: :info)
      Axn.config.on_exception = ->(e, action:, context:) { reported << e.class } # rubocop:disable Lint/UnusedBlockArgument

      klass.call

      expect(io.string).to include("Handled exception (CaféBoom): réason")
      expect(io.string).not_to include("IGNORING EXCEPTION")
      expect(reported).to eq([boom])
    ensure
      Axn.config.logger = previous_logger
      Axn.config.on_exception = nil
    end

    # Choosing WHICH detail to log compares `result.error` against the default message, and `result.error` is
    # the caller's own object whenever a declared `error` handler returned one — so the comparison dispatched
    # that object's `==`. A dispatch hazard rather than an encoding one, but it lands in the same place: this
    # handler runs inside `best_effort`, so it costs the log line AND the configured on_exception callback,
    # which is an error reporter silently ceasing to be called.
    it "picks the detail without dispatching the resolved error's own ==" do
      boom = Class.new(StandardError)
      detail = Object.new
      def detail.==(_other) = raise(NotImplementedError, "== must not decide which detail is logged")
      def detail.to_s = "a reason object"

      klass = build_axn do
        error(standalone: true) { detail }
        define_method(:call) { raise boom }
      end

      io = StringIO.new
      reported = []
      previous_logger = Axn.config.logger
      Axn.config.logger = Logger.new(io, level: :info)
      Axn.config.on_exception = ->(e, action:, context:) { reported << e.class } # rubocop:disable Lint/UnusedBlockArgument

      expect { klass.call }.not_to raise_error

      expect(io.string).to include("a reason object")
      expect(io.string).not_to include("IGNORING EXCEPTION")
      expect(reported).to eq([boom])
    ensure
      Axn.config.logger = previous_logger
      Axn.config.on_exception = nil
    end
  end

  describe "a composed user-facing validation message" do
    # The parts come from three producers with three encodings: a `user_facing:` handler's return, a field's own
    # ActiveModel message (whose bytes follow the declared name's), and the `:base` extras. A handler resolving to
    # nothing falls back to the field's own raw message, so one rendered part beside one raw part took the whole
    # run down — settling as a reported `exception` outcome instead of the non-reported user-facing failure.
    it "settles as the user-facing failure rather than an encoding failure" do
      name = latin1_name
      bad = latin1("b\xE4d")
      klass = build_axn do
        expects :aaa, presence: true, user_facing: -> { bad }
        expects name, presence: true, user_facing: -> {}
        def call = nil
      end

      result = klass.call

      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.error).to be_readable_utf8
      expect(result.error).to include("bäd")
    end

    it "leaves an all-ASCII composition exactly as it was" do
      klass = build_axn do
        expects :aaa, presence: true, user_facing: -> { "bad aaa" }
        expects :bbb, presence: true, user_facing: -> { "bad bbb" }
        def call = nil
      end

      expect(klass.call.error).to eq("bad aaa and bad bbb")
    end
  end

  describe "the serialization errors' own messages" do
    # Both are PUBLIC classes an adapter constructs directly, so a `path:`/`field:` in another encoding is a
    # caller away — and each is joined to a class name the error renders.
    let(:exotic_name) { latin1("Caf\xE9Val").to_sym }
    let(:exotic_class) { Class.new.tap { |k| Object.const_set(exotic_name, k) } }

    after { Object.send(:remove_const, exotic_name) if Object.const_defined?(exotic_name) }

    it "renders the path beside the value's class" do
      error = Axn::Extensions::Serialization::UnserializableValue.new(path: latin1("caf\xE9"), value: exotic_class.new)

      expect(error.message).to be_readable_utf8
      expect(error.message).to include("café", "CaféVal")
    end

    it "renders a caller-supplied reason beside the value's class" do
      error = Axn::Extensions::Serialization::UnserializableValue.new(path: "p", value: exotic_class.new,
                                                                      reason: latin1("b\xE4d"))

      expect(error.message).to be_readable_utf8
      expect(error.message).to include("bäd", "CaféVal")
    end

    it "renders the async field name beside the value's class" do
      error = Axn::Async::UnserializableArgument.new(field: latin1_name, value: exotic_class.new)

      expect(error.message).to be_readable_utf8
      expect(error.message).to include("café", "CaféVal")
    end

    it "leaves an ASCII path and class exactly as they were" do
      error = Axn::Extensions::Serialization::UnserializableValue.new(path: "items[1].parent", value: Object.new,
                                                                      reason: "because.")

      expect(error.message).to eq("Cannot serialize exposed value at `items[1].parent` (Object): because.")
    end
  end

  # This one is the ORIGINAL shape rather than the half-rendered one — both operands were raw, so it raised on
  # `origin/main` too — and it is closed here because `Result#inspect` is read from loggers, debuggers and
  # spec-failure output, which makes it the hardest raise in the library to trace back to its cause: the result
  # itself is perfectly intact underneath, and every tool you would reach for to look at it raises instead.
  describe "a result's own inspect" do
    it "inspects an OK result naming an exposed Latin-1 field holding a UTF-8 value" do
      name = latin1_name
      klass = build_axn do
        exposes name, allow_blank: true
        define_method(:call) { expose(name, "naïve") }
      end

      result = klass.call

      expect { result.inspect }.not_to raise_error
      expect(result.inspect).to be_readable_utf8
      expect(result.inspect).to include("café", "naïve")
    end

    # The path the CHANGELOG bullet's `Result#inspect` claim is about: a failed result, whose status half is
    # rendered while the field half was not.
    it "inspects a FAILED result naming the same field" do
      name = latin1_name
      klass = build_axn do
        exposes name, allow_blank: true
        define_method(:call) do
          expose(name, "naïve")
          fail!("nope")
        end
      end

      result = klass.call

      expect { result.inspect }.not_to raise_error
      expect(result.inspect).to be_readable_utf8
      expect(result.inspect).to include("[failed with 'nope']", "café", "naïve")
    end

    # A value's `inspect` is its own code, and this runs from inside the reporting, so it must not be what
    # escapes either. Degrades to naming the class, exactly as every other message path does.
    it "names a value whose own inspect raises rather than letting it escape" do
      hostile = Class.new { def inspect = raise(NotImplementedError, "hijacked from #inspect") }.new
      klass = build_axn do
        exposes :thing, allow_blank: true
        define_method(:call) { expose(:thing, hostile) }
      end

      result = klass.call

      expect { result.inspect }.not_to raise_error
      expect(result.inspect).to include("inspect unavailable")
    end

    it "leaves an ASCII field and value exactly as they were" do
      klass = build_axn do
        exposes :thing, allow_blank: true
        def call = expose(:thing, "value")
      end

      expect(klass.call.inspect).to eq(%(#<Axn::Result [OK] thing: "value">))
    end

    # `format_for_inspect` picks between four ways of rendering a value, and rendering some of those branches
    # individually is what missed the others — which is why the composed value is normalized once, at the join,
    # instead. The timestamp branch is the one that exercised that, and it has two halves: ActiveSupport's
    # `to_fs(:inspect)` where the value answers to it (specced in `spec_rails`, since only a Rails boot loads
    # the conversions that define it) and axn's own ISO-8601 rendering where it does not, below.
    #
    # THE SAME VALUE THEREFORE READS DIFFERENTLY IN THE TWO SUITES, deliberately: a DateTime is
    # `"2026-02-01T12:30:00+00:00"` here and `"2026-02-01 12:30:00.000000000 +0000"` under Rails. Axn will not
    # require the conversions to make the two agree — loading them replaces `Date#inspect` process-wide, which
    # is a library redecorating a core class for its host — so the divergence is the deliberate cost, and it is
    # confined to how a date is spelled inside axn's own debug output.
    describe "a Date/Time exposure whose value does not answer to to_fs" do
      # `to_fs` is undefined on the value rather than left absent from the process, because whether ActiveSupport's
      # conversions are loaded is not this file's to decide: another spec in this suite pulls them in transitively,
      # so an example that assumed otherwise would pass or fail on file ordering. Undefining the method asks the
      # branch the question directly, and gets the same answer either way.
      def without_to_fs(klass) = Class.new(klass) { undef_method(:to_fs) if method_defined?(:to_fs) }

      # The fallback exists because `to_fs` is ActiveSupport's, not Ruby's: reaching for it unconditionally made
      # `result.inspect` raise `NoMethodError` for a plain Date outside Rails — the most reachable way this file
      # could fail, needing no exotic value and no encoding at all.
      it "inspects a Date as an ISO-8601 day" do
        date = without_to_fs(Date).new(2026, 2, 1)
        klass = build_axn do
          exposes :on, allow_blank: true
          define_method(:call) { expose(:on, date) }
        end

        result = klass.call

        expect { result.inspect }.not_to raise_error
        expect(result.inspect).to eq(%(#<Axn::Result [OK] on: "2026-02-01">))
      end

      it "inspects a Time as an ISO-8601 timestamp" do
        time = without_to_fs(Time).utc(2026, 2, 1, 12)
        klass = build_axn do
          exposes :at, allow_blank: true
          define_method(:call) { expose(:at, time) }
        end

        result = klass.call

        expect { result.inspect }.not_to raise_error
        expect(result.inspect).to eq(%(#<Axn::Result [OK] at: "2026-02-01T12:00:00+00:00">))
      end

      # A DateTime IS a Date, so a single fallback format would render it as a bare day and drop its time. This
      # pins that the more specific class keeps it.
      it "inspects a DateTime without dropping its time" do
        at = without_to_fs(DateTime).new(2026, 2, 1, 12, 30)
        klass = build_axn do
          exposes :at, allow_blank: true
          define_method(:call) { expose(:at, at) }
        end

        expect(klass.call.inspect).to eq(%(#<Axn::Result [OK] at: "2026-02-01T12:30:00+00:00">))
      end

      # Availability is read out of the method table, never asked of the value: a display path must not be
      # steerable by a `respond_to?` the value defines, nor raisable by it.
      it "does not consult the value's own respond_to?" do
        hostile = Class.new(without_to_fs(Date)) do
          def respond_to?(*) = raise(NotImplementedError, "hijacked from #respond_to?")
        end
        klass = build_axn do
          exposes :on, allow_blank: true
          define_method(:call) { expose(:on, hostile.new(2026, 2, 1)) }
        end

        result = klass.call

        expect { result.inspect }.not_to raise_error
        expect(result.inspect).to eq(%(#<Axn::Result [OK] on: "2026-02-01">))
      end
    end

    # The real non-Rails scenario, in a FRESH Ruby that requires nothing but axn — which is the only way to assert
    # it, since this suite's own process has ActiveSupport's conversions loaded by another spec.
    #
    # Two things at once, and the second is why the first is possible: a plain Date/DateTime/Time exposure
    # inspects rather than raising, AND loading axn leaves `Date#inspect` as Ruby's own. Axn will not require the
    # conversions that would define `to_fs`, because loading them replaces `Date#inspect` process-wide — a
    # library redecorating a core class for its host, in service of the library's own debug output. Degrading
    # locally keeps the cost inside axn.
    describe "in a process that requires only axn" do
      program = <<~RUBY
        $LOAD_PATH.unshift("lib")
        require "axn"
        Axn.config.logger = Logger.new(IO::NULL)
        klass = Class.new do
          include Axn
          exposes :on, :at, :ts, allow_blank: true
          def call
            expose(:on, Date.new(2026, 2, 1))
            expose(:at, DateTime.new(2026, 2, 1, 12, 30))
            expose(:ts, Time.utc(2026, 2, 1, 12))
          end
        end
        puts klass.call.inspect
        puts Date.new(2026, 2, 1).inspect
      RUBY

      # One fresh Ruby for both examples.
      def self.fresh_run(program)
        @fresh_run ||= begin
          out, status = Open3.capture2e(RbConfig.ruby, "-e", program, chdir: File.expand_path("../../..", __dir__))
          raise "fresh load failed: #{out}" unless status.success?

          out.lines.map(&:chomp)
        end
      end

      it "inspects a Date, DateTime and Time through the ISO-8601 fallback" do
        expect(self.class.fresh_run(program).first)
          .to eq(%(#<Axn::Result [OK] on: "2026-02-01", at: "2026-02-01T12:30:00+00:00", ts: "2026-02-01T12:00:00+00:00">))
      end

      it "leaves Date#inspect as Ruby's own" do
        expect(self.class.fresh_run(program).last).to start_with("#<Date:")
      end
    end
  end

  describe "the tool-loading warn lines" do
    before { Axn::Tools::Registry.reset_adapters! }
    after { Axn::Tools::Registry.reset_adapters! }

    # A `tool_roots` entry is caller-supplied text, so its ENCODING is too: a BINARY-tagged path with high bytes
    # resolves on disk and reaches the warn line beside the rendered exception message. The line is built inside
    # the rescue that isolates one bad file, so a raise there escapes to the outer rescue and abandons the rest
    # of the eager load — every remaining tool silently missing from enumeration.
    it "warns about the one bad file instead of abandoning the eager load" do
      Dir.mktmpdir("axn_mixed_encoding") do |tmp|
        dir = File.join(tmp, "caf\xC3\xA9dir")
        Dir.mkdir(dir)
        File.write(File.join(dir, "boom.rb"), %(raise ArgumentError, "bäd"\n))
        register_adapter_with_roots(:mcp, roots: [dir.dup.force_encoding("BINARY")])

        warnings = []
        allow(Axn.config.logger).to receive(:warn) { |*args, &block| warnings << (block ? block.call : args.first) }

        expect { Axn::Tools.for(:mcp) }.not_to raise_error

        expect(warnings).to include(a_string_matching(/tool file skipped.*boom\.rb.*ArgumentError: bäd/))
        expect(warnings).not_to include(a_string_matching(/tool eager-load skipped/))
      end
    end
  end
end
