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
    # sugar — and are refused by the SECOND receiver: the inbound facade the value is read from, where
    # a generated reader would replace machinery every other field's reader depends on.
    %i[declared_fields action action_name default_error default_success fail!].each do |name|
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

  it "applies the same rule to an `as:` reader name" do
    expect { build_axn { expects :thing, as: :class } }
      .to raise_error(Axn::ContractViolation::ReservedAttributeError, /class/)
  end

  it "applies the same rule to a `prefix:` reader name" do
    expect { build_axn { expects :name, prefix: :in } }.not_to raise_error
  end

  it "names the owner in the message so the author knows what is in the way" do
    expect { build_axn { expects :class } }
      .to raise_error(Axn::ContractViolation::ReservedAttributeError, /Kernel.*as:/m)
  end
end
