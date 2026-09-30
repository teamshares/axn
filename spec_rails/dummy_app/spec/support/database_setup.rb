# frozen_string_literal: true

# Set up the test database schema by running migrations
# For :memory: databases, we need to manually run migrations
RSpec.configure do |config|
  config.before(:suite) do
    ActiveRecord::Base.connection.execute("PRAGMA foreign_keys = OFF")

    # Ensure schema_migrations table exists
    unless ActiveRecord::Base.connection.table_exists?("schema_migrations")
      ActiveRecord::Base.connection.create_table("schema_migrations", id: false) do |t|
        t.string "version", null: false
      end
      ActiveRecord::Base.connection.add_index("schema_migrations", "version", unique: true)
    end

    # Load and run all migrations
    migration_files = Dir[Rails.root.join("db/migrate/*.rb")]
    migration_files.each do |file|
      version = File.basename(file).split("_").first

      # Skip if already migrated
      result = ActiveRecord::Base.connection.select_values(
        "SELECT version FROM schema_migrations WHERE version = '#{version}'",
      )
      next if result.include?(version)

      # Load and run the migration
      load file
      migration_class_name = File.basename(file, ".rb").split("_").drop(1).map(&:camelize).join
      migration_class = migration_class_name.constantize
      migration_class.new.change

      # Record migration
      ActiveRecord::Base.connection.execute(
        "INSERT INTO schema_migrations (version) VALUES ('#{version}')",
      )
    end

    ActiveRecord::Base.connection.execute("PRAGMA foreign_keys = ON")
  end

  # Every example starts from empty tables. The `:memory:` database lives for the whole process, and the suite
  # deliberately has no enclosing test transaction: specs exercise the real commit and rollback of
  # `use :transaction` and its after-commit hooks, which an outer transaction would absorb (the action's
  # transaction would join it, so nothing commits and a raise no longer rolls back what the spec measures). Rows
  # those examples commit are therefore deleted here instead.
  config.before do
    connection = ActiveRecord::Base.connection
    tables = connection.tables - %w[schema_migrations ar_internal_metadata]
    connection.disable_referential_integrity do
      tables.each { |table| connection.execute("DELETE FROM #{connection.quote_table_name(table)}") }
    end
  end
end
