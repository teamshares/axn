# frozen_string_literal: true

module Action
  class Configuration
    include Action::Logging
    attr_accessor :top_level_around_hook
    attr_writer :logger, :env, :on_exception, :additional_includes, :default_log_level, :default_autolog_level

    def default_log_level = @default_log_level ||= :info
    def default_autolog_level = @default_autolog_level ||= :info

    def additional_includes = @additional_includes ||= []

    def on_exception(e, action:, context: {})
      if @on_exception
        # TODO: only pass action: or context: if requested (and update documentation)
        @on_exception.call(e, action:, context:)
      else
        log("[#{action.class.name.presence || "Anonymous Action"}] Exception raised: #{e.class.name} - #{e.message}")
      end
    end

    def logger
      @logger ||= begin
        Rails.logger
      rescue NameError
        Logger.new($stdout).tap do |l|
          l.level = Logger::INFO
        end
      end
    end

    def env
      @env ||= ENV["RACK_ENV"].presence || ENV["RAILS_ENV"].presence || "development"
      ActiveSupport::StringInquirer.new(@env)
    end
  end

  class << self
    def config = @config ||= Configuration.new

    def configure
      self.config ||= Configuration.new
      yield(config) if block_given?
    end
  end
end
