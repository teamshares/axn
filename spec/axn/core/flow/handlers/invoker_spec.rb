# frozen_string_literal: true

require "spec_helper"

# `Invoker.call_symbol_handler` warns and returns nil rather than raising when a declared symbol
# handler names a method the action doesn't respond to — a defensive fallback for a handler symbol
# that stopped resolving (a typo, a renamed method) after being declared.
RSpec.describe "invoking a symbol handler that does not resolve" do
  let(:invoker) { Axn::Core::Flow::Handlers::Invoker }

  it "warns and settles cleanly rather than raising when the symbol does not resolve" do
    action = build_axn do
      on_error :no_such_method
      def call = fail!("boom")
    end

    result = nil
    expect { result = action.call }.not_to raise_error
    expect(result).to be_a(Axn::Result)
  end

  # A diagnostic may not decide the HANDLER's verdict. Called directly (bypassing `Invoker.call`'s
  # own outer rescue) so the guard's OWN contract is what's under test: unguarded, this raise
  # propagated out of `call_symbol_handler` itself, where `Invoker.call`'s transitive catch reports
  # the LOGGER's exception as though the handler had raised and substitutes the swallow sentinel for
  # what should simply have been nil.
  it "still returns nil, unguarded by any caller, when the invalid-symbol breadcrumb's logger raises" do
    allow(Axn.config.logger).to receive(:warn).and_raise(IOError, "closed stream")
    action = build_axn { def call = nil }.send(:new)

    result = nil
    expect do
      result = invoker.send(:call_symbol_handler, action:, symbol: :no_such_method)
    end.not_to raise_error
    expect(result).to be_nil
  end
end
