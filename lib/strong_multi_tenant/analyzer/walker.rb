# frozen_string_literal: true

module StrongMultiTenant
  class Analyzer
    # Helpers to walk a pg_query AST. We operate directly on the Google::Protobuf::Message
    # objects returned by PgQuery::ParseResult#tree.
    module Walker
      module_function

      # Yield every message-type value nested under `node`, including node itself.
      def each_node(node, &block)
        return enum_for(:each_node, node) unless block_given?
        return unless node

        stack = [node]
        until stack.empty?
          current = stack.pop
          next if current.nil?

          case current
          when Google::Protobuf::MessageExts
            yield current
            current.class.descriptor.each do |field|
              val = current[field.name]
              push_children(stack, val)
            end
          when Array
            current.each { |c| push_children(stack, c) }
          end
        end
      end

      def push_children(stack, val)
        case val
        when Google::Protobuf::MessageExts
          stack << val
        when Google::Protobuf::RepeatedField, Array
          val.each { |v| push_children(stack, v) }
        end
      end

      # Collect RangeVar references from a node. Returns [{table:, schema:, alias:}]
      def collect_range_vars(node)
        refs = []
        each_node(node) do |n|
          if n.is_a?(PgQuery::RangeVar)
            refs << {
              table: n.relname,
              schema: (n.schemaname.empty? ? nil : n.schemaname),
              alias: (n.alias&.aliasname&.then { |a| a.empty? ? nil : a })
            }
          end
        end
        refs
      end

      # Shallow: collect RangeVars that appear as the top-level fromClause of a
      # given statement (not recursing into subqueries). Useful for determining
      # the "primary" target tables.
      def top_level_range_vars(from_nodes)
        refs = []
        Array(from_nodes).each do |from_node|
          next unless from_node.is_a?(Google::Protobuf::MessageExts)
          case from_node
          when PgQuery::RangeVar
            refs << from_node
          when PgQuery::JoinExpr
            refs.concat(range_vars_from_join(from_node))
          when PgQuery::Node
            inner = node_unwrap(from_node)
            refs.concat(top_level_range_vars([inner])) if inner
          end
        end
        refs
      end

      def range_vars_from_join(join)
        out = []
        [join.larg, join.rarg].each do |side|
          next unless side
          inner = node_unwrap(side)
          case inner
          when PgQuery::RangeVar
            out << inner
          when PgQuery::JoinExpr
            out.concat(range_vars_from_join(inner))
          end
        end
        out
      end

      # Node is a oneof wrapper containing exactly one child; return that child.
      def node_unwrap(node)
        return nil if node.nil?
        return node unless node.is_a?(PgQuery::Node)
        node.inner
      end
    end
  end
end
