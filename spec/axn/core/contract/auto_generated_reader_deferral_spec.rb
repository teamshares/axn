# frozen_string_literal: true

require "spec_helper"

# `_reader_name_available?` defers to a pre-existing method rather than clobbering it, leaving a
# debug-level breadcrumb behind — but the breadcrumb is a side channel and the VERDICT ("is the name
# free") is this method's own return value.
RSpec.describe "auto-generated reader deferral" do
  it "defers to a pre-existing boolean predicate rather than clobbering it" do
    klass = Class.new do
      include Axn
      def active? = "PRE-EXISTING"
      expects :active, type: :boolean
      def call = nil
    end

    expect(klass.send(:new).active?).to eq("PRE-EXISTING")
  end

  # A diagnostic may not decide whether a declaration succeeds. `best_effort` returns nil on
  # failure, so a naive rewrite that left the guard's return value AS the verdict would turn "the
  # name is taken" into "the name is free" whenever the logger raises — letting the auto-generated
  # reader clobber the method the author wrote.
  it "still defers to the pre-existing method when the breadcrumb's logger raises" do
    allow(Axn.config.logger).to receive(:debug).and_raise(IOError, "closed stream")

    klass = Class.new do
      include Axn
      def active? = "PRE-EXISTING"
      expects :active, type: :boolean
      def call = nil
    end

    expect(klass.send(:new).active?).to eq("PRE-EXISTING")
  end
end
