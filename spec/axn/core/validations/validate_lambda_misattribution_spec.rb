# frozen_string_literal: true

RSpec.describe "a validate: lambda that raises an exception axn cannot describe" do
  # `validate_validator` reports the lambda's exception through `best_effort { raise e }`. When the report
  # itself raised, the escape landed in the executor one layer out and REPLACED the settled outcome: the
  # caller's `Axn::InboundValidationError` was destroyed, no per-field message was ever added, and
  # `result.exception` named a stack with nothing to do with the failure. Reachable with three lines of
  # ordinary DSL, and in every environment for the hostile-`#message` shape.
  def action_validating_with(&raiser)
    build_axn do
      expects :n, validate: ->(_value) { raiser.call }
    end
  end

  let(:hostile_message) do
    Class.new(StandardError) do
      def message = raise(NotImplementedError, "message explodes")
    end
  end

  # The per-field message is asserted alongside the exception class, and on the EXCEPTION rather than on
  # `result.error` — the latter is the generic user-facing wording ("Something went wrong"), which cannot
  # tell a real validation failure from a lost one. `validate_each` builds this text from the lambda's
  # exception a second time, after the guard has reported it, so without a guarded read there the field
  # error is where the escape happens even once `best_effort` itself is airtight.
  it "settles on the validation error for an ordinary raise (control)" do
    result = action_validating_with { raise ArgumentError, "ordinary" }.call(n: 1)

    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
    expect(result.exception.message).to match(/failed validation: ordinary/)
  end

  it "settles on the validation error when the lambda's exception has a raising #message" do
    result = action_validating_with { raise hostile_message }.call(n: 1)

    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
    expect(result.exception.message).to match(/failed validation/)
  end

  it "settles on the validation error when the lambda's exception holds unrenderable message bytes" do
    result = action_validating_with { raise ArgumentError, "bad\xFF".dup.force_encoding("ASCII-8BIT") }.call(n: 1)

    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
    # Escaped rather than scrubbed: a message naming an offender must not quietly alter what it names.
    expect(result.exception.message).to match(/failed validation: "bad\\xFF"/)
  end
end

# `resolve_default`/`resolve_preprocess` (Axn::Internal::FieldConfig) wrap a raising default:/preprocess:
# proc as a typed ContractViolation, building that wrapper's own message from the ORIGINAL exception's
# `#message` (Axn::Internal::ContractErrorHandling and the message: procs in field_config.rb). Neither
# read is guarded: it runs directly inside `with_contract_error_handling`'s own `rescue StandardError`
# clause, so a raise there is not caught locally, and it escapes as the caller's `default:`/`preprocess:`
# exception is wrapping — replacing the typed DefaultAssignmentError/PreprocessingError (and its
# "Error applying default for field 'x': ..." framing) with the raw, untyped exception instead.
RSpec.describe "a default:/preprocess: proc whose own raised exception axn cannot describe" do
  # This is the brief's literal Step 1 spec, and it only proves `result.error` doesn't raise — NOT that
  # the field-level detail survives. With no custom `error:` declared, `result.error` resolves via the
  # generic fallback ("Something went wrong") regardless of whether the typed DefaultAssignmentError
  # below was preserved or destroyed, so it can't be strengthened at this level: the fallback text is
  # identical either way. The two examples below (asserting on `result.exception`'s class) are what
  # actually pin the fix; this one is kept to match the literal brief and is deliberately named for
  # what it checks rather than for the typing loss it can't see.
  it "does not let result.error raise for an unrenderable default: proc failure (weak on its own)" do
    action = build_axn do
      expects :n
      exposes :thing, default: -> { raise ArgumentError, "bad\xFF".dup.force_encoding("ASCII-8BIT") }
    end

    result = action.call(n: 1)

    expect { result.error }.not_to raise_error
  end

  let(:hostile_message) do
    Class.new(StandardError) do
      def message = raise(NotImplementedError, "message explodes")
    end
  end

  it "keeps the DefaultAssignmentError typing when the default: proc's own error has a raising #message" do
    hostile = hostile_message
    action = build_axn do
      expects :n
      exposes :thing, default: -> { raise hostile, "inner" }
    end

    result = action.call(n: 1)

    expect(result.exception).to be_a(Axn::ContractViolation::DefaultAssignmentError)
  end

  it "keeps the PreprocessingError typing when the preprocess: proc's own error has a raising #message" do
    hostile = hostile_message
    action = build_axn do
      expects :n, preprocess: ->(_value) { raise hostile, "inner" }
    end

    result = action.call(n: 1)

    expect(result.exception).to be_a(Axn::ContractViolation::PreprocessingError)
  end
end
