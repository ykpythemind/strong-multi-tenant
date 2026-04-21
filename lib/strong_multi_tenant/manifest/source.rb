# frozen_string_literal: true

require "yaml"
require "digest"

module StrongMultiTenant
  module Manifest
    class Source
      attr_reader :roots, :direct, :skip, :parent_check, :raw_text

      ALLOWED_KEYS = %w[roots direct skip parent_check].freeze

      def self.load_file(path)
        raise ConfigurationError, "manifest not found: #{path}" unless File.exist?(path)

        text = File.read(path)
        new(text, path: path)
      end

      def initialize(text, path: nil)
        @raw_text = text
        @path = path
        parse!
      end

      def digest
        Digest::SHA256.hexdigest(raw_text)
      end

      def tables
        (roots + direct.keys + skip).uniq
      end

      def validate_against_schema!(schema_reader)
        all_tables = schema_reader.all_tables.map(&:to_s)
        missing = []

        (roots + direct.keys).each do |t|
          missing << t unless all_tables.include?(t)
        end

        unless missing.empty?
          raise ConfigurationError, "tables declared in manifest but missing from schema: #{missing.join(", ")}"
        end

        direct.each do |table, column|
          cols = schema_reader.columns(table).map(&:to_s)
          unless cols.include?(column.to_s)
            raise ConfigurationError, "direct[#{table}]: column '#{column}' not found in schema"
          end
        end

        roots.each do |t|
          pk = schema_reader.primary_key(t)
          unless pk
            raise ConfigurationError, "root '#{t}' has no primary key"
          end
        end

        # parent_check: v1 では trust_app 以外は未実装
        parent_check.each do |table, mode|
          mode = mode.to_sym
          next if mode == :trust_app
          raise NotImplementedError, "parent_check=#{mode} for '#{table}' is not implemented in v1"
        end
      end

      private

      def parse!
        data = YAML.safe_load(raw_text, permitted_classes: [Symbol]) || {}
        unless data.is_a?(Hash)
          raise ConfigurationError, "manifest must be a mapping at top level"
        end

        unknown = data.keys - ALLOWED_KEYS
        unless unknown.empty?
          raise ConfigurationError, "unknown top-level keys: #{unknown.join(", ")}"
        end

        @roots = Array(data["roots"]).map(&:to_s)
        @direct = (data["direct"] || {}).each_with_object({}) do |(k, v), h|
          raise ConfigurationError, "direct.#{k} must be a column name (String/Symbol)" unless v.is_a?(String) || v.is_a?(Symbol)
          h[k.to_s] = v.to_s
        end
        @skip = Array(data["skip"]).map(&:to_s)
        @parent_check = (data["parent_check"] || {}).each_with_object({}) do |(k, v), h|
          h[k.to_s] = v.to_s
        end

        validate_shapes!
      end

      def validate_shapes!
        unless @roots.is_a?(Array)
          raise ConfigurationError, "roots must be a sequence"
        end
        overlap = @roots & @direct.keys
        unless overlap.empty?
          raise ConfigurationError, "tables listed as both root and direct: #{overlap.join(", ")}"
        end
        overlap2 = @skip & (@roots + @direct.keys)
        unless overlap2.empty?
          raise ConfigurationError, "tables listed as both skip and root/direct: #{overlap2.join(", ")}"
        end
      end
    end
  end
end
