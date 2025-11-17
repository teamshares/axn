# frozen_string_literal: true

RSpec.describe "Axn Clients" do
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
