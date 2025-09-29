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
    expect(client.get_name!(id: user.id)).to eq("John Doe")
    expect(client.get_email!(id: user.id)).to eq("john.doe@example.com")
  end
end
