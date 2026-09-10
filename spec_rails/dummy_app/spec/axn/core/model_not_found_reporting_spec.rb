# frozen_string_literal: true

# The Rails half of PRO-3369: `ActiveRecord::RecordNotFound` is the DEFAULT not-found class, so
# `expects :user, model: true` — the spelling every app writes — is the one that has to stop paging for an
# ordinary bad id. The non-Rails lane (spec/axn/core/model_not_found_spec.rb) pins the same rule over POROs
# and covers `not_found_on:` and its declaration guards.
#
# This file is a runtime-truth MATRIX rather than a set of behavioral assertions: what went wrong in
# production was a report COUNT, and the whole fix is about which of two callers sees one. So every example
# asserts the reported classes, not merely that the action failed.
RSpec.describe "a model: field whose record does not exist" do
  let(:reported) { [] }

  around do |example|
    Axn.config.on_exception = ->(exception, action:, context:) { reported << [exception, context] } # rubocop:disable Lint/UnusedBlockArgument
    example.run
  ensure
    Axn.config.on_exception = nil
  end

  let(:missing_id) { 999_999 }

  let(:default_finder) { build_axn { expects :user, model: true } }
  let(:nil_finder) { build_axn { expects :user, model: { finder: :find_by_id } } }

  def reported_classes = reported.map { |(exception, _ctx)| exception.class }

  def tool_call(klass, **inputs)
    Axn::Tools::Invoker.new(adapter: :mcp, user_facing_input_errors: true).call(klass, inputs)
  end

  # The heart of it. `:find` raises RecordNotFound and `:find_by_id` returns nil for the identical outcome,
  # and until this change only the raising spelling reported — an accident of which finder the author picked,
  # never a decision anyone made.
  describe "the two spellings of a miss now agree" do
    it "reports nothing on a tool call, whichever finder is declared" do
      tool_call(default_finder, user_id: missing_id)
      tool_call(nil_finder, user_id: missing_id)

      expect(reported).to be_empty
    end

    it "reports exactly one contract violation on a direct call, whichever finder is declared" do
      default_finder.call(user_id: missing_id)
      nil_finder.call(user_id: missing_id)

      expect(reported_classes).to eq([Axn::InboundValidationError, Axn::InboundValidationError])
    end

    it "says the same thing to the caller" do
      expect(tool_call(default_finder, user_id: missing_id).error).to eq("User not found")
      expect(tool_call(nil_finder, user_id: missing_id).error).to eq("User not found")
    end
  end

  # The dangling-FK coverage the old ignored-exception report provided is NOT lost for an ordinary call: the
  # contract violation still pages. What changes is that it pages once, as the violation it is, rather than
  # twice with a `RecordNotFound` whose per-id message fragmented one bug into a fault per id.
  it "still pages a direct caller, and no longer names ActiveRecord::RecordNotFound" do
    default_finder.call(user_id: missing_id)

    expect(reported_classes).to eq([Axn::InboundValidationError])
    expect(reported_classes).not_to include(ActiveRecord::RecordNotFound)
  end

  it "reports nothing at all when the record resolves" do
    user = User.create!(name: "Test User")

    expect(default_finder.call(user_id: user.id)).to be_ok
    expect(reported).to be_empty
  end

  # An `optional:` model field declares that "no record" is an acceptable outcome, so a miss is not a
  # violation at all — the run succeeds. It used to succeed AND page, the only shape in the matrix where a
  # green result produced a Honeybadger fault. Its `:find_by_id` twin has always been silent here.
  it "no longer pages on a successful run when the field is optional" do
    action = build_axn { expects :user, model: true, allow_nil: true }

    expect(action.call(user_id: missing_id)).to be_ok
    expect(reported).to be_empty
  end

  describe "the message" do
    it "names the miss rather than degrading to a blank field" do
      expect(default_finder.call(user_id: missing_id).exception.message).to eq("User not found")
    end

    it "still reads as blank when no id was supplied, which is a different mistake" do
      expect(default_finder.call.exception.message).to eq("User can't be blank")
    end

    # The doubled "User is not a User and User can't be blank" was two validators reporting one nil: the
    # model validator delegating nil to the type check, and the presence check.
    it "is a single error, not a type error paired with a presence error" do
      expect(default_finder.call(user_id: missing_id).exception.errors.count).to eq(1)
    end

    # The id is deliberately absent: this string reaches an external caller verbatim under
    # `user_facing_input_errors:`, and a custom finder's token can be a credential.
    it "does not interpolate the lookup token" do
      expect(tool_call(default_finder, user_id: missing_id).error).not_to include(missing_id.to_s)
    end
  end

  describe "a finder that is broken rather than empty-handed" do
    before { allow(Axn.config.logger).to receive(:warn) }

    it "still reports, even on a tool call — a dead lookup is an app bug" do
      allow(User).to receive(:find).and_raise(ActiveRecord::StatementInvalid, "connection lost")

      tool_call(default_finder, user_id: missing_id)

      expect(reported_classes).to eq([ActiveRecord::StatementInvalid])
    end
  end

  describe "a nested model: subfield" do
    subject(:action) do
      build_axn do
        expects :data
        expects :user, model: { klass: User }, on: :data
      end
    end

    it "follows the same rule at depth" do
      result = tool_call(action, data: { user_id: missing_id })

      expect(result).not_to be_ok
      expect(result.error).to eq("User not found")
      expect(reported).to be_empty
    end

    it "reads as blank at depth when no id was supplied" do
      # A non-empty parent, so the leaf's own verdict is what surfaces: an EMPTY `data` fails its own
      # presence check first and strands everything below it.
      expect(action.call(data: { other: 1 }).exception.message).to eq("User can't be blank")
    end
  end
end
