# frozen_string_literal: true

# The ActiveJob discard hook decides whether an exhausted job's exception gets REPORTED, and it skips
# `Axn::Failure` because a business failure is not an error to report. That is the same predicate class as
# `Extensions.owned_failure?` and `_fails_on?` — an instance answering for itself is an instance suppressing
# its own report — and it sits outside the core enumeration those were fixed under, so it is easy to miss.
#
# Rails-only: the hook is `after_discard`, which is Rails 7.1+, and the proxy class does not exist without
# ActiveJob loaded.
RSpec.describe "Axn::Async ActiveJob discard reporting" do
  before { skip "after_discard requires Rails 7.1+" unless ActiveJob::Base.respond_to?(:after_discard) }

  let(:action) do
    stub_const("DiscardProbeAxn", Class.new do
      include Axn
      async :active_job
      def call = nil
    end)
  end

  def discard(exception)
    job = action.send(:active_job_proxy_class).new
    job._axn_handle_discard(job, exception, action)
  end

  it "skips reporting for an Axn::Failure" do
    reported = []
    allow(Axn.config).to receive(:on_exception) { |e, **| reported << e }

    discard(Axn::Failure.new("business decision"))

    expect(reported).to be_empty
  end

  # Raises rather than lies, so the example fails if the question is asked at all. Outside StandardError AND
  # outside SWALLOWABLE_BEYOND_STANDARD_ERROR, so a dispatch would escape the discard hook — which runs after
  # the job has already exhausted its retries, i.e. the last chance the exception has to be reported.
  it "does not ask the exception whether it is a failure" do
    unswallowable = Class.new(Exception) # rubocop:disable Lint/InheritException
    hostile = Class.new(StandardError) do
      define_method(:is_a?) { |_klass| raise(unswallowable, "is_a? must not decide whether this is reported") }
      def kind_of?(klass) = is_a?(klass)
    end.new("exhausted")

    expect { discard(hostile) }.not_to raise_error
  end
end
