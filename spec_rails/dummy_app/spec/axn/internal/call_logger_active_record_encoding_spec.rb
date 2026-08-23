# frozen_string_literal: true

# The call logger names an ActiveRecord record as `<Class#id>`, built from `data.to_param`. A record
# whose `to_param` returns non-ASCII bytes in a foreign encoding (a Latin-1 slug column, for instance)
# used to reach the composing Array/Hash `.join` unrendered, so a SECOND such record elsewhere in the
# same logged structure disagreeing on encoding raised Encoding::CompatibilityError out of the log line
# itself — swallowed by the surrounding best_effort, losing the line entirely (PRO-3203). Needs a real
# ActiveRecord::Base descendant, so it lives here rather than in the non-Rails suite.
RSpec.describe "auto-log rendering of ActiveRecord records with foreign-encoded to_param" do
  let(:log_messages) { [] }

  def foreign_record(encoded_param)
    User.new(name: "x").tap { |record| record.define_singleton_method(:to_param) { encoded_param } }
  end

  def action_expecting_items
    action = build_axn do
      expects :items
      exposes :v
    end
    action.define_method(:call) { expose(v: 1) }
    allow(Axn.config.logger).to receive(:info) { |message| log_messages << message }
    allow(Axn.config.logger).to receive(:warn)
    action
  end

  it "renders both records rather than losing the line to a swallowed encoding failure" do
    latin1 = foreign_record("caf\xE9".dup.force_encoding("ISO-8859-1"))
    utf8 = foreign_record("café")

    expect(action_expecting_items.call(items: [latin1, utf8])).to be_ok
    expect(log_messages.first).to include("About to execute").and include("café")
    expect(log_messages.first).not_to include("IGNORING EXCEPTION")
  end
end
