# frozen_string_literal: true

module StrongMultiTenant
  module Manifest
    # Wraps ActiveRecord connection so tests can swap it. Used only at build time.
    class SchemaReader
      def self.from_connection(connection = nil)
        connection ||= ::ActiveRecord::Base.connection
        new(connection)
      end

      def initialize(connection)
        @connection = connection
      end

      def all_tables
        @connection.tables
      end

      def primary_key(table)
        @connection.primary_key(table)
      end

      def columns(table)
        @connection.columns(table).map(&:name)
      end

      # foreign_keys(table) returns a list of fk definitions where `table` holds
      # the FK and points to `to_table`. We need both directions, so also expose
      # `incoming_foreign_keys`.
      def foreign_keys(table)
        @connection.foreign_keys(table).map do |fk|
          { from_table: fk.from_table.to_s, to_table: fk.to_table.to_s, column: fk.column.to_s, primary_key: fk.primary_key.to_s }
        end
      end

      def all_foreign_keys
        all_tables.flat_map { |t| foreign_keys(t) }
      end
    end

    # In-memory schema representation for tests / pure-logic building.
    class StaticSchemaReader
      def initialize(tables:, foreign_keys:, columns: {}, primary_keys: {})
        @tables = tables.map(&:to_s)
        @fks = foreign_keys.map do |fk|
          {
            from_table: fk[:from_table].to_s,
            to_table: fk[:to_table].to_s,
            column: fk[:column].to_s,
            primary_key: (fk[:primary_key] || "id").to_s
          }
        end
        @columns = columns.transform_keys(&:to_s).transform_values { |v| v.map(&:to_s) }
        @primary_keys = primary_keys.transform_keys(&:to_s).transform_values(&:to_s)
      end

      def all_tables
        @tables
      end

      def primary_key(table)
        @primary_keys[table.to_s] || "id"
      end

      def columns(table)
        @columns[table.to_s] || []
      end

      def foreign_keys(table)
        @fks.select { |fk| fk[:from_table] == table.to_s }
      end

      def all_foreign_keys
        @fks
      end
    end
  end
end
