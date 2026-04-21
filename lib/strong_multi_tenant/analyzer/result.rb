# frozen_string_literal: true

module StrongMultiTenant
  class Analyzer
    Result = Data.define(:status, :kind, :table, :reason, :message) do
      def ok?
        status == :ok
      end

      def self.ok
        new(status: :ok, kind: nil, table: nil, reason: nil, message: nil)
      end

      def self.violation(kind:, table: nil, reason: nil, message: nil)
        new(status: :violation, kind: kind, table: table, reason: reason, message: message)
      end
    end
  end
end
