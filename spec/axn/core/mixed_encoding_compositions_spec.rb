# frozen_string_literal: true

require "logger"
require "stringio"
require "tmpdir"
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

    # The reason `inspect` normalizes at the JOIN rather than per-operand. `format_for_inspect` picks between
    # four ways of rendering a value, and two of them were missed by rendering the others: `to_fs(:inspect)`,
    # whose text an app supplies through the documented `Date::DATE_FORMATS`/`Time::DATE_FORMATS` extension
    # point, and the ActiveRecord-relation branch. Neither is special — what is special is that ENUMERATING
    # the branches is what kept being wrong, so the composed value is normalized once instead.
    describe "a value rendered through an app-registered :inspect date format" do
      around do |example|
        previous_date = Date::DATE_FORMATS[:inspect]
        previous_time = Time::DATE_FORMATS[:inspect]
        Date::DATE_FORMATS[:inspect] = ->(_d) { "1 f\xE9vrier 2026".dup.force_encoding("ISO-8859-1") }
        Time::DATE_FORMATS[:inspect] = ->(_t) { "midi f\xE9vrier".dup.force_encoding("ISO-8859-1") }
        example.run
      ensure
        Date::DATE_FORMATS[:inspect] = previous_date
        Time::DATE_FORMATS[:inspect] = previous_time
      end

      it "inspects a Date beside a Latin-1 field name" do
        name = latin1_name
        klass = build_axn do
          exposes name, allow_blank: true
          define_method(:call) { expose(name, Date.new(2026, 2, 1)) }
        end

        result = klass.call

        expect { result.inspect }.not_to raise_error
        expect(result.inspect).to be_readable_utf8
        expect(result.inspect).to include("café", "1 février 2026")
      end

      it "inspects a Time beside a Latin-1 field name" do
        name = latin1_name
        klass = build_axn do
          exposes name, allow_blank: true
          define_method(:call) { expose(name, Time.utc(2026, 2, 1, 12)) }
        end

        result = klass.call

        expect { result.inspect }.not_to raise_error
        expect(result.inspect).to include("café", "midi février")
      end

      # The same branch with an ASCII name, where nothing raised before either — but the Latin-1 text used to
      # reach `inspect` as raw bytes, reading as mojibake. Normalizing at the join renders it as its text
      # wherever it lands, so this is asserted rather than left unstated.
      it "renders the registered format as text even where nothing would have raised" do
        klass = build_axn do
          exposes :on, allow_blank: true
          def call = expose(:on, Date.new(2026, 2, 1))
        end

        expect(klass.call.inspect).to eq(%(#<Axn::Result [OK] on: "1 février 2026">))
      end
    end

    # THE baseline for this branch: with the DEFAULT (ASCII) date format, the output must be byte-identical, so
    # normalizing at the join cannot be what moves ordinary `inspect` text.
    it "leaves a Date under the default format exactly as it was" do
      klass = build_axn do
        exposes :on, allow_blank: true
        def call = expose(:on, Date.new(2026, 2, 1))
      end

      expect(klass.call.inspect).to eq(%(#<Axn::Result [OK] on: "2026-02-01">))
    end

    # This suite is the NON-RAILS one, which is exactly where these belong: `format_for_inspect` renders a date
    # through `to_fs(:inspect)`, and with no Rails boot to load that core_ext, `result.inspect` raised
    # `NoMethodError` for a plain `Date` — the most reachable way this file could fail, needing no exotic value
    # and no encoding at all. `ContextFacadeInspector` declares the core_exts, so the compact rendering is the
    # same here as it is under Rails rather than one environment crashing.
    describe "a Date/Time exposure with no Rails boot to load ActiveSupport's conversions" do
      it "inspects a Date in the compact form" do
        klass = build_axn do
          exposes :on, allow_blank: true
          def call = expose(:on, Date.new(2026, 2, 1))
        end

        result = klass.call

        expect { result.inspect }.not_to raise_error
        expect(result.inspect).to eq(%(#<Axn::Result [OK] on: "2026-02-01">))
      end

      it "inspects a Time in the compact form" do
        klass = build_axn do
          exposes :at, allow_blank: true
          def call = expose(:at, Time.utc(2026, 2, 1, 12))
        end

        result = klass.call

        expect { result.inspect }.not_to raise_error
        expect(result.inspect).to eq(%(#<Axn::Result [OK] at: "2026-02-01 12:00:00.000000000 +0000">))
      end

      # A DateTime takes the `is_a?(Date)` branch, and rendering it through `Date#to_fs` would silently drop its
      # time — so the DateTime conversion is declared too, and this pins that it keeps the time.
      it "inspects a DateTime without dropping its time" do
        klass = build_axn do
          exposes :at, allow_blank: true
          def call = expose(:at, DateTime.new(2026, 2, 1, 12, 30))
        end

        expect(klass.call.inspect).to eq(%(#<Axn::Result [OK] at: "2026-02-01 12:30:00.000000000 +0000">))
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
