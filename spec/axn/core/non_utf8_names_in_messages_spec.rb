# frozen_string_literal: true

require "logger"
require "stringio"

# Every message axn builds is a UTF-8 String, so a declared name (or a caller-supplied Hash key) whose bytes are
# not UTF-8 has to be RENDERED into one rather than interpolated raw — joining raw bytes to UTF-8 text raises
# Encoding::CompatibilityError from the reporting itself, and the caller gets an encoding failure in place of the
# thing being reported, or loses a log line entirely.
#
# Both names in each fixture below are individually legal: distinct text, each renderable on its own. The
# property-name rules correctly permit these declarations — the defect was only ever in the message path.
#
# Non-ASCII on BOTH sides is what makes it fire. A Latin-1 name beside an ASCII one concatenates fine (every
# ASCII-compatible encoding does), which is why an ASCII fixture shows a merely mangled message instead.
RSpec.describe "non-UTF-8 declared names in messages" do
  # Valid ISO-8859-1: "café" in Latin-1. Renderable (canonicalizes to "café"), just not UTF-8 bytes.
  def latin1_name = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym
  def latin1_string = "caf\xE9".dup.force_encoding("ISO-8859-1")

  def be_readable_utf8
    satisfy("be readable UTF-8") { |message| message.encoding == Encoding::UTF_8 && message.valid_encoding? }
  end

  describe "a validation error naming shape members in two encodings" do
    subject(:action) do
      latin1 = latin1_name
      build_axn do
        expects(:payload, type: Hash) do
          field :naïve, type: String
          field latin1, type: String
        end
      end
    end

    # The worst of the family: the call fails correctly, but the caller cannot read its own error, and anything
    # logging `e.message` in a rescue raises instead.
    it "lets the caller read the failure message" do
      exception = action.call(payload: {}).exception

      expect(exception).to be_a(Axn::InboundValidationError)
      expect { exception.message }.not_to raise_error
      expect(exception.message).to be_readable_utf8
    end

    it "names both members in the message" do
      message = action.call(payload: {}).exception.message

      expect(message).to include("naïve").and include("café")
    end

    it "keeps each per-field error readable too" do
      field_errors = action.call(payload: {}).exception.field_errors

      expect(field_errors.map { |e| e[:message] }).to all(be_readable_utf8)
    end
  end

  describe "the stranded-subfield diagnostic" do
    # A nil-tolerant parent with a required descendant is a declaration-time contradiction, and its message
    # names the parent and joins the stranded path from segments — two places raw bytes would land.
    it "reports the contradiction rather than an encoding failure" do
      latin1 = latin1_name

      expect do
        build_axn do
          expects :naïve, type: Hash, allow_nil: true
          expects latin1, on: :naïve, type: Hash, optional: true
          expects :deep, on: latin1
        end
      end.to raise_error(ArgumentError) { |error|
        expect(error.message).to be_readable_utf8
        expect(error.message).to include(":naïve", "café", "nil-tolerant")
      }
    end
  end

  describe "the call logger" do
    # Pure caller data — no declaration is involved. Two Hash keys in different non-ASCII encodings.
    it "emits the log line instead of losing it to a swallowed encoding failure" do
      io = StringIO.new
      previous = Axn.config.logger
      Axn.config.logger = Logger.new(io, level: :info)
      klass = build_axn { expects :payload, type: Hash }

      klass.call(payload: { naïve: 1, latin1_name => 2 })

      expect(io.string).to include("About to execute")
      expect(io.string).not_to include("IGNORING EXCEPTION")
    ensure
      Axn.config.logger = previous
    end

    it "renders both keys in the line" do
      io = StringIO.new
      previous = Axn.config.logger
      Axn.config.logger = Logger.new(io, level: :info)
      klass = build_axn { expects :payload, type: Hash }

      klass.call(payload: { naïve: 1, latin1_name => 2 })

      expect(io.string).to include("naïve").and include("café")
    ensure
      Axn.config.logger = previous
    end
  end

  describe "the shared renderer" do
    # An ASCII name renders byte-identically, so ordinary messages are untouched by any of this.
    it "leaves an ASCII name exactly as it was" do
      expect(Axn::Reflection::PropertyNames.renderable_label(:status)).to eq("status")
    end

    it "renders a non-UTF-8 name as the property it canonicalizes to" do
      expect(Axn::Reflection::PropertyNames.renderable_label(latin1_name)).to eq("café")
      expect(Axn::Reflection::PropertyNames.renderable_label(latin1_string)).to eq("café")
    end

    # Bytes with no UTF-8 rendering at all have no property to print, so they fall back to the escaped form.
    it "escapes bytes with no UTF-8 rendering" do
      label = Axn::Reflection::PropertyNames.renderable_label("bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym)

      expect(label).to eq(':"bad\xFF"')
      expect(label).to be_readable_utf8
    end

    # The fallback must not dispatch the name's own `inspect`: an exotic object's is caller code, and one that
    # raises would replace the message being built with its own exception.
    it "names an exotic object by class rather than running its inspect" do
      exotic = Class.new do
        def to_s = "bad\xFF".dup.force_encoding("ASCII-8BIT")
        def inspect = raise(NotImplementedError, "hijacked from #inspect")
      end.new

      expect(Axn::Reflection::PropertyNames.renderable_label(exotic)).to match(/\Aa name of class /)
    end
  end
end
