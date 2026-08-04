# frozen_string_literal: true

# `ContextFacadeInspector` displays a Date/Time through ActiveSupport's `to_fs(:inspect)` when the value answers
# to it, which is what honours an app's registered `Date::DATE_FORMATS[:inspect]`. Only a Rails boot loads the
# conversions that define `to_fs`, so these live here: axn deliberately does not require them (loading them
# replaces `Date#inspect` process-wide, which is a library redecorating a core class for its host), and a
# spec-level require in the non-Rails suite would prove nothing about the real load path.
#
# So the same value reads differently in the two suites, by design — a DateTime is
# `"2026-02-01 12:30:00.000000000 +0000"` here and the ISO-8601 `"2026-02-01T12:30:00+00:00"` under the fallback
# that `spec/axn/core/mixed_encoding_compositions_spec.rb` pins. The divergence is the deliberate cost of not
# patching the host, and it is confined to how a date is spelled inside axn's own debug output.
RSpec.describe "Axn::Core::ContextFacadeInspector timestamp display (ActiveSupport conversions loaded)" do
  def latin1(bytes) = bytes.dup.force_encoding("ISO-8859-1")
  def latin1_name = latin1("caf\xE9").to_sym

  it "renders a Date through ActiveSupport rather than the fallback" do
    klass = build_axn do
      exposes :on, allow_blank: true
      def call = expose(:on, Date.new(2026, 2, 1))
    end

    expect(klass.call.inspect).to eq(%(#<Axn::Result [OK] on: "2026-02-01">))
  end

  it "renders a DateTime with its own format, keeping the time" do
    klass = build_axn do
      exposes :at, allow_blank: true
      def call = expose(:at, DateTime.new(2026, 2, 1, 12, 30))
    end

    expect(klass.call.inspect).to eq(%(#<Axn::Result [OK] at: "2026-02-01 12:30:00.000000000 +0000">))
  end

  # An app's own registered format is the whole reason `to_fs` is preferred over the fallback, and it is also
  # the one place a foreign encoding reaches this branch: the registered callable's text is the app's.
  describe "with an app-registered :inspect format returning non-UTF-8 text" do
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

    it "honours the registered format" do
      klass = build_axn do
        exposes :on, allow_blank: true
        def call = expose(:on, Date.new(2026, 2, 1))
      end

      expect(klass.call.inspect).to eq(%(#<Axn::Result [OK] on: "1 février 2026">))
    end

    # The composed `inspect` joins that Latin-1 text to a rendered field name, so rendering only the name — or
    # only some of the formatter's branches — turns a working composition into an `Encoding::CompatibilityError`.
    # Normalizing at the join is what makes this independent of which branch produced the text.
    it "inspects a Date beside a Latin-1 field name" do
      name = latin1_name
      klass = build_axn do
        exposes name, allow_blank: true
        define_method(:call) { expose(name, Date.new(2026, 2, 1)) }
      end

      result = klass.call

      expect { result.inspect }.not_to raise_error
      expect(result.inspect.encoding).to eq(Encoding::UTF_8)
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
  end
end
