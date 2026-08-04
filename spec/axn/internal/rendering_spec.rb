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

    it "renders unrenderable bytes into text that can be interpolated" do
      error = ArgumentError.new("caf\xE9".dup.force_encoding(Encoding::ASCII_8BIT))

      rendered = described_class.exception_message(error)
      expect(rendered.encoding).to eq(Encoding::UTF_8)
      expect { "prose: #{rendered}" }.not_to raise_error
    end

    it "falls back to Exception#to_s when #message returns a non-String" do
      klass = Class.new(StandardError) do
        def message = :not_a_string
      end

      expect(described_class.exception_message(klass.new("stored"))).to eq("stored")
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

    it "falls back to the class name for an ordinary class whose stored message object cannot render" do
      # No override at all: `Exception#message` renders the stored object through `rb_String`, so both the
      # dispatched read and the bound `Exception#to_s` raise, and the class is what is left.
      hostile = Object.new
      hostile.define_singleton_method(:to_s) { raise(NotImplementedError, "hostile message object") }
      error = Class.new(StandardError).new(hostile)

      expect(described_class.exception_message(error)).to eq(Axn::Internal::ClassName.of(error))
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

    # An override that answers non-nil is consulted by CRuby's own `setup_exception`, which then declines to
    # record a real backtrace — so the bound reader sees NIL and this degrades, rather than the frame type test
    # below catching the non-Array. Both belong here: this is the outcome for the shape that actually reaches
    # the guard, and the type test is what makes the outcome not depend on that CRuby detail.
    it "degrades when an override kept a real backtrace from ever being recorded" do
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

    it "reads the backtrace through a bound reader, so an override cannot substitute its own answer" do
      # A real backtrace AND an override: the override is what a dispatched read would get, and the recorded
      # frame is what the bound reader gets. Asserting the frame is asserting that the override never ran.
      exception = Class.new(StandardError) do
        def backtrace = "not an array"
      end.new("x")
      exception.set_backtrace(["/app/lib/thing.rb:42:in `block'"])

      expect(described_class.exception_source_location(exception)).to eq("thing.rb:42")
    end

    it "reads the first frame through a bound reader, so the backtrace CONTAINER cannot dispatch either" do
      # `set_backtrace` keeps the object it was handed rather than copying it, subclass included — verified on
      # 3.3 and 3.4 — so an Array subclass gets to answer `first` while a failure is being reported. `Interrupt`
      # rather than a StandardError because the guard around reporting deliberately does not absorb a signal:
      # a dispatched read here would carry it out in place of the exception being reported.
      hostile_container = Class.new(Array) do
        def first(*) = raise(Interrupt, "the container answered")
      end
      exception = ArgumentError.new("x")
      exception.set_backtrace(hostile_container.new(["/app/lib/thing.rb:42:in `block'"]))

      expect(described_class.exception_source_location(exception)).to eq("thing.rb:42")
    end
  end
end
