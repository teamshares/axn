# frozen_string_literal: true

require "open3"

# Each of these loads ONE file in a fresh process, without the umbrella `axn` entrypoint and without
# ActiveSupport. A config file whose default resolves through another component, or whose validation
# leans on a core-ext, works fine in the suite (where everything is loaded) and fails only for a
# consumer that requires the component directly — so the isolation has to be real to be tested.
RSpec.describe "loading config components in isolation" do
  # `Bundler.with_unbundled_env` is required, not optional politeness. Under `bundle exec`, RUBYOPT
  # carries `-rbundler/setup`, which evaluates axn.gemspec — and the gemspec
  # `require_relative "lib/axn/version"`s, so the child starts with Axn::VERSION already defined and
  # cannot detect a component that fails to require it. Bundler re-injects RUBYOPT into spawned
  # children, so overriding it in the env hash (with nil OR "") does not work; only this helper does.
  def load_in_fresh_process(script)
    Bundler.with_unbundled_env do
      out, status = Open3.capture2e(RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", "-e", script)
      [out.strip, status]
    end
  end

  it "resolves the tracer default when only axn/configuration is loaded" do
    out, status = load_in_fresh_process(<<~RUBY)
      require "axn/configuration"
      print Axn.config.tracer.inspect
    RUBY

    expect(status).to be_success, "expected a clean load, got: #{out}"
    expect(out).to eq("nil")
  end

  it "auto-detects a tracer when only axn/configuration is loaded and OpenTelemetry is present" do
    out, status = load_in_fresh_process(<<~RUBY)
      module OpenTelemetry
        def self.tracer_provider
          @tracer_provider ||= Object.new.tap do |provider|
            def provider.tracer(name, version) = "tracer(\#{name}, \#{version})"
          end
        end
      end

      require "axn/configuration"
      print Axn.config.tracer
    RUBY

    expect(status).to be_success, "expected a clean load, got: #{out}"
    expect(out).to eq("tracer(axn, #{Axn::VERSION})")
  end

  it "answers the capability probe for an uninspectable tracer when only axn/internal/tracing is loaded" do
    # A BasicObject proxy has no `method`, so the probe's rescue clause is evaluated — and that clause
    # names Extensions' swallowable allowlist, which this component has to require for itself.
    out, status = load_in_fresh_process(<<~RUBY)
      require "axn/internal/tracing"

      proxy = Class.new(BasicObject) do
        def in_span(_name, **) = nil
      end.new

      print Axn::Internal::Tracing.supports_record_exception_option?(proxy).inspect
    RUBY

    expect(status).to be_success, "expected a clean load, got: #{out}"
    expect(out).to eq("false")
  end

  it "raises ArgumentError, not NoMethodError, for a String validate: reason when only axn/configurable is loaded" do
    out, status = load_in_fresh_process(<<~RUBY)
      require "axn/configurable"

      klass = Class.new do
        extend Axn::Configurable::Settings
        setting :num, validate: ->(v) { v.is_a?(Integer) || "must be an Integer" }
      end

      begin
        klass.new.num = "nope"
        print "NO RAISE"
      rescue ArgumentError => e
        print e.message
      end
    RUBY

    expect(status).to be_success, "expected a clean load, got: #{out}"
    expect(out).to eq('num got invalid value: "nope" — must be an Integer')
  end

  it "falls back to the plain message for a blank String reason when only axn/configurable is loaded" do
    out, status = load_in_fresh_process(<<~RUBY)
      require "axn/configurable"

      klass = Class.new do
        extend Axn::Configurable::Settings
        setting :num, validate: ->(v) { v.is_a?(Integer) || "  " }
      end

      begin
        klass.new.num = "nope"
        print "NO RAISE"
      rescue ArgumentError => e
        print e.message
      end
    RUBY

    expect(status).to be_success, "expected a clean load, got: #{out}"
    expect(out).to eq('num got invalid value: "nope"')
  end
end
