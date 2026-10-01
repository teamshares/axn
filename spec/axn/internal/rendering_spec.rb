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

    # `Module#to_s` is a TypeError on anything else, and the callers are public exception kwargs: a message
    # path owes an answer about the value rather than an error about rendering it.
    it "names a non-Module rather than raising out of the message path" do
      expect(described_class.module_name(:not_a_module)).to eq("not_a_module")
      expect(described_class.module_name(42)).to eq("Integer")
    end
  end

  describe ".type_label" do
    # The dispatch both name readers share: axn's own `name` is what the class means to be called, and the
    # bound reader answers past it with an address.
    it "names a declared class by the name it installed for itself" do
      klass = Class.new { def self.name = "AnonymousClient_2980::Axns::Inner" }

      expect(described_class.type_label(klass)).to eq("AnonymousClient_2980::Axns::Inner")
    end

    # The policy that separates this reader from `action_name`, which degrades to the generic "Action": a type
    # label is what the message says the input is NOT, so an unnameable class degrades to its placeholder, which
    # still says the declared type was a class rather than naming something else.
    it "falls back to the placeholder for an anonymous class, whose name is nil" do
      expect(described_class.type_label(Class.new)).to eq("(anonymous class)")
    end

    it "falls back to the placeholder when the class's own reader raises, on the same terms" do
      klass = Class.new { def self.name = raise(Exception, "answered") } # rubocop:disable Lint/RaiseException

      expect(described_class.type_label(klass)).to eq("(anonymous class)")
    end

    it "falls back to the placeholder for a class answering with something other than a String" do
      klass = Class.new { def self.name = :sym }

      expect(described_class.type_label(klass)).to eq("(anonymous class)")
    end

    # The positive control: an ordinary class and a pseudo-type read as a validation message has always said
    # them, so a seam that sent every token through the fallback would be caught rather than pass as safe.
    it "leaves an ordinary class and a pseudo-type reading as they always have" do
      expect(described_class.type_label(Integer)).to eq("Integer")
      expect(described_class.type_label(:boolean)).to eq("boolean")
    end
  end

  describe ".action_name" do
    # The whole point of the dispatch: axn's own `name` is what the class means to be called, and the bound
    # reader `module_name` uses answers past it with an address.
    it "answers with the name a class installed for itself" do
      klass = Class.new { def self.name = "AnonymousAxn_7" }

      expect(described_class.action_name(klass)).to eq("AnonymousAxn_7")
      expect(described_class.module_name(klass)).to match(/\A#<Class:/)
    end

    it "falls back for an anonymous class, whose name is nil" do
      expect(described_class.action_name(Class.new)).to eq("Action")
    end

    it "falls back for a class that answers with something other than a String" do
      expect(described_class.action_name(Class.new { def self.name = :sym })).to eq("Action")
    end

    # Rendering runs while a failure is being composed, so the class's own reader must not carry anything out
    # of it — including the raise a `rescue StandardError` would let past.
    it "falls back rather than letting the class's own reader raise out of the message path" do
      klass = Class.new { def self.name = raise(Exception, "answered") } # rubocop:disable Lint/RaiseException

      expect(described_class.action_name(klass)).to eq("Action")
    end

    it "renders bytes that have no UTF-8 rendering, so the name can be joined to axn's prose" do
      klass = Class.new { def self.name = "Bad\xFF".dup.force_encoding(Encoding::ASCII_8BIT) }

      rendered = described_class.action_name(klass)
      expect(rendered).to include('\xFF')
      expect(rendered.encoding).to eq(Encoding::UTF_8)
    end

    it "names a non-Module rather than raising out of the message path" do
      expect(described_class.action_name(:not_a_module)).to eq("not_a_module")
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

  # A DSL argument quoted back in a refusal may run exactly what quoting it by its own `inspect` ran, and nothing
  # more: a plain Array's elements are walked (native `Array#inspect` reaches each one's `inspect` too), while any
  # other container is quoted by its own `inspect`. Each example goes through a real refusal path, so it also pins
  # that the refusal is the error raised.
  describe ".stable_inspect" do
    # Named, because a container quoted by its own `inspect` renders an anonymous element by its address, which is
    # that container's rendering rather than axn's.
    let(:exception_class) { stub_const("StableInspectSpec::Boom", Class.new(StandardError)) }

    # Records every call to `name` on a container whose own code must not run, raising an `Interrupt` (outside
    # what the refusal paths absorb) so a call replaces the refusal as well as being counted.
    def hostile_array(name, calls)
      Class.new(Array) do
        define_method(name) do |*, **, &|
          calls << name
          raise Interrupt, "#{name} ran"
        end
      end
    end

    %i[map each join].each do |name|
      it "never runs an Array subclass's own ##{name} for an invalid factory spec" do
        calls = []
        spec = hostile_array(name, calls).new([exception_class, "retry", :extra])

        expect { Axn::Factory.build(fails_on: [spec]) { nil } }
          .to raise_error(ArgumentError, /\A\[Axn::Factory\] Invalid fails_on spec \(expected \[exceptions, message\?\]\): /)
        expect(calls).to be_empty
      end

      it "never runs an Array subclass's own ##{name} for an invalid `step if:`" do
        calls = []
        condition = hostile_array(name, calls).new([:a])
        step_axn = build_axn { def call = nil }

        expect { build_axn { step :maybe, step_axn, if: condition } }
          .to raise_error(ArgumentError, /\Astep if: must be a Symbol or callable/)
        expect(calls).to be_empty
      end
    end

    # The dispatch quoting it by its own `inspect` always made, and so the rendering it always had.
    it "quotes an Array subclass by its own #inspect" do
      condition = Class.new(Array) { def inspect = "<my list>" }.new([:a])
      step_axn = build_axn { def call = nil }

      expect { build_axn { step :maybe, step_axn, if: condition } }
        .to raise_error(ArgumentError, "step if: must be a Symbol or callable (got <my list>)")
    end

    it "quotes a plain Array carrying a singleton #map or #inspect by its own #inspect, never the singleton #map" do
      calls = []
      condition = [:a]
      condition.define_singleton_method(:map) { |*| calls << :map }
      condition.define_singleton_method(:inspect) { "<singleton list>" }
      step_axn = build_axn { def call = nil }

      expect { build_axn { step :maybe, step_axn, if: condition } }
        .to raise_error(ArgumentError, "step if: must be a Symbol or callable (got <singleton list>)")
      expect(calls).to be_empty
    end

    it "walks a plain Array, naming a class element by its placeholder and quoting the rest by their own #inspect" do
      expect(described_class.stable_inspect([Class.new, "retry", :extra, [Module.new]]))
        .to eq('[(anonymous class), "retry", :extra, [(anonymous module)]]')
    end

    # Nothing below `::Array` adds code, so walking it runs only what its inherited `inspect` would have.
    it "walks an Array subclass that adds no methods of its own" do
      expect(described_class.stable_inspect(Class.new(Array).new([Class.new, :x]))).to eq("[(anonymous class), :x]")
    end

    it "quotes a self-referential plain Array the way Array#inspect does" do
      cyclic = [1]
      cyclic << cyclic

      expect(described_class.stable_inspect(cyclic)).to eq("[1, [...]]")
    end
  end
end
