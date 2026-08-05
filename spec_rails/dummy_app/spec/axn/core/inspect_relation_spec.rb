# frozen_string_literal: true

# `ContextFacadeInspector` has a branch whose whole purpose is to keep an exposed ActiveRecord relation from
# being LOADED just to build a debug string. It tested `instance_of?(::ActiveRecord::Relation)`, which is false
# for every relation an app can produce — a real one's class is the model's own `User::ActiveRecord_Relation`,
# and only a bare `::ActiveRecord::Relation.allocate` satisfies `instance_of?`. So the branch never fired, the
# relation fell through to `inspect`, and it hydrated exactly the records the guard exists to avoid loading.
#
# Only a real Rails boot can tell the difference, which is why this lives here: in the non-Rails suite
# `defined?(::ActiveRecord::Relation)` is false and the branch is unreachable for a different reason.
RSpec.describe "Axn::Core::ContextFacadeInspector ActiveRecord relation display" do
  before { User.delete_all }

  def action_exposing(relation)
    build_axn do
      exposes :users, allow_blank: true
      define_method(:call) { expose(:users, relation) }
    end
  end

  it "names the relation's own class instead of rendering its records" do
    User.create!(name: "Ada")
    User.create!(name: "Grace")

    inspected = action_exposing(User.all).call.inspect

    expect(inspected).to eq("#<Axn::Result [OK] users: User::ActiveRecord_Relation>")
    expect(inspected).not_to include("Ada")
    expect(inspected).not_to include("Grace")
  end

  # The point of the branch, stated as the thing it actually buys: `inspect` must not be what triggers the
  # query.
  #
  # Measured by counting SELECTs, NOT by `relation.loaded?` — which is a vacuous assertion here and passes
  # against the broken code too. ActiveRecord's `Relation#inspect` reads through `annotate("loading for
  # inspect")`, which builds a SEPARATE relation, so the query runs while the original object is never
  # marked loaded.
  def selects_during
    selects = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      selects << payload[:sql] if payload[:sql].to_s.start_with?("SELECT")
    end
    yield
    selects
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  it "runs no query to build the inspect string" do
    User.create!(name: "Ada")
    result = action_exposing(User.all).call

    expect(selects_during { result.inspect }).to be_empty
  end

  # The auto-log line renders the same exposure through `Internal::CallLogger`, which is a DIFFERENT renderer
  # and ran on every call rather than only when something asked for an inspect — so a relation exposure cost a
  # SELECT per call purely to build a log line.
  it "runs no query to build the auto-log line either" do
    User.create!(name: "Ada")
    klass = action_exposing(User.all)

    expect(selects_during { klass.call }).to be_empty
  end

  # `Identity.class_of(relation).name` answers "ActiveRecord::Relation" — ActiveRecord overrides `Class#name`
  # on the generated relation class — so the displayed name has to come from `Module#to_s`, which is what
  # `Rendering.class_name` reads. Pinned because the two spellings look interchangeable at the call site.
  it "reads the name that ActiveRecord's own Class#name override does not answer" do
    relation = User.all

    expect(Axn::Internal::Identity.class_of(relation).name).to eq("ActiveRecord::Relation")
    expect(Axn::Internal::Rendering.class_name(relation)).to eq("User::ActiveRecord_Relation")
  end

  # A relation of a DIFFERENT model must not read as the first one's — i.e. the displayed name is derived per
  # value rather than being a constant string that happened to match.
  it "names each model's relation as its own" do
    expect(action_exposing(Profile.all).call.inspect)
      .to eq("#<Axn::Result [OK] users: Profile::ActiveRecord_Relation>")
  end
end
