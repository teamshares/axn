# frozen_string_literal: true

RSpec.describe "Axn Rails autoload paths" do
  before(:all) do
    # Ensure Rails is fully initialized
    Rails.application.initialize! unless Rails.application.initialized?
  end

  describe "app/actions directory" do
    it "is added to Rails autoloader" do
      actions_path = Rails.root.join("app/actions")
      # Check if the path is registered with the main autoloader
      autoloader_paths = Rails.autoloaders.main.dirs
      expect(autoloader_paths).to include(actions_path.to_s)
    end

    it "only adds the path if the directory exists" do
      # The dummy app has app/actions directory, so it should be included
      actions_path = Rails.root.join("app/actions")
      expect(File.directory?(actions_path)).to be_truthy
      autoloader_paths = Rails.autoloaders.main.dirs
      expect(autoloader_paths).to include(actions_path.to_s)
    end
  end

  describe "Rails 7.2+ autoloader configuration" do
    it "uses modern Rails autoloader API" do
      # Verify we're using the modern autoloader approach
      expect(Rails.autoloaders).to respond_to(:main)
      expect(Rails.autoloaders.main).to respond_to(:dirs)
    end
  end

  describe "action autoloading configuration" do
    it "verifies namespace configuration is set" do
      # Verify the namespace configuration is properly set
      expect(Axn.config.rails.app_actions_autoload_namespace).to eq(:Actions)
    end

    # Membership in `dirs` (above) is true whether the engine namespaced the directory or Rails
    # pushed it at the root namespace on its own, so it cannot tell the two apart. The root's
    # namespace can, and a constant that only autoloading can supply proves it took effect.
    it "maps the directory to the configured namespace, not the root" do
      actions_path = Rails.root.join("app/actions").to_s
      expect(Rails.autoloaders.main.send(:roots)[actions_path]).to eq(Actions)
    end

    it "resolves a constant under the configured namespace" do
      expect(Actions::Clients::User.name).to eq("Actions::Clients::User")
    end
  end

  describe "duplicate path prevention" do
    it "does not add duplicate paths to autoloader" do
      actions_path = Rails.root.join("app/actions")
      autoloader_paths = Rails.autoloaders.main.dirs

      # Count occurrences of the actions path
      occurrences = autoloader_paths.count(actions_path.to_s)
      expect(occurrences).to eq(1)
    end
  end
end
