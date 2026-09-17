# frozen_string_literal: true

# `ContextFacade#initialize` used to read `singleton_class` unconditionally, even for a facade with no
# reader to define — the whole of `bare`'s share of PRO-3334's residual regression (94,400 bytes per
# 100 calls, measured with memory_profiler). `_facade_fields` now filters at declaration, and the
# constructor skips the read entirely when `reader_fields` is empty. This spec asserts the invariant
# directly, without a probe that itself would materialize the very thing under test.
RSpec.describe "context facade singleton elision" do
  # `Class#attached_object` (Ruby >= 3.2, this gem's floor) walks LIVE classes rather than touching the
  # object under test — calling `.singleton_class`, stubbing with `allow`, or `respond_to?` on a name
  # Ruby answers via `method_missing` would each materialize a singleton and silently void the
  # assertion. Verified separately: a fresh Object answers false here and true only once something
  # (deliberately) reads its `singleton_class`.
  def singleton_materialized?(obj)
    ObjectSpace.each_object(Class).any? { |c| c.singleton_class? && c.attached_object.equal?(obj) }
  end

  it "does not materialize a singleton class for a result with no declared exposures" do
    result = build_axn { def call = nil }.call

    expect(singleton_materialized?(result)).to be(false)
  end

  # Positive control: without this, the example above would pass even if elision were entirely broken
  # (e.g. every facade always got a singleton) — the probe would just be measuring the wrong thing.
  it "materializes one for a result that does declare an exposure" do
    result = build_axn do
      exposes :out
      def call = expose(out: 1)
    end.call

    expect(singleton_materialized?(result)).to be(true)
  end

  it "does not materialize a singleton for the Result facade of an expects-only action" do
    result = build_axn do
      expects :name
      def call = nil
    end.call(name: "x")

    expect(singleton_materialized?(result)).to be(false)
  end

  it "does not materialize a singleton for the InternalContext facade of a bare action" do
    result = build_axn { def call = nil }.call

    internal_context = result.__action__.send(:internal_context)

    expect(singleton_materialized?(internal_context)).to be(false)
  end

  # An exposes-only action's InternalContext is NOT bare: an outbound field is implicitly allowed
  # inbound too (`_facade_fields(:inbound)` composes declared(:inbound) + declared(:outbound)), so its
  # singleton IS materialized. Positive control for the example above, on the same facade class.
  it "materializes one for the InternalContext facade of an exposes-only action" do
    result = build_axn do
      exposes :out
      def call = expose(out: 1)
    end.call

    internal_context = result.__action__.send(:internal_context)

    expect(singleton_materialized?(internal_context)).to be(true)
  end

  # The one case where a boolean predicate can still need the singleton even though the reader loop
  # found nothing to define: a boolean config assigned directly onto the class (bypassing the DSL,
  # which would otherwise refuse this pairing via `_reject_shadowed_predicate_name!`) whose field name
  # the facade itself owns. `_facade_fields` filters it out of `reader_fields`, but
  # `_boolean_predicate_fields` still sees it via the raw `external_field_configs` — proving
  # `Result#_define_boolean_predicate_reader`'s lazy `@__singleton ||= singleton_class` closes the gap
  # rather than raising `NoMethodError` on nil.
  it "still materializes one when a boolean predicate lands on a facade-owned field" do
    klass = build_axn { def call = nil }
    config = Axn::Core::Contract::FieldConfig.new(field: :exception, validations: { type: { klass: :boolean } },
                                                  reader_as: :exception)
    klass.external_field_configs = (klass.external_field_configs + [config]).freeze

    expect(klass._facade_fields(:outbound).reader_fields).to be_empty

    result = klass.call

    expect(result).to respond_to(:exception?)
    expect(singleton_materialized?(result)).to be(true)
  end
end
