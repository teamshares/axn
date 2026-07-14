# frozen_string_literal: true

RSpec.describe "PRO-2889 value-level subfield defaults" do
  before(:all) do
    Rails.application.initialize! unless Rails.application.initialized?

    unless ActiveRecord::Base.connection.table_exists?(:users)
      ActiveRecord::Base.connection.create_table :users do |t|
        t.string :name, null: false
        t.string :email, null: true
        t.timestamps
      end
    end
  end

  let(:action) do
    build_axn do
      expects :user, model: { klass: User }, allow_nil: true
      # Reading an attribute off the resolved AR record is method dispatch (PRO-2898).
      expects :email, on: :user, type: String, default: "anon@example.com", method_call: true
      exposes :nick, allow_nil: true
      def call = expose(nick: email)
    end
  end

  it "succeeds on omission: a required defaulted subfield resolves under an allow_nil: model parent" do
    result = action.call
    expect(result).to be_ok
    expect(result.nick).to eq("anon@example.com")
  end

  it "falls back when an id-resolved record has a nil attribute" do
    user = User.create!(name: "Test User", email: nil)

    result = action.call(user_id: user.id)
    expect(result).to be_ok
    expect(result.nick).to eq("anon@example.com")
  end

  it "does not mutate a caller-supplied record" do
    user = User.create!(name: "Test User", email: nil)

    result = nil
    expect { result = action.call(user:) }.not_to change { user.changed? }.from(false)
    expect(result).to be_ok
    expect(result.nick).to eq("anon@example.com")
  end
end
