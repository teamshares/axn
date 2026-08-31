# frozen_string_literal: true

# PRO-3278: the `axn.call` span seam (Axn::Extensions::Tracing.current_span / .annotate_span) reads
# through Axn::Core::NestingTracking, which is scoped by ActiveSupport::IsolatedExecutionState — a
# Rails-configured setting (config.active_support.isolation_level). The non-Rails suite
# (spec/axn/internal/tracing/current_span_spec.rb) covers the mechanism exhaustively; this confirms it
# behaves identically under a real Rails app rather than assuming the isolation model carries over.
RSpec.describe "Axn::Extensions::Tracing.current_span under Rails" do
  after { Axn.config.reset!(:tracer) }

  let(:distinct_span_tracer) do
    Class.new do
      def in_span(*, **)
        span = Class.new do
          attr_reader :attributes

          def initialize = @attributes = {}
          def set_attribute(key, value) = @attributes[key] = value
        end.new
        yield(span)
      end
    end.new
  end

  it "resolves to each level's own span in a nested chain" do
    Axn.config.tracer = distinct_span_tracer
    spans = {}
    inner = build_axn { define_method(:call) { spans[:inner] = Axn::Extensions::Tracing.current_span } }
    outer = build_axn do
      define_method(:call) do
        spans[:outer_before] = Axn::Extensions::Tracing.current_span
        inner.call
        spans[:outer_after] = Axn::Extensions::Tracing.current_span
      end
    end

    outer.call

    expect(spans[:inner]).not_to be_nil
    expect(spans[:outer_before]).to equal(spans[:outer_after])
    expect(spans[:outer_before]).not_to equal(spans[:inner])
  end

  it "writes attributes onto the same span finalize_span annotates with axn.outcome" do
    Axn.config.tracer = distinct_span_tracer
    seen_span = nil
    build_axn do
      define_method(:call) do
        Axn::Extensions::Tracing.annotate_span("gen_ai.request.model" => "gpt-4o-mini")
        seen_span = Axn::Extensions::Tracing.current_span
      end
    end.call

    expect(seen_span.attributes).to include("gen_ai.request.model" => "gpt-4o-mini", "axn.outcome" => "success")
  end

  it "is nil outside any action and after the call returns" do
    expect(Axn::Extensions::Tracing.current_span).to be_nil

    Axn.config.tracer = distinct_span_tracer
    build_axn.call

    expect(Axn::Extensions::Tracing.current_span).to be_nil
  end
end
