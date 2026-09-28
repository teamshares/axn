# frozen_string_literal: true

require "pp"

RSpec.describe Axn::Extensions::Auth::Bearer do
  # Any object answering #header(name) is a request — no Rack involved.
  let(:request_class) do
    Struct.new(:headers) do
      def header(name) = headers.find { |key, _| key.casecmp?(name) }&.last
    end
  end

  def request(headers = {}) = request_class.new(headers)

  def bearer(token) = request("Authorization" => "Bearer #{token}")

  let(:auth) { Axn::Extensions::Auth }

  describe "#call" do
    subject(:strategy) { described_class.new(keys: { "data_pipeline" => "pipeline-key", "ops" => "ops-key" }) }

    it "returns an ok verdict naming the principal whose key matched" do
      expect(strategy.call(bearer("pipeline-key"))).to eq(auth::Verdict.ok("data_pipeline"))
      expect(strategy.call(bearer("ops-key")).principal).to eq("ops")
    end

    it "rejects a wrong key as a mismatch" do
      expect(strategy.call(bearer("nope"))).to eq(auth::CREDENTIALS_MISMATCH)
    end

    it "reports an absent, blank or non-Bearer Authorization as missing" do
      expect(strategy.call(request)).to eq(auth::CREDENTIALS_MISSING)
      expect(strategy.call(request("Authorization" => "  "))).to eq(auth::CREDENTIALS_MISSING)
      expect(strategy.call(request("Authorization" => "Basic cGlwZWxpbmUta2V5"))).to eq(auth::CREDENTIALS_MISSING)
      expect(strategy.call(request("Authorization" => "Bearer "))).to eq(auth::CREDENTIALS_MISSING)
    end

    it "accepts the scheme case-insensitively" do
      expect(strategy.call(request("Authorization" => "bearer pipeline-key")).ok?).to be(true)
    end

    it "stringifies principal ids" do
      expect(described_class.new(keys: { data_pipeline: "k" }).call(bearer("k")).principal).to eq("data_pipeline")
    end
  end

  describe "a custom header" do
    subject(:strategy) { described_class.new(keys: { "svc" => "k1" }, header: "X-API-Key") }

    it "reads the header's raw (stripped) value" do
      expect(strategy.call(request("X-API-Key" => " k1 ")).principal).to eq("svc")
      expect(strategy.call(request("X-API-Key" => "k2"))).to eq(auth::CREDENTIALS_MISMATCH)
      expect(strategy.call(request)).to eq(auth::CREDENTIALS_MISSING)
    end

    it "ignores Authorization entirely" do
      expect(strategy.call(bearer("k1"))).to eq(auth::CREDENTIALS_MISSING)
    end

    it "publishes neutral metadata: no scheme, the header name, no challenge header" do
      expect(strategy.scheme).to be_nil
      expect(strategy.header).to eq("X-API-Key")
      expect(strategy.unauthorized_headers).to eq({})
    end
  end

  describe "rotation" do
    it "accepts any key in an Array" do
      strategy = described_class.new(keys: { "svc" => %w[old new] })
      expect(strategy.call(bearer("old")).ok?).to be(true)
      expect(strategy.call(bearer("new")).ok?).to be(true)
    end

    it "accepts a Proc returning an Array" do
      strategy = described_class.new(keys: { "svc" => -> { %w[old new] } })
      expect(strategy.call(bearer("new")).principal).to eq("svc")
    end

    it "re-resolves a deferred key on every request" do
      current = "first"
      strategy = described_class.new(keys: { "svc" => -> { current } })
      expect(strategy.call(bearer("first")).ok?).to be(true)
      current = "second"
      expect(strategy.call(bearer("first")).ok?).to be(false)
      expect(strategy.call(bearer("second")).ok?).to be(true)
    end

    it "passes the request to a one-arity Proc" do
      strategy = described_class.new(keys: { "svc" => ->(req) { req.header("X-Tenant") == "a" ? "ka" : "kb" } })
      expect(strategy.call(request("Authorization" => "Bearer ka", "X-Tenant" => "a")).ok?).to be(true)
    end
  end

  describe "timing" do
    it "compares against every candidate of every principal, even after a match" do
      strategy = described_class.new(keys: { "a" => %w[a1 a2], "b" => "b1" })
      allow(auth).to receive(:secure_compare).and_call_original
      strategy.call(bearer("a1"))
      expect(auth).to have_received(:secure_compare).exactly(3).times
    end
  end

  describe "misconfiguration" do
    it "refuses empty or non-Hash keys at construction" do
      expect { described_class.new(keys: {}) }.to raise_error(auth::ConfigurationError, /keys/)
      expect { described_class.new(keys: "k") }.to raise_error(auth::ConfigurationError, /keys/)
    end

    it "refuses a literal blank key at construction, naming the principal but not the value" do
      expect { described_class.new(keys: { "svc" => "" }) }
        .to raise_error(auth::ConfigurationError, /svc.*empty String/)
      expect { described_class.new(keys: { "svc" => [] }) }.to raise_error(auth::ConfigurationError, /svc/)
    end

    it "raises (never 401s) when a deferred key resolves blank at request time" do
      strategy = described_class.new(keys: { "svc" => -> { "" } })
      expect { strategy.call(bearer("")) }.to raise_error(auth::ConfigurationError)
      nil_strategy = described_class.new(keys: { "svc" => -> {} })
      expect { nil_strategy.call(bearer("x")) }.to raise_error(auth::ConfigurationError, /NilClass/)
    end

    it "raises when one token authenticates as two principals" do
      strategy = described_class.new(keys: { "a" => "same", "b" => -> { "same" } })
      expect { strategy.call(bearer("same")) }.to raise_error(auth::ConfigurationError, /"a", "b"/)
    end

    it "refuses principal ids that collapse to the same String" do
      expect { described_class.new(keys: { svc: "k1", "svc" => "k2" }) }
        .to raise_error(auth::ConfigurationError, /:svc and "svc" both name principal "svc"/)
    end

    it "refuses a principal id that is not a non-empty String or Symbol" do
      expect { described_class.new(keys: { 1 => "k" }) }.to raise_error(auth::ConfigurationError, /principal id.*Integer/)
      expect { described_class.new(keys: { "" => "k" }) }.to raise_error(auth::ConfigurationError, /principal id/)
    end

    # A presented token is stripped before comparison, so a padded key could never match: that is a
    # misconfiguration (a secret file's trailing newline), not a stream of 401s.
    it "refuses a literal key with surrounding whitespace at construction" do
      expect { described_class.new(keys: { "svc" => "k1\n" }) }
        .to raise_error(auth::ConfigurationError, /"svc".*leading or trailing whitespace/)
      expect { described_class.new(keys: { "svc" => ["ok", " k2"] }) }.to raise_error(auth::ConfigurationError, /whitespace/)
    end

    it "raises when a deferred key resolves with surrounding whitespace" do
      strategy = described_class.new(keys: { "svc" => -> { "k1\n" } })
      expect { strategy.call(bearer("k1")) }.to raise_error(auth::ConfigurationError, /whitespace/)
    end

    it "accepts a key with inner whitespace" do
      expect(described_class.new(keys: { "svc" => "a b" }).call(bearer("a b")).principal).to eq("svc")
    end

    it "renders a String-subclass principal id without calling its own methods" do
      hostile = Class.new(String) do
        def to_s = raise("to_s ran")
        def inspect = raise("inspect ran")
      end
      strategy = described_class.new(keys: { hostile.new("svc") => "k" })
      expect(strategy.call(bearer("k")).principal).to eq("svc")
      expect { described_class.new(keys: { hostile.new("svc") => "" }) }.to raise_error(auth::ConfigurationError, /"svc"/)
      expect { described_class.new(keys: { svc: "k1", hostile.new("svc") => "k2" }) }
        .to raise_error(auth::ConfigurationError, /both name principal "svc"/)
    end

    it "refuses a blank header name" do
      expect { described_class.new(keys: { "svc" => "k" }, header: "") }.to raise_error(auth::ConfigurationError, /header/)
    end
  end

  describe "literal keys" do
    it "are detached from the caller's objects" do
      scalar = +"k1"
      element = +"k2"
      list = [element]
      strategy = described_class.new(keys: { "a" => scalar, "b" => list })
      scalar.replace("attacker")
      element.replace("attacker")
      list << "attacker"
      expect(strategy.call(bearer("attacker"))).to eq(auth::CREDENTIALS_MISMATCH)
      expect(strategy.call(bearer("k1")).principal).to eq("a")
      expect(strategy.call(bearer("k2")).principal).to eq("b")
    end
  end

  describe "the header name" do
    it "is detached from the caller's String" do
      name = +"X-API-Key"
      strategy = described_class.new(keys: { "svc" => "k1" }, header: name)
      name.replace("Authorization")
      expect(strategy.header).to eq("X-API-Key")
      expect(strategy.header).to be_frozen
      expect(strategy.scheme).to be_nil
      expect(strategy.call(bearer("k1"))).to eq(auth::CREDENTIALS_MISSING)
    end
  end

  describe "metadata and redaction" do
    subject(:strategy) { described_class.new(keys: { "svc" => "super-secret-value" }) }

    it "publishes principals, scheme, header and the RFC 6750 challenge" do
      expect(strategy.principals).to eq(["svc"])
      expect(strategy.scheme).to eq("Bearer")
      expect(strategy.header).to eq("Authorization")
      expect(strategy.unauthorized_headers).to eq("www-authenticate" => "Bearer")
    end

    it "never renders a key through inspect or pp" do
      expect(strategy.inspect).not_to include("super-secret-value")
      expect(strategy.inspect).to include("svc")
      expect(strategy.pretty_inspect).not_to include("super-secret-value")
    end
  end
end
