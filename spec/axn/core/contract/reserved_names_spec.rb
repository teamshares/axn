# frozen_string_literal: true

# Which names an inbound declaration may take. The rule is derived from method OWNERSHIP, not from a
# list of names, so the examples here assert the OUTCOME of that rule at each of its boundaries rather
# than restating the rule: axn's own sugar is surrendered, everything else is refused at declaration.
RSpec.describe "reserved names for expectations" do
  describe "names a user may take" do
    %i[result log info error expose inputs forward! execution_context internal_context].each do |name|
      it "allows `expects :#{name}`" do
        expect { build_axn { expects name } }.not_to raise_error
      end
    end

    it "reads the declared value back" do
      klass = build_axn do
        expects :log
        exposes :out
        def call = expose(out: log)
      end

      expect(klass.call(log: "a value").out).to eq("a value")
    end

    it "allows a name nothing owns" do
      expect { build_axn { expects :widget } }.not_to raise_error
    end
  end

  describe "names the framework cannot surrender" do
    it "rejects `expects :call` rather than silently skipping the action body" do
      expect { build_axn { expects :call } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /call/)
    end

    it "rejects `expects :_run`" do
      expect { build_axn { expects :_run } }.to raise_error(Axn::ContractViolation::ReservedAttributeError)
    end

    it "rejects `expects :initialize`, which would replace how the action is built" do
      expect { build_axn { expects :initialize } }.to raise_error(Axn::ContractViolation::ReservedAttributeError)
    end

    # A leading underscore marks a name axn dispatches on itself from another file, so it is never part
    # of the surface a sugar module surrenders even though it lives in one.
    %i[_forward_to_class _build_context_facade _safe_execution_context_slice _propagate_sub_result_outcome!].each do |name|
      it "rejects `expects :#{name}`, an internal of a module whose sugar IS surrenderable" do
        expect { build_axn { expects name } }.to raise_error(Axn::ContractViolation::ReservedAttributeError)
      end
    end
  end

  # `ambient_context` is a sentinel rather than a convenience: the subfield resolver decides a route is
  # ambient by comparing its root against `AmbientContext::PARENT`. A field that took the name would be
  # answered by the ambient branch and hand back the ambient context instead of the declared value, so
  # both spellings stay refused.
  describe "the ambient sentinel" do
    it "rejects `expects :ambient_context`" do
      expect { build_axn { expects :ambient_context } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /ambient_context/)
    end

    it "rejects `expects :x, as: :ambient_context`" do
      expect { build_axn { expects :x, as: :ambient_context } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /ambient_context/)
    end
  end

  describe "names owned by Ruby or the reader's own facade" do
    it "rejects `expects :class` rather than recursing until SystemStackError" do
      expect { build_axn { expects :class } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /class/)
    end

    %i[hash send inspect].each do |name|
      it "rejects `expects :#{name}`" do
        expect { build_axn { expects name } }.to raise_error(Axn::ContractViolation::ReservedAttributeError)
      end
    end

    # These are free on the action class — nothing there owns them, or what does is surrenderable
    # sugar — and are refused as WIRE KEYS: the inbound facade builds a reader per declared field and
    # declines to define over its own methods, so a key naming one reads back the facade's method
    # result instead of the caller's value.
    %i[declared_fields action action_name context inspect method_missing
       default_error default_success fail! _msg_resolver].each do |name|
      it "rejects `expects :#{name}`, which the inbound facade owns" do
        expect { build_axn { expects name } }.to raise_error(Axn::ContractViolation::ReservedAttributeError)
      end
    end
  end

  describe "names owned by the user's own code" do
    it "rejects a declaration that would clobber an earlier def" do
      expect do
        Class.new do
          include Axn
          def helper = "mine"
          expects :helper
        end
      end.to raise_error(Axn::ContractViolation::ReservedAttributeError, /helper/)
    end

    it "rejects a declaration that would clobber a superclass's method" do
      parent = Class.new do
        include Axn
        def helper = "mine"
      end

      expect { Class.new(parent) { expects :helper } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /helper/)
    end

    it "still allows a def AFTER the declaration (the wrap idiom)" do
      klass = build_axn do
        expects :name
        exposes :out
        def call = expose(out: name)
        def name = "wrapped"
      end

      expect(klass.call(name: "raw").out).to eq("wrapped")
    end

    it "still reports a redeclared field as a duplicate rather than a shadowing conflict" do
      expect { build_axn { expects :thing; expects :thing } } # rubocop:disable Style/Semicolon
        .to raise_error(Axn::ContractViolation::DuplicateFieldError)
    end

    it "reports an inherited field's redeclaration as a duplicate, not a shadowing conflict" do
      parent = build_axn { expects :thing }

      expect { Class.new(parent) { expects :thing, default: "x" } }
        .to raise_error(Axn::ContractViolation::DuplicateFieldError)
    end
  end

  # A declaration lands TWO names on two receivers, and `as:`/`prefix:` pull them apart: the reader is
  # a method on the action class, the wire key is a reader on the inbound facade the value is read
  # from. Each is judged where it lands — which is what makes renaming the reader a real way out of a
  # reader collision (a contract whose caller-facing key is `format` keeps that key), and what keeps a
  # key the facade owns refused however the reader is spelled.
  describe "the reader, not the wire key" do
    it "applies the rule to an `as:` reader name" do
      expect { build_axn { expects :thing, as: :class } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /class/)
    end

    it "applies the rule to a `prefix:`-composed reader name" do
      expect { build_axn { expects :class, prefix: :the_ } }.not_to raise_error
      expect { build_axn { expects :thing, prefix: :in } }.not_to raise_error
      expect { build_axn { expects :spect, prefix: :in } } # composes :inspect
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /inspect/)
    end

    it "accepts a reserved WIRE KEY whose reader is renamed, and reads the value back" do
      klass = build_axn do
        expects :format, as: :fmt
        exposes :out
        def call = expose(out: fmt)
      end

      expect(klass.call(format: "csv").out).to eq("csv")
    end

    it "accepts a reserved wire key behind a `prefix:` too" do
      klass = build_axn do
        expects :format, prefix: :in_
        exposes :out
        def call = expose(out: in_format)
      end

      expect(klass.call(format: "csv").out).to eq("csv")
    end

    it "lets an author keep a wire key their own def already answers to" do
      klass = Class.new do
        include Axn
        def helper = "mine"
        expects :helper, as: :given_helper
        exposes :out
        def call = expose(out: [given_helper, helper])
      end

      expect(klass.call(helper: "theirs").out).to eq(%w[theirs mine])
    end
  end

  # The other half of the same split. Renaming the reader leaves the wire key exactly as written, so a
  # key the inbound facade answers to survives every alias — and the facade, which will not define a
  # reader over one of its own methods, then answered the field with its own method result: the caller
  # passed a value, the action read "Something went wrong", and `ok?` was true.
  describe "the wire key, not the reader" do
    %i[default_error default_success declared_fields action context inspect].each do |key|
      it "rejects a reserved wire key `#{key}` behind an `as:` reader" do
        expect { build_axn { expects key, as: :aliased } }
          .to raise_error(Axn::ContractViolation::ReservedAttributeError, /#{key}/)
      end

      it "rejects a reserved wire key `#{key}` behind a `prefix:` too" do
        expect { build_axn { expects key, prefix: :in_ } }
          .to raise_error(Axn::ContractViolation::ReservedAttributeError, /#{key}/)
      end
    end

    it "names the wire key and does not offer a rename that cannot help" do
      expect { build_axn { expects :default_error, as: :de } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError,
                        /inbound field named `default_error`.*Rename the field/m)
    end

    # The facade is asked only about its OWN surface, so a wire key owned by Ruby stays legal — the
    # reader is where that collision is judged, and `as:` moves it out of the way. The facade defines
    # its readers without dispatching a name one of them may have taken, so the key still reads back.
    it "still accepts a wire key owned by Ruby, and reads the caller's value back" do
      klass = build_axn do
        expects :class, as: :klass
        expects :other
        exposes :out
        def call = expose(out: [klass, other])
      end

      expect(klass.call(class: "theirs", other: "second").out).to eq(%w[theirs second])
    end

    # `singleton_class` is the same shape as `class` and the more brittle of the two: the facade
    # dispatches it once per field to define that field's reader, so a reader defined for it would take
    # the method the loop itself runs on and every LATER field would be defined against a String.
    it "still accepts `singleton_class` as a wire key, without breaking the fields declared after it" do
      klass = build_axn do
        expects :singleton_class, as: :aliased
        expects :other
        exposes :out
        def call = expose(out: [aliased, other])
      end

      expect(klass.call(singleton_class: "theirs", other: "second").out).to eq(%w[theirs second])
    end
  end

  # The guard reads the action class's method table, and that class is the AUTHOR's. A metaprogramming base
  # defining its own singleton `method_defined?`/`instance_method` would otherwise decide this verdict — and
  # one answering "free" admits the declaration whose reader then replaces `Object#class`. A guard a caller
  # can invert is not a guard.
  it "is not answered by the action class's own singleton method-table methods" do
    klass = Class.new do
      include Axn
      def self.method_defined?(*) = false
      def self.private_method_defined?(*) = false
      def self.instance_method(*) = raise("instance_method explodes")
    end

    expect { klass.class_eval { expects :class } }
      .to raise_error(Axn::ContractViolation::ReservedAttributeError, /`class`/)
  end

  it "still admits a legal name on such a class, and reads the caller's value back" do
    klass = Class.new do
      include Axn
      def self.method_defined?(*) = false
      def self.instance_method(*) = raise("instance_method explodes")
      expects :fine_name
      exposes :out
      def call = expose(out: fine_name)
    end

    expect(klass.call(fine_name: "value").out).to eq("value")
  end

  it "names the owner in the message, and the rename that gets around it" do
    expect { build_axn { expects :class } }
      .to raise_error(Axn::ContractViolation::ReservedAttributeError, /Kernel.*`as:`/m)
  end
end

# The outbound half of the same rule, judged against Axn::Result — the object an exposure's reader is
# defined on. One receiver, and nothing on it is surrenderable, so the examples here mark the
# boundary between "Result answers to this" and "nothing does" rather than a sugar/machinery line.
RSpec.describe "reserved names for exposures" do
  describe "names Result owns" do
    %i[error message ok? outcome exception elapsed_time finalized? fail!
       declared_fields deconstruct_keys hash class inspect __action__ __exposed_keys__].each do |name|
      it "rejects `exposes :#{name}`" do
        expect { build_axn { exposes name } }
          .to raise_error(Axn::ContractViolation::ReservedAttributeError)
      end
    end

    it "rejects deconstruct_keys rather than breaking pattern matching" do
      expect { build_axn { exposes :deconstruct_keys } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /deconstruct_keys/)
    end

    # Not a Result method but a universal one: a Result whose `hash` answered with an exposure would
    # collide with every other such Result in a Hash or Set.
    it "rejects `exposes :hash`, which Results are stored by" do
      expect { build_axn { exposes :hash } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /hash/)
    end

    it "rejects a private method Result dispatches on itself" do
      expect { build_axn { exposes :_fail_standalone? } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError)
    end
  end

  # An exposed field is also an implicitly-allowed field on the INBOUND facade, which builds a reader
  # for it so the action body can read back what it exposed. That reader reads provided_data, so an
  # exposure named after one of that facade's own methods answers nil in the body instead of running
  # it — the two names that reach only this way.
  describe "names the inbound facade owns" do
    %i[default_error default_success].each do |name|
      it "rejects `exposes :#{name}`" do
        expect { build_axn { exposes name } }
          .to raise_error(Axn::ContractViolation::ReservedAttributeError, /#{name}/)
      end
    end

    it "leaves the helper answering in the action body" do
      klass = build_axn do
        exposes :probe
        def call = expose(probe: default_error)
      end

      expect(klass.call.probe).to eq("Something went wrong")
    end
  end

  # Two names no reader ever touches, so ownership cannot see them — an exposure and axn's machinery
  # share a KEY instead, and the machinery wins silently. Both refusals are derived from what their
  # consumer emits (Result::PATTERN_MATCH_KEYS, which deconstruct_keys builds its hash from; the
  # `fail!`/`done!` signatures), never from a second list.
  describe "keys an exposure would collide with rather than shadow" do
    it "rejects `exposes :ok`, which a pattern match would bind instead of the outcome" do
      expect { build_axn { exposes :ok } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /pattern matching/)
    end

    it "rejects `exposes :finalized` for the same reason" do
      expect { build_axn { exposes :finalized } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /pattern matching/)
    end

    it "covers every key deconstruct_keys reports" do
      Axn::Result::PATTERN_MATCH_KEYS.each_key do |key|
        expect { build_axn { exposes key } }.to raise_error(Axn::ContractViolation::ReservedAttributeError)
      end
    end

    it "leaves a pattern match reporting the outcome" do
      result = build_axn { def call = nil }.call

      expect(result.deconstruct_keys(nil)).to include(ok: true, outcome: :success, finalized: true)
    end

    it "rejects `exposes :standalone`, which `fail!` would bind as its control keyword" do
      expect { build_axn { exposes :standalone } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /control keyword/)
    end

    it "covers every control keyword `fail!`/`done!` take" do
      expect(Axn::Core::SETTLEMENT_CONTROL_KWARGS).not_to be_empty
      Axn::Core::SETTLEMENT_CONTROL_KWARGS.each do |kwarg|
        expect { build_axn { exposes kwarg } }.to raise_error(Axn::ContractViolation::ReservedAttributeError)
      end
    end
  end

  describe "names lifted because nothing owns or emits them" do
    %i[each_pair result inputs ambient_context].each do |name|
      it "allows `exposes :#{name}`" do
        klass = build_axn do
          exposes name
          define_method(:call) { expose(name => "value") }
        end

        expect(klass.call.public_send(name)).to eq("value")
      end
    end

    it "allows a name nothing owns" do
      expect { build_axn { exposes :widget } }.not_to raise_error
    end
  end

  # A boolean exposure aliases `<field>?` onto the same singleton, so that name is judged too — and
  # a private owner counts, because Result dispatches those on itself: `_fail_standalone?` decides
  # whether a declared base message is attached to a `fail!` reason.
  describe "the boolean predicate a declaration also lands" do
    it "rejects a boolean exposure whose predicate would take a private Result method" do
      expect { build_axn { exposes :_fail_standalone, type: :boolean } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /_fail_standalone\?/)
    end

    it "rejects a boolean exposure whose predicate would take a public one" do
      expect { build_axn { exposes :frozen, type: :boolean } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /frozen\?/)
    end

    it "leaves the same name declarable when it lands no predicate" do
      klass = build_axn do
        exposes :_fail_standalone
        def call = expose(_fail_standalone: true)
      end

      expect(klass.call._fail_standalone).to be(true)
    end

    it "still generates the predicate for a name Result does not own" do
      klass = build_axn do
        exposes :approved, type: :boolean
        def call = expose(approved: true)
      end

      expect(klass.call.approved?).to be(true)
    end

    # The refusal above is what keeps this true: with the predicate defined, `_fail_standalone?`
    # answered the exposure and the declared base was dropped from the failure message.
    it "leaves error resolution intact for a boolean exposure it does allow" do
      klass = build_axn do
        error "Base trouble"
        exposes :flagged, type: :boolean
        def call
          expose(flagged: true)
          fail! "boom"
        end
      end

      expect(klass.call.error).to eq("Base trouble: boom")
    end
  end

  # The definition-site half of the same rule: the declaration guard is the primary defence, but a
  # config assigned straight onto a class never passes through the DSL, and a facade must not hand its
  # own method away to one.
  describe "the facade's own backstop" do
    it "declines to define a reader over a facade method for a config that skipped the DSL" do
      klass = build_axn do
        exposes :probe
        def call = expose(probe: default_error)
      end
      config = Axn::Core::Contract::FieldConfig.new(field: :default_error, validations: {}, reader_as: :default_error)
      klass.external_field_configs = (klass.external_field_configs + [config]).freeze

      expect(klass.call.probe).to eq("Something went wrong")
    end

    it "still defines a reader for a wire key Ruby owns, which the inbound facade must answer" do
      klass = build_axn do
        expects :format, as: :fmt
        exposes :out
        def call = expose(out: fmt)
      end

      expect(klass.call(format: "csv").out).to eq("csv")
    end
  end

  # `exposes` takes neither `as:` nor `prefix:`, so an exposed field's name IS its reader: there is no
  # equivalent of the inbound escape hatch, and the message must not advertise one.
  describe "the absence of an escape hatch" do
    it "has no `as:`" do
      expect { build_axn { exposes :widget, as: :other } }
        .to raise_error(ArgumentError, /Unknown key\(s\) :as/)
    end

    it "has no `prefix:`" do
      expect { build_axn { exposes :widget, prefix: :out_ } }
        .to raise_error(ArgumentError, /Unknown key\(s\) :prefix/)
    end

    it "names the owner and tells the author to rename the field" do
      expect { build_axn { exposes :class } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /Kernel.*rename the field/m)
    end

    # The worst case of deriving from a live method table: an Object monkeypatch is usually an
    # anonymous module, whose inspect (`#<Module:0x…>`) names nothing an author could act on.
    it "points at the source when the owner has no name" do
      Object.include(Module.new { def some_patched_name = "patched" })

      expect { build_axn { exposes :some_patched_name } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /an anonymous module \(.*reserved_names_spec\.rb:\d+\)/)
    ensure
      Object.send(:undef_method, :some_patched_name)
    end

    # Composing this message must not run the OWNER's code. An Object monkeypatch is the author's own
    # module, and one that defines `self.name`/`inspect`/`instance_method` — a DSL gem doing so is
    # ordinary — would otherwise have that code run mid-message, and one that raises would replace the
    # collision error with its own failure.
    it "names the owner without dispatching the owner's own singleton methods" do
      Object.include(Module.new do
        def self.name = raise("name explodes")
        def self.inspect = raise("inspect explodes")
        def self.instance_method(*) = raise("instance_method explodes")

        def hostile_patched_name = "patched"
      end)

      expect { build_axn { exposes :hostile_patched_name } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /hostile_patched_name.*anonymous module/m)
    ensure
      Object.send(:undef_method, :hostile_patched_name)
    end

    it "does not offer `as:`, which exposes would refuse" do
      expect { build_axn { exposes :class } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError) { |e| expect(e.message).not_to include("as:") }
    end
  end
end
