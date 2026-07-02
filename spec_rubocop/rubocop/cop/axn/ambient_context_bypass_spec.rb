# frozen_string_literal: true

require_relative "../../../spec_helper"
require_relative "../../../../lib/rubocop/cop/axn/ambient_context_bypass"

RSpec.describe RuboCop::Cop::Axn::AmbientContextBypass do
  include RuboCop::RSpec::ExpectOffense
  subject(:cop) { described_class.new }

  it "flags a direct Current attribute read" do
    expect_offense(<<~RUBY)
      do_thing(Current.company)
               ^^^^^^^^^^^^^^^ Axn/AmbientContextBypass: Read ambient state via `expects :company, on: :ambient_context` instead of `Current` directly.
    RUBY
  end

  it "flags a top-level ::Current read" do
    expect_offense(<<~RUBY)
      x = ::Current.user
          ^^^^^^^^^^^^^^ Axn/AmbientContextBypass: Read ambient state via `expects :user, on: :ambient_context` instead of `Current` directly.
    RUBY
  end

  it "does not flag unrelated receivers" do
    expect_no_offenses("x = Time.current")
  end

  it "does not flag a Current assignment (setup, not a bypass read)" do
    expect_no_offenses("Current.company = c")
  end

  it "does not flag a Current call with arguments" do
    expect_no_offenses("Current.foo(bar)")
  end

  it "does not flag Current.reset (lifecycle API, not an attribute read)" do
    expect_no_offenses("Current.reset")
  end

  it "does not flag Current.instance (lifecycle API, not an attribute read)" do
    expect_no_offenses("Current.instance")
  end

  it "does not flag Current.attributes (lifecycle API, not an attribute read)" do
    expect_no_offenses("Current.attributes")
  end

  it "does not flag ::Current.reset (lifecycle API, not an attribute read)" do
    expect_no_offenses("::Current.reset")
  end
end
