# frozen_string_literal: true

module Action
  class Configuration
    attr_accessor :top_level_around_hook
    attr_writer :logger, :env, :on_exception, :additional_includes, :default_log_level, :default_autolog_level

    def default_log_level = @default_log_level ||= :info
    def default_autolog_level = @default_autolog_level ||= :info

    def additional_includes = @additional_includes ||= []

    def on_exception(e, action:, context: {})
      msg = "Handled exception (#{e.class.name}): #{e.message}"
      msg = ("#" * 10) + " #{msg} " + ("#" * 10) unless Action.config.env.production?
      action.log(msg)

      return unless @on_exception

      # Only pass the kwargs that the given block expects
      kwargs = @on_exception.parameters.select { |type, _name| %i[key keyreq].include?(type) }.map(&:last)
      kwarg_hash = {}
      kwarg_hash[:action] = action if kwargs.include?(:action)
      kwarg_hash[:context] = context if kwargs.include?(:context)
      if kwarg_hash.any?
        @on_exception.call(e, **kwarg_hash)
      else
        @on_exception.call(e)
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
