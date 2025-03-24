# frozen_string_literal: true

require "service_action"
require "pry-byebug"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:suite) do
    Action.configure do |c|
      # Hide default logging
      c.logger = Logger.new("/dev/null")
    end
  end
end

def build_action(&block)
  action = Class.new.send(:include, Action)
  action.class_eval(&block) if block
  action
end

def build_interactor(*modules, &block)
  interactor = Class.new.send(:include, Interactor)
  modules.each { |mod| interactor = interactor.send(:include, mod) }
  interactor.class_eval(&block) if block
  interactor
end
