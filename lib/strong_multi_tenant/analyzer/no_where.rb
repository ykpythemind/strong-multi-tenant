# frozen_string_literal: true

module StrongMultiTenant
  class Analyzer
    # NoWhere detection: flags SELECT / UPDATE / DELETE without a WHERE clause
    # (or with a trivially-true WHERE).
    module NoWhere
      module_function

      def trivially_true?(where_node)
        return true if where_node.nil?
        inner = where_node.is_a?(PgQuery::Node) ? Walker.node_unwrap(where_node) : where_node
        case inner
        when PgQuery::A_Const
          v = Predicate.a_const_value(inner)
          return true if v == true
          return true if v.is_a?(Integer) && v != 0
          false
        when PgQuery::A_Expr
          # 1=1 / 'x'='x' shapes. Be conservative: call trivial only if both sides
          # are const and equal with kind :AEXPR_OP =.
          if inner.kind == :AEXPR_OP && inner.name.map { |n| Predicate.str_val(n) }.join == "="
            l = Predicate.classify_side(inner.lexpr)
            r = Predicate.classify_side(inner.rexpr)
            return true if l && r && l[:type] == :const && r[:type] == :const && l[:value] == r[:value]
          end
          false
        else
          false
        end
      end
    end
  end
end
