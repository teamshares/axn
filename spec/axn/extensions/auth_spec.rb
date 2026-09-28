# frozen_string_literal: true

RSpec.describe Axn::Extensions::Auth do
  describe ".secure_compare" do
    it "is true for equal strings" do
      expect(described_class.secure_compare("s3cret", "s3cret")).to be(true)
    end

    it "is false for different strings of different lengths, without raising" do
      expect(described_class.secure_compare("short", "much-longer-secret")).to be(false)
    end

    it "is false when either side is nil" do
      expect(described_class.secure_compare(nil, "x")).to be(false)
      expect(described_class.secure_compare("x", nil)).to be(false)
    end
  end

  describe ".require_secret!" do
    it "returns a non-empty String unchanged" do
      expect(described_class.require_secret!("Bearer", "abc")).to eq("abc")
    end

    it "raises ConfigurationError naming an empty String, never its bytes" do
      expect { described_class.require_secret!("Bearer", "") }
        .to raise_error(described_class::ConfigurationError, "Bearer secret must be a non-empty String (got an empty String)")
    end

    it "raises naming the class of a non-String" do
      expect { described_class.require_secret!("Bearer", nil, label: "key") }
        .to raise_error(described_class::ConfigurationError, "Bearer key must be a non-empty String (got NilClass)")
      expect { described_class.require_secret!("Bearer", false) }
        .to raise_error(described_class::ConfigurationError, /got FalseClass/)
    end

    it "returns a frozen, native copy, detached from the caller's object" do
      original = +"abc"
      secret = described_class.require_secret!("Bearer", original)
      original.replace("zzz")
      expect(secret).to eq("abc")
      expect(secret).to be_frozen
      expect(secret.instance_of?(String)).to be(true)
    end

    # A guard downstream gems rely on to refuse weak keys cannot ask the value about itself.
    it "reads emptiness and type natively, not through the value's own methods" do
      lying_string = Class.new(String) { def empty? = false }.new("")
      expect { described_class.require_secret!("Bearer", lying_string) }
        .to raise_error(described_class::ConfigurationError, /got an empty String/)

      impostor = Object.new
      def impostor.is_a?(*) = true
      def impostor.class = raise("replaced the error")
      expect { described_class.require_secret!("Bearer", impostor) }
        .to raise_error(described_class::ConfigurationError, /got Object\)/)
    end

    it "returns a String subclass's bytes as a plain String, so its overrides never run downstream" do
      subclass = Class.new(String) { def to_s = "overridden" }
      secret = described_class.require_secret!("Bearer", subclass.new("real"))
      expect(secret.instance_of?(String)).to be(true)
      expect(secret).to eq("real")
    end

    it "raises the caller's error class when given" do
      custom = Class.new(StandardError)
      expect { described_class.require_secret!("x", "", error: custom) }.to raise_error(custom)
    end

    it "is a tagged public error that is also an ArgumentError" do
      expect(described_class::ConfigurationError.ancestors).to include(Axn::Error, ArgumentError)
    end
  end

  describe ".deferred? / .resolve" do
    let(:request) { Struct.new(:id).new(7) }

    it "defers only Procs" do
      expect(described_class.deferred?(-> {})).to be(true)
      expect(described_class.deferred?(proc { |_r| })).to be(true)
      expect(described_class.deferred?("literal")).to be(false)
      expect(described_class.deferred?(:api_key)).to be(false)
      expect(described_class.deferred?(Object.new.method(:to_s))).to be(false)
    end

    it "decides deferral natively, so a value claiming to be a Proc is still a literal" do
      impostor = Object.new
      def impostor.is_a?(*) = true
      expect(described_class.deferred?(impostor)).to be(false)
      expect(described_class.resolve(impostor, request)).to equal(impostor)
    end

    it "reads a Proc's arity natively" do
      sneaky = Class.new(Proc) { def arity = raise("arity ran") }.new { "zero" }
      expect(described_class.resolve(sneaky, request)).to eq("zero")
    end

    it "reports whether resolve can call a deferred value with zero arguments or one request" do
      callable = [-> {}, ->(_req) {}, ->(_req, _opt = nil) {}, ->(*_args) {}, proc { |_a, _b| }, "literal"]
      uncallable = [->(_req, _ctx) {}, ->(request:) { request }, ->(**_opts) {}, proc { |request:| request }]
      callable.each { |value| expect(described_class.resolvable?(value)).to be(true), value.inspect }
      uncallable.each { |value| expect(described_class.resolvable?(value)).to be(false), value.inspect }
    end

    it "calls a zero-arity Proc with no arguments" do
      expect(described_class.resolve(-> { "zero" }, request)).to eq("zero")
    end

    # An explicit one-parameter block is the point here: `&:id` would be a lambda of arity -2.
    # rubocop:disable Style/SymbolProc
    it "calls a one-arity Proc with the request" do
      expect(described_class.resolve(->(req) { req.id }, request)).to eq(7)
      expect(described_class.resolve(proc { |req| req.id }, request)).to eq(7)
    end
    # rubocop:enable Style/SymbolProc

    it "passes a literal through, including a Symbol (core never resolves a name against the request)" do
      expect(described_class.resolve("literal", request)).to eq("literal")
      expect(described_class.resolve(:api_key, request)).to eq(:api_key)
    end
  end

  describe ".verified?" do
    it "asks #ok? first, so a rejecting verdict object is never read as truthy" do
      expect(described_class.verified?(described_class::Verdict.ok("p"))).to be(true)
      expect(described_class.verified?(described_class::CREDENTIALS_MISMATCH)).to be(false)
      expect(described_class.verified?(Struct.new(:ok?).new(false))).to be(false)
    end

    it "asks #ok? even when the verdict's own respond_to? denies it" do
      liar = Struct.new(:ok?).new(false)
      def liar.respond_to?(*) = false
      expect(described_class.verified?(liar)).to be(false)
    end

    it "asks #ok? of a method_missing proxy that does not advertise it" do
      proxy = Class.new(BasicObject) do
        def method_missing(name, *) = name == :ok? ? false : super # rubocop:disable Style/MissingRespondToMissing
      end.new
      expect(described_class.verified?(proxy)).to be(false)
    end

    it "does not mistake a NoMethodError raised inside #ok? for an absent #ok?" do
      broken = Object.new
      def broken.ok? = nil.nope
      expect { described_class.verified?(broken) }.to raise_error(NoMethodError, /nope/)
    end

    it "reads a genuine Verdict through its own member, not an override" do
      subclass = Class.new(described_class::Verdict) { def ok? = true }
      expect(described_class.verified?(subclass.rejected(:denied))).to be(false)
      expect(described_class.normalize(subclass.rejected(:denied)).instance_of?(described_class::Verdict)).to be(true)
    end

    it "reads anything without #ok? for truthiness" do
      expect(described_class.verified?(true)).to be(true)
      expect(described_class.verified?(Object.new)).to be(true)
      expect(described_class.verified?(nil)).to be(false)
      expect(described_class.verified?(false)).to be(false)
    end
  end

  describe ".normalize" do
    it "returns a Verdict unchanged" do
      verdict = described_class::Verdict.ok("data_pipeline")
      expect(described_class.normalize(verdict)).to equal(verdict)
    end

    it "does not pass through an object merely claiming to be a Verdict" do
      impostor = Struct.new(:ok?, :reason, :principal).new(false, :denied, "admin")
      def impostor.is_a?(*) = true
      expect(described_class.normalize(impostor)).to eq(described_class::Verdict.rejected(:denied))
    end

    it "reads reason and principal even when respond_to? denies them" do
      liar = Struct.new(:ok?, :reason).new(false, :denied)
      def liar.respond_to?(*) = false
      expect(described_class.normalize(liar)).to eq(described_class::Verdict.rejected(:denied))
    end

    it "reads a duck-typed verdict's principal and reason" do
      ok = Struct.new(:ok?, :principal).new(true, "svc")
      rejected = Struct.new(:ok?, :reason).new(false, :signature_mismatch)
      expect(described_class.normalize(ok)).to eq(described_class::Verdict.ok("svc"))
      expect(described_class.normalize(rejected)).to eq(described_class::Verdict.rejected(:signature_mismatch))
    end

    it "never carries a principal on a rejection" do
      rejected = Struct.new(:ok?, :principal).new(false, "svc")
      expect(described_class.normalize(rejected).principal).to be_nil
    end

    it "maps booleans and bare objects" do
      expect(described_class.normalize(true)).to eq(described_class::Verdict.ok)
      expect(described_class.normalize(nil)).to eq(described_class::Verdict.rejected(:rejected))
      expect(described_class.normalize(false).reason).to eq(:rejected)
    end
  end

  describe "Verdict" do
    it "cannot be constructed as a rejection carrying a principal" do
      expect { described_class::Verdict.new(ok: false, reason: :denied, principal: "admin") }
        .to raise_error(ArgumentError, /rejected Verdict cannot carry a principal/)
      expect { described_class::Verdict.rejected(:denied).with(principal: "admin") }.to raise_error(ArgumentError)
    end

    it "cannot be constructed as an ok verdict carrying a reason" do
      expect { described_class::Verdict.new(ok: true, reason: :denied, principal: nil) }
        .to raise_error(ArgumentError, /ok Verdict cannot carry a reason/)
    end

    it "checks its invariants without asking the members about themselves" do
      claims_true = Object.new
      def claims_true.equal?(*) = true
      claims_nil = Object.new
      def claims_nil.nil? = true
      expect { described_class::Verdict.new(ok: claims_true) }.to raise_error(ArgumentError, /true or false/)
      expect { described_class::Verdict.new(ok: false, reason: :x, principal: claims_nil) }.to raise_error(ArgumentError, /principal/)
      expect { described_class::Verdict.new(ok: true, reason: claims_nil) }.to raise_error(ArgumentError, /reason/)
    end

    it "requires ok to be true or false, so ok? is a real predicate" do
      expect { described_class::Verdict.new(ok: "yes", reason: nil, principal: nil) }
        .to raise_error(ArgumentError, /ok must be true or false/)
    end

    it "defaults reason and principal to nil" do
      expect(described_class::Verdict.new(ok: true)).to eq(described_class::Verdict.ok)
    end

    it "exposes frozen, shared rejection constants" do
      expect(described_class::CREDENTIALS_MISSING).to be_frozen
      expect(described_class::CREDENTIALS_MISSING.reason).to eq(:credentials_missing)
      expect(described_class::CREDENTIALS_MISMATCH.reason).to eq(:credentials_mismatch)
      expect(described_class::CREDENTIALS_MISMATCH.ok?).to be(false)
    end
  end
end
