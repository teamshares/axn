# frozen_string_literal: true

# `use :model` is built on ActiveRecord persistence, so its *behavioral* specs live in the Rails
# suite (spec_rails/.../strategies/model_spec.rb) where AR and real models are present. This suite
# is deliberately ActiveRecord-free — so it's the only place we can assert the strategy refuses to
# run without AR. Do NOT `require "active_record"` here (or anywhere else in spec/): doing so loads
# AR process-wide and would silently invalidate this guarantee.
RSpec.describe "use :model strategy without ActiveRecord" do
  it "the suite genuinely has no ActiveRecord loaded (guards the assertion below)" do
    expect(defined?(ActiveRecord)).to be_nil
  end

  it "raises NotImplementedError at declaration rather than failing confusingly at runtime" do
    expect do
      build_axn { use :model, create: :anything }
    end.to raise_error(NotImplementedError, /Model strategy requires ActiveRecord/)
  end
end
