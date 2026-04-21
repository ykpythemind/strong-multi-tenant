# strong_multi_tenant

Application-layer multi-tenant enforcement for Rails + PostgreSQL.

Every SQL statement emitted by ActiveRecord (or raw `execute`) is parsed with
[pg_query](https://github.com/pganalyze/pg_query) and checked against a
declarative policy manifest. Queries missing a tenant predicate, or touching a
table without a `WHERE` clause, raise immediately.

Unlike `acts_as_tenant`, there is no `default_scope` magic. The gem **detects
violations**; it never rewrites your SQL. This keeps behavior predictable and
makes bypass explicit.

## Design principles

- **Single source of truth — `config/strong_multi_tenant.yml`.** No model DSL.
- **No convention-based column detection.** Only explicit declarations and FK
  graph facts.
- **Derived policies are computed statically.** `rake strong_multi_tenant:build`
  BFS-walks foreign keys and writes `config/strong_multi_tenant.lock.yml`. Both
  files are checked in; CI fails on drift via `rake strong_multi_tenant:check`.
- **`NoWhere` is a first-class rule.** `SELECT/UPDATE/DELETE` without a WHERE
  always raises, even on unreachable/skipped tables. Opt out per-table with
  `StrongMultiTenant.allow_no_where(:countries) { … }`.
- **Bypass is explicit:** `StrongMultiTenant.bypass { … }` disables all checks
  within the block.

## Installation

```ruby
# Gemfile
gem "strong_multi_tenant"
```

```sh
$ bundle install
$ rails g strong_multi_tenant:install
# edit config/strong_multi_tenant.yml
$ rake strong_multi_tenant:build
```

Commit `config/strong_multi_tenant.yml` and `config/strong_multi_tenant.lock.yml`.

## Setting the tenant

```ruby
class ApplicationController < ActionController::Base
  before_action do
    StrongMultiTenant::Current.tenant_id = current_user.organization_id
  end
end
```

Or use the generated `StrongMultiTenantContext` concern.

## Manifest format

```yaml
# config/strong_multi_tenant.yml

roots:
  - organizations         # id == tenant_id

direct:
  posts: organization_id  # self has tenant column
  users: organization_id

skip:
  - active_storage_blobs  # excluded from all tenant checks (NoWhere still applies)

parent_check:
  # payment_transactions: runtime_exists   # v1.x, not yet implemented
```

The lock file (generated) mirrors this plus every table reachable via FK:

```yaml
policies:
  organizations: { mode: root, tenant_column: id }
  posts:         { mode: direct, tenant_column: organization_id }
  comments:
    mode: fk
    fk_columns: [post_id]
    parents: [posts]
    parent_check: trust_app
```

## Policy modes

| mode | where declared | required predicate | value checked? |
|---|---|---|---|
| `root` | `roots:` in yml | `id = Const\|ParamRef` | yes — must equal `Current.tenant_id` |
| `direct` | `direct:` in yml | `tenant_column = Const\|ParamRef` | yes |
| `fk` | auto (from FK graph) | one of `fk_columns = Const\|ParamRef\|IN(...)` | **no** (trust_app) |
| `hybrid` | derived table that *also* carries tenant_column | `tenant_column` OR `fk_columns` predicate | yes, only if tenant_column predicate used |

The `fk` relaxation lets Rails `has_many` associations emit
`WHERE post_id = $1` unchanged; tenant correctness is delegated to whoever
fetched `$1` in the first place.

## Block-scoped helpers

```ruby
StrongMultiTenant.with_tenant(42)      { Post.find(id) }   # temporary tenant swap
StrongMultiTenant.bypass               { Post.unscoped.find(id) }
StrongMultiTenant.allow_no_where(:countries) { Country.all }
```

## Exceptions

```
StrongMultiTenant::Violation
├── TenantViolation         # missing/mismatched tenant predicate
├── NoWhereViolation        # SELECT/UPDATE/DELETE without WHERE
├── ParentTenantMismatch    # v1.x: parent_check=runtime_exists
├── ConfigurationError      # malformed yml / missing tables
└── StaleLockError          # lock file digest mismatch
```

Each carries `#sql`, `#table`, `#reason`, `#tenant_context`, and fires a
`strong_multi_tenant.violation` `ActiveSupport::Notifications` event.

## Rake tasks

- `strong_multi_tenant:build` — regenerate the lock file.
- `strong_multi_tenant:check` — fails non-zero when the lock drifts. Run in CI.

## Trade-offs / limitations

- PostgreSQL only (via `pg_query`).
- `:fk` trust_app mode does not validate the parent row; `:runtime_exists`
  and `:rewrite` are v1.x / v2.
- JOIN-propagation of parent policy (`comments JOIN posts ON …
  WHERE posts.organization_id = $1` letting `comments` skip fk predicate)
  is a v2 feature (`:fk_via_join`). In v1 both sides need their own predicate.
- Polymorphic associations, composite FKs, and multi-root tenants are v2.

## License

MIT.
