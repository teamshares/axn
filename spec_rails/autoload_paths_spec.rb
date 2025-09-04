# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Axn Rails autoload paths" do
  describe "app/actions directory" do
    it "is added to autoload paths" do
      actions_path = Rails.root.join("app/actions")
      expect(Rails.application.config.autoload_paths).to include(actions_path)
    end

    it "is added to eager load paths" do
      actions_path = Rails.root.join("app/actions")
      expect(Rails.application.config.eager_load_paths).to include(actions_path)
    end

    it "only adds the path if the directory exists" do
      # The dummy app has app/actions directory, so it should be included
      actions_path = Rails.root.join("app/actions")
      expect(File.directory?(actions_path)).to be_truthy
      expect(Rails.application.config.autoload_paths).to include(actions_path)
    end
  end

  describe "Rails version compatibility" do
    it "handles Rails 7.1+ autoload path configuration" do
      if Rails.version.to_f >= 7.1
        # For Rails 7.1+, we check if add_autoload_paths_to_load_path is enabled
        # and only add to $LOAD_PATH if it's explicitly enabled
        actions_path = Rails.root.join("app/actions")

        if Rails.application.config.respond_to?(:add_autoload_paths_to_load_path) &&
           Rails.application.config.add_autoload_paths_to_load_path == true
          expect($LOAD_PATH).to include(actions_path.to_s)
        else
          # If not enabled, it shouldn't be in $LOAD_PATH
          expect($LOAD_PATH).not_to include(actions_path.to_s)
        end
      else
        # For Rails < 7.1, autoload paths were automatically added to $LOAD_PATH
        actions_path = Rails.root.join("app/actions")
        expect($LOAD_PATH).to include(actions_path.to_s)
      end
    end
  end

  describe "action autoloading" do
    it "can autoload actions from app/actions directory" do
      # Test that we can load the TestAction from the app/actions directory
      expect { TestAction }.not_to raise_error
      expect(TestAction).to be_a(Class)
    end

    it "actions can be instantiated and called" do
      result = TestAction.call
      expect(result).to be_ok
      expect(result.success).to eq("Action completed successfully")
    end
  end

  describe "duplicate path prevention" do
    it "does not add duplicate paths to autoload_paths" do
      actions_path = Rails.root.join("app/actions")
      autoload_paths = Rails.application.config.autoload_paths

      # Count occurrences of the actions path
      occurrences = autoload_paths.count(actions_path)
      expect(occurrences).to eq(1)
    end

    it "does not add duplicate paths to eager_load_paths" do
      actions_path = Rails.root.join("app/actions")
      eager_load_paths = Rails.application.config.eager_load_paths

      # Count occurrences of the actions path
      occurrences = eager_load_paths.count(actions_path)
      expect(occurrences).to eq(1)
    end
  end
end
