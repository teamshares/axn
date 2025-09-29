# frozen_string_literal: true

RSpec.describe "Axn Clients" do
  # TODO: this should be done in a before(:all) block or already managed by the db/migrate directory
  before do
    # Ensure the users table exists
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS users")
    require_relative "../../../db/migrate/001_create_users"
    CreateUsers.new.change
  end

  let(:client) { Actions::Clients::User }

  let!(:user) { User.create(name: "John Doe", email: "john.doe@example.com") }

  it "function" do
    # As method
    name = client.get_name!(id: user.id)
    expect(name).to eq("John Doe")

    # As axn
    email = client.email!(id: user.id)
    expect(email).to be_ok
    expect(email.value).to eq("john.doe@example.com")
  end
end
