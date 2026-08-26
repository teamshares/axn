# frozen_string_literal: true

require "axn/testing/spec_helpers"

# `Kernel#Array` dispatches `to_ary`/`to_a` on whatever it is handed — and a declared `type:`/`klass:` token is
# always the CALLER's own Class or Module. Every site in `contract.rb` and `schema.rb` that read a raw declared
# token through `Array(...)` therefore ran the caller's own `to_ary` at declaration, and again on every
# reflection call — which reflection may never do (the standing rule is that it is side-effect-free), and which
# could silently substitute the declared type in the emitted schema. A token whose `to_ary` raised took the
# declaration down with the CALLER's own exception instead of axn's.
#
# Fixed by routing every such site through `Internal::ShapeGraph.type_tokens` (`_declared_type_tokens` in
# contract.rb) instead of `Kernel#Array`, which classifies with `case`/`when ::Array` and so never asks the
# token for `to_ary`/`to_a`.
RSpec.describe "declared type tokens are read without dispatching to_ary" do
  def hostile_token(dispatched, returns: [String])
    Class.new do
      define_singleton_method(:to_ary) do
        dispatched << :to_ary
        returns
      end
    end
  end

  def raising_token(dispatched)
    Class.new do
      define_singleton_method(:to_ary) do
        dispatched << :to_ary
        raise "caller code ran"
      end
    end
  end

  # Runs the block, tolerating any declaration/runtime error the hostile token's shape may legitimately
  # trigger for unrelated reasons (e.g. "not a coercible type") — the one thing under test is whether
  # `to_ary` ran, not whether the declaration succeeds.
  def expect_no_dispatch(dispatched)
    yield
  rescue StandardError
    nil
  ensure
    expect(dispatched).to eq([])
  end

  describe "the ticket's own two confirmed sites" do
    it "does not let a hostile to_ary substitute the emitted schema type (schema.rb json_type_for)" do
      dispatched = []
      # An honest anonymous class of the same shape is the control: since neither class has a JSON Schema
      # mapping of its own, both should reflect identically — proving the decoy's `[::Integer]` (a type
      # that WOULD reflect differently) never influenced the emitted node.
      honest = Class.new
      hostile = hostile_token(dispatched, returns: [Integer])

      honest_schema = build_axn { expects :f, type: honest, absence: true, optional: true }.input_schema.dig(:properties, :f)
      hostile_schema = build_axn { expects :f, type: hostile, absence: true, optional: true }.input_schema.dig(:properties, :f)

      expect(dispatched).to eq([])
      expect(hostile_schema).to eq(honest_schema)
    end

    it "does not run a hostile to_ary while deciding whether a field is :boolean (contract.rb boolean?)" do
      dispatched = []
      token = hostile_token(dispatched, returns: [:boolean])

      expect { build_axn { expects :f, type: token } }.not_to raise_error
      expect(dispatched).to eq([])
    end

    it "does not let a to_ary that raises take the declaration down" do
      dispatched = []
      token = raising_token(dispatched)

      expect { build_axn { expects :f, type: token } }.not_to raise_error
      expect(dispatched).to eq([])
    end
  end

  # Every other newly-fixed site (PRO-3233), exercised through the DSL surface that reaches it — declared,
  # reflected on both input and output, and called, so a dispatch anywhere in that path is caught.
  describe "every other fixed call site" do
    it "the allow_empty: guard reads the declared type without dispatching" do
      dispatched = []
      token = hostile_token(dispatched)

      expect_no_dispatch(dispatched) { build_axn { expects :f, type: token, allow_empty: true } }
    end

    it "default presence + emptiness-axis reconciliation read the declared type without dispatching" do
      dispatched = []
      token = hostile_token(dispatched)

      expect_no_dispatch(dispatched) do
        k = build_axn do
          expects :f, type: token, allow_empty: false, length: { minimum: 1 }
          def call = nil
        end
        k.call(f: nil)
      end
    end

    it "an of: bag's klass: axis is read without dispatching, at declaration and reflection" do
      dispatched = []
      token = hostile_token(dispatched)

      expect_no_dispatch(dispatched) do
        k = build_axn { expects :f, type: Array, of: { klass: token, message: "bad element" } }
        k.input_schema
        k.output_schema
      end
    end

    it "a map's values: axis is read without dispatching, at declaration and reflection" do
      dispatched = []
      token = hostile_token(dispatched)

      expect_no_dispatch(dispatched) do
        k = build_axn { expects :f, type: Hash, of: { values: token } }
        k.input_schema
        k.output_schema
      end
    end

    it "shape compatibility is read without dispatching" do
      dispatched = []
      token = hostile_token(dispatched, returns: [Hash])

      expect_no_dispatch(dispatched) do
        build_axn { expects(:f, type: token) { field :v, type: String } }
      end
    end

    it "a distributing shape's element container is read without dispatching" do
      dispatched = []
      token = hostile_token(dispatched)

      expect_no_dispatch(dispatched) do
        build_axn { expects(:f, type: Array, of: token) { field :v, type: String } }
      end
    end

    it "coerce: sugar reads the declared type without dispatching" do
      dispatched = []
      token = hostile_token(dispatched, returns: [Date])

      expect_no_dispatch(dispatched) { build_axn { expects :f, coerce: token } }
    end
  end
end
