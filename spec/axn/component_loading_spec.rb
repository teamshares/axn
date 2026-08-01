# frozen_string_literal: true

require "open3"

# Each of these loads ONE file in a fresh process, without the umbrella `axn` entrypoint and without
# ActiveSupport. A config file whose default resolves through another component, or whose validation
# leans on a core-ext, works fine in the suite (where everything is loaded) and fails only for a
# consumer that requires the component directly — so the isolation has to be real to be tested.
RSpec.describe "loading config components in isolation" do
  def load_in_fresh_process(script)
    out, status = Open3.capture2e(RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", "-e", script)
    [out.strip, status]
  end

  it "resolves the tracer default when only axn/configuration is loaded" do
    out, status = load_in_fresh_process(<<~RUBY)
      require "axn/configuration"
      print Axn.config.tracer.inspect
    RUBY

    expect(status).to be_success, "expected a clean load, got: #{out}"
    expect(out).to eq("nil")
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
