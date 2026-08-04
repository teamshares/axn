# frozen_string_literal: true

require "open3"

# The `:client` strategy's REGISTRATION, which nothing in `client_spec.rb` can pin: that file clears the registry
# and registers the strategy itself in a `before` hook, so an example asserting the strategy is registered there
# only asserts what the hook just did — and passed identically when registration was gated on `defined?(Faraday)`.
#
# That gate was observable only in a process that loaded axn BEFORE faraday, and — `require` being idempotent —
# only once per process. Hence a fresh Ruby per example: this suite has both gems loaded, and re-requiring the
# strategy file here would no-op.
RSpec.describe "Axn::Extras::Strategies::Client registration" do
  def repo_root = File.expand_path("../../../..", __dir__)

  # `RUBYOPT` carries bundler's `-rbundler/setup`, so the child resolves the same bundle this suite runs against —
  # which loads faraday's LOAD PATH without loading faraday itself, exactly the ordering at issue.
  def run(body)
    out, status = Open3.capture2e(RbConfig.ruby, "-e", body, chdir: repo_root)
    [out, status]
  end

  it "registers the strategy in a process that has not loaded faraday" do
    out, status = run(<<~RUBY)
      require "axn"
      raise "faraday was already loaded, so this proves nothing" if defined?(Faraday)
      print Axn::Strategies.all[:client] == Axn::Extras::Strategies::Client
    RUBY

    expect(status).to be_success, "load failed: #{out}"
    expect(out).to eq("true")
  end

  it "resolves `use :client` when axn was loaded before faraday" do
    out, status = run(<<~RUBY)
      require "axn"
      klass = Class.new do
        include Axn
        use :client, url: "https://example.com"
      end
      print [defined?(Faraday) ? "faraday loaded" : "faraday absent", klass.allocate.client.class.name].inspect
    RUBY

    expect(status).to be_success, "load failed: #{out}"
    expect(out).to eq('["faraday loaded", "Faraday::Connection"]')
  end

  describe "when faraday cannot be loaded" do
    # A bundle without the gem, simulated at the one boundary that decides it: `require "faraday"` raises what
    # Ruby raises for an absent file, path included. In a fresh process, so the constant is genuinely not defined
    # either — a stub inside this suite would leave `Faraday` loaded and could pass for the wrong reason.
    def run_without_faraday(body)
      run(<<~RUBY)
        module Kernel
          alias_method :require_before_faraday_removed, :require
          def require(name)
            return require_before_faraday_removed(name) unless name == "faraday"

            error = LoadError.new("cannot load such file -- faraday")
            error.define_singleton_method(:path) { "faraday" }
            raise error
          end
        end

        #{body}
      RUBY
    end

    it "raises at declaration, naming the gem to add" do
      out, status = run_without_faraday(<<~RUBY)
        require "axn"
        begin
          Class.new do
            include Axn
            use :client, url: "https://example.com"
          end
        rescue LoadError => e
          print e.message
        end
      RUBY

      expect(status).to be_success, "load failed: #{out}"
      expect(out).to include("To use the :client strategy, add 'faraday' to your Gemfile")
    end

    it "still registers the strategy, so the failure names the missing gem rather than the strategy" do
      out, status = run_without_faraday(<<~RUBY)
        require "axn"
        print [defined?(Faraday).nil?, Axn::Strategies.all.key?(:client)].inspect
      RUBY

      expect(status).to be_success, "load failed: #{out}"
      expect(out).to eq("[true, true]")
    end
  end

  # The other half of that message's contract: a LoadError raised from faraday's OWN requires names a different
  # file and must not be reported as a missing faraday. In-process — what is pinned is which error is re-raised.
  it "re-raises a LoadError that names a file other than faraday" do
    nested = LoadError.new("cannot load such file -- faraday/net_http")
    nested.define_singleton_method(:path) { "faraday/net_http" }
    allow(Axn::Extras::Strategies::Client).to receive(:require).with("faraday").and_raise(nested)

    expect { Axn::Extras::Strategies::Client.ensure_faraday_available! }
      .to raise_error(LoadError, "cannot load such file -- faraday/net_http")
  end
end
