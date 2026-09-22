# frozen_string_literal: true

RSpec.describe "_facade_fields cache" do
  it "returns the same entry object across calls for the same direction" do
    action = build_axn do
      expects :name
      exposes :greeting
    end

    expect(action._facade_fields(:inbound)).to equal(action._facade_fields(:inbound))
    expect(action._facade_fields(:outbound)).to equal(action._facade_fields(:outbound))
  end

  it "reports Axn::Core::InternalContext for :inbound and Axn::Result for :outbound" do
    action = build_axn { expects :name }

    expect(action._facade_fields(:inbound).facade_class).to eq(Axn::Core::InternalContext)
    expect(action._facade_fields(:outbound).facade_class).to eq(Axn::Result)
  end

  it "includes every outbound field in the inbound reader list, matching declared(:inbound) + declared(:outbound)" do
    action = build_axn do
      expects :name
      exposes :out
    end

    expect(action._facade_fields(:inbound).reader_fields)
      .to eq(action._declared_fields(:inbound) + action._declared_fields(:outbound))
    expect(action._facade_fields(:inbound).reader_fields).to include(:out)
  end

  # A field that is ONLY `exposes` gets no reader on the ACTION class (that generated reader is
  # `expects`-only — see `_define_field_reader`'s own comment), so this composition is not about the
  # action body reading its own exposure back; it is what lets a CALLER-supplied value under an
  # exposes-only key still surface through `internal_context`, and what the shadowing guard for names
  # like `default_error`/`default_success` reasons about (see `_reject_shadowed_exposure_name!`).
  it "resolves an exposes-only field through internal_context from provided_data, not exposed_data" do
    action = build_axn do
      exposes :out
      def call
        ic = Axn::Internal::ActionState.internal_context(self)
        expose(out: ic.send(:public_send, :out))
      end
    end

    expect(action.call(out: "surprise").out).to eq("surprise")
  end

  it "does not include the outbound-only fields in the outbound reader list" do
    action = build_axn do
      expects :name
      exposes :greeting
    end

    expect(action._facade_fields(:outbound).reader_fields).to eq([:greeting])
  end

  it "gives a subclass its own cache rather than inheriting the parent's cached entry" do
    parent = build_axn { expects :name }
    child = Class.new(parent)

    expect(child._facade_fields(:inbound)).not_to equal(parent._facade_fields(:inbound))
    expect(child._facade_fields(:inbound).reader_fields).to eq(parent._facade_fields(:inbound).reader_fields)
  end

  it "rebuilds (new entry, same content) after redeclaration" do
    action = build_axn { expects :name }
    first = action._facade_fields(:inbound)

    action.internal_field_configs = action.internal_field_configs.dup.freeze
    second = action._facade_fields(:inbound)

    expect(second).not_to equal(first)
    expect(second.reader_fields).to eq(first.reader_fields)
  end

  it "returns a frozen reader_fields Array" do
    action = build_axn { expects :name }

    expect(action._facade_fields(:inbound).reader_fields).to be_frozen
  end

  it "still raises for an invalid direction" do
    action = build_axn { expects :name }

    expect { action._facade_fields(:sideways) }.to raise_error(ArgumentError, /Invalid direction/)
  end

  # The definition-site backstop this replaces still applies: a config that skipped the DSL (assigned
  # straight onto the class) is filtered out of the reader list exactly as before, even though
  # `_declared_fields` — which is a plain map over the same config array — still reports it.
  it "omits a field the facade itself owns, for a config that skipped the DSL" do
    action = build_axn { exposes :probe }
    config = Axn::Core::Contract::FieldConfig.new(field: :_default_error, validations: {}, reader_as: :_default_error)
    action.external_field_configs = (action.external_field_configs + [config]).freeze

    # `:_default_error` is owned by InternalContext (so its inbound reader list excludes it) but not by
    # Result (so its outbound reader list, and the plain `_declared_fields` map either direction reads
    # from, still carries it) — the asymmetry `reserved_names_spec.rb`'s "facade's own backstop" relies
    # on.
    expect(action._declared_fields(:outbound)).to include(:_default_error)
    expect(action._facade_fields(:outbound).reader_fields).to include(:_default_error)
    expect(action._facade_fields(:inbound).reader_fields).not_to include(:_default_error)
  end
end
