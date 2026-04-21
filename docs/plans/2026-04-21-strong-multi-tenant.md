# strong_multi_tenant: Rails アプリケーション層 RLS gem 設計プラン (統合版)

## Context

Rails アプリケーションで「誰がどの行を見れるか」を PostgreSQL RLS に頼らず **アプリ層のガード** で担保したい。既存の `acts_as_tenant` は `default_scope` + モデル DSL でスコープ付与するが、生 SQL・JOIN・`find_by_sql` をすり抜けるし、ポリシー違反を **強制的に raise** する仕組みではない。

本 gem は次の立て付けで差別化する:

- **YAML マニフェスト単一ソース** — `config/strong_multi_tenant.yml` に **roots / direct / skip / parent_check** を宣言。モデルクラスへの DSL 追加は一切不要（情報源の二重化を避ける）。
- **規約ベース廃止** — 列名推測（`organization_id` > `tenant_id` > `account_id`）はしない。誤検知/漏れの温床なので「宣言」と「FK グラフという事実」だけを使う。
- **FK 静的解析で派生を自動展開** — `rake strong_multi_tenant:build` が schema の外部キーを BFS で辿り、`config/strong_multi_tenant.lock.yml` に派生テーブルの policy を確定。schema.rb と同じく lock は checked-in、CI で drift を検知。
- **SQL 発行を AST で検査** — `pg_query` で parse し、対象テーブルに応じた述語が WHERE にあるかを毎クエリ検証。違反なら raise。
- **NoWhere 禁止をデフォルト装備** — policy の有無に関わらず、WHERE 無しの SELECT/UPDATE/DELETE は `NoWhereViolation`。回避は `StrongMultiTenant.allow_no_where(:table) { ... }` で明示。
- **CurrentAttributes で文脈管理** — Fiber-safe に現在のテナント / bypass / allow_no_where を保持。
- **書き換えはしない（検出のみ）** — 挙動予測性を最優先。バイパスは `StrongMultiTenant.bypass { ... }` で明示。
- **親 ID の正当性は v1 では trust_app** — 派生テーブルの FK 先が本当に Current テナントの行か、という値検査は v1 ではアプリ層責務。拡張ポイント (`parent_check`) を設計段階で切り、v1.x で `:runtime_exists`、v2 で `:rewrite` を追加できる形にしておく。

対象 DB は **PostgreSQL 専用 (pg_query 6.x / libpg_query 17)**。MySQL は Adapter 境界だけ切って将来対応。

## 全体アーキテクチャ

```
┌──────────────────────────────┐
│ config/strong_multi_tenant.yml       │ ← 手書き (roots / direct / skip / parent_check)
└──────────────────────────────┘
              │ rake strong_multi_tenant:build
              ▼
┌──────────────────────────────┐
│ config/strong_multi_tenant.lock.yml  │ ← 生成物 (policies / skipped, checked-in)
└──────────────────────────────┘
              │ boot 時ロード
              ▼
┌──────────────────────────────┐     ┌───────────────────────────┐
│ StrongMultiTenant::Registry            │◀────│ StrongMultiTenant::Current            │
│  table → Policy              │     │  .tenant_id, .bypass,     │
│  (lock ファイルからのみ構築) │     │  .allow_no_where_tables   │
└──────────────────────────────┘     └───────────────────────────┘
              │
              ▼
┌──────────────────────────────┐
│ StrongMultiTenant::Analyzer            │ ← pg_query で parse → 検査
│  analyze(sql) -> :ok | Violation
│    ├ テナント述語検査 (mode別)
│    └ NoWhere 検査 (横断)
└──────────────────────────────┘
              ▲
              │ prepend
┌──────────────────────────────┐
│ PostgreSQLAdapter            │
│  internal_exec_query 等      │
└──────────────────────────────┘
```

## 主要コンポーネント

### 1. `StrongMultiTenant::Current` (lib/strong_multi_tenant/current.rb)

- `ActiveSupport::CurrentAttributes` 派生。
- 属性: `tenant_id`, `bypass` (bool), `allow_no_where_tables` (Set<Symbol>)。
- `ApplicationController` で `before_action { StrongMultiTenant::Current.tenant_id = current_user.organization_id }` が想定セットアップ。

### 2. `StrongMultiTenant::Policy` (lib/strong_multi_tenant/policy.rb)

値オブジェクト:

```ruby
Policy = Data.define(
  :table_name,
  :mode,            # :root | :direct | :fk | :hybrid
  :tenant_column,   # :direct / :hybrid / :root のみ
  :fk_columns,      # :fk / :hybrid のみ (Array<Symbol>)
  :parents,         # :fk / :hybrid のみ (Array<Symbol>)
  :parent_check,    # :trust_app (v1 既定) | :runtime_exists (v1.x) | :rewrite (v2)
)
```

mode の意味:

| mode | 由来 | 要求される述語 | 値検査 |
|---|---|---|---|
| `:root` | yml `roots` (例: organizations) | `id = Const \| ParamRef` | Current.tenant_id と一致 |
| `:direct` | yml `direct` (例: posts: organization_id) | `tenant_column = Const \| ParamRef` | Current.tenant_id と一致 |
| `:fk` | lock に自動展開 (例: comments→posts) | `fk_columns` のいずれかが 定数/bind/IN で束縛 | **v1 はしない** (`parent_check: :trust_app`) |
| `:hybrid` | 派生 + 非正規化 tenant_column あり | tenant_column 述語優先、無ければ fk_columns 束縛 | tenant_column 側のみ値検査 |

`:fk` の値検査省略は、Rails の `has_many` が発行する `WHERE post_id = $1` を通すための意図的な妥協。親 ID の正当性はアプリ層（先行する Post クエリが :direct で検査済み）に委ねる。README でトレードオフを明記。

### 3. `StrongMultiTenant::Registry` (lib/strong_multi_tenant/registry.rb)

- `lookup(table_name) -> Policy | nil`。
- Rails ブート時に **lock ファイルのみ** から構築（`ActiveRecord::Base.descendants` の走査はしない、規約検出も無い）。
- ロード時に policies / skipped を Hash<Symbol, Policy> に展開。

### 4. `StrongMultiTenant::Manifest` (lib/strong_multi_tenant/manifest.rb)

yml + lock のローダ。サブモジュール:

- `Manifest::Source` — `config/strong_multi_tenant.yml` をパース + バリデーション。全エントリのテーブルがスキーマに存在するかを検証。
- `Manifest::Builder` — source + `connection.foreign_keys` から lock を構築。
  - root を起点に BFS で FK を逆引き、到達テーブルを `:fk` で登録。
  - 派生テーブルに非正規化 tenant_column（root/direct と同名の列）があれば `:hybrid` に昇格。
  - `skip` 指定は `skipped.explicit` へ。届かなかったテーブルは `skipped.unreachable` へ。
  - 循環 FK（self-reference / 相互参照）は visited セットで停止。
- `Manifest::SchemaReader` — `connection.foreign_keys` / `connection.columns` のラッパ。テスト時差し替え可。

### 5. `StrongMultiTenant::Analyzer` (lib/strong_multi_tenant/analyzer.rb) ← **コア**

- 入力: 生 SQL 文字列。
- 出力: `Result(:ok)` / `Result(:violation, kind:, table:, reason:)`。
- 流れ:
  1. `PgQuery.fingerprint(sql)` で LRU キャッシュ引き。
  2. `PgQuery.parse(sql)` で AST 取得。
  3. スキップ対象を早期 return:
     - DDL (`CreateStmt` 等)、`TransactionStmt`、`VariableSetStmt`、`ExplainStmt`、AR の `SCHEMA` クエリ。
  4. `Current.bypass?` なら即 `:ok`。
  5. **テナント述語検査** — 参照される全 `RangeVar` を列挙（CTE, subquery, JOIN, UNION 含む）し、Registry から policy を引き:
     - `:root` / `:direct` → `<table>.<tenant_column> = <Const|ParamRef>`。bind 値と Current.tenant_id を突合。
     - `:fk` → `fk_columns` のいずれかが `= Const | ParamRef | IN (...)` で束縛されているか。値は検査しない。
     - `:hybrid` → tenant_column 述語（値一致）を先に試し、無ければ `:fk` と同判定。
     - policy 無し → テナント検査はスキップ。
     - CTE / サブクエリはそれ自体を 1 スコープとして検査（外側の WHERE では救済しない）。
  6. **NoWhere 検査** — SELECT/UPDATE/DELETE の主対象テーブルについて:
     - WHERE 無し、あるいは `WHERE TRUE` / `WHERE 1=1` のような自明真のみなら、`Current.allow_no_where_tables` に含まれない限り `NoWhereViolation` raise。
     - INSERT は対象外。
     - policy 有無に関わらず検査する（unreachable / skipped も含む）。
  7. **INSERT** は VALUES 節の `tenant_column` に `Current.tenant_id` と同値が入っているかを検査（`:direct` / `:root` / `:hybrid` のみ）。

キャッシュは SQL fingerprint → 構造的検査結果。`Current.tenant_id` との値比較はキャッシュ後に再適用。

### 6. `StrongMultiTenant::AdapterGuard` (lib/strong_multi_tenant/adapter_guard.rb)

- `ActiveRecord::ConnectionAdapters::PostgreSQLAdapter` に `Module.prepend`。
- 包むメソッド（Rails 7.1〜8.x 互換、バージョンガード付き）:
  - `internal_exec_query(sql, name, binds, ...)` (Rails 7.1+)
  - `exec_update` / `exec_delete` / `exec_insert`
  - `execute(sql, name)` (生 SQL 経路)
- 先頭で `Current.bypass?` を判定 → false なら `Analyzer.analyze(sql)` → 違反で対応する Violation を raise、OK なら `super`。
- prepared statement では binds が `ParamRef` として AST に現れるため、Analyzer は「`tenant_column = $N` の形であり、かつ対応する bind 値が Current.tenant_id と一致する」ところまで検査する。

### 7. `StrongMultiTenant::Violation` (lib/strong_multi_tenant/violation.rb)

例外体系:

```
StrongMultiTenant::Violation < StandardError       (親)
├── TenantViolation              # policy 系 (root/direct/fk/hybrid 違反)
├── NoWhereViolation             # WHERE 無し違反
├── ParentTenantMismatch         # v1.x: parent_check :runtime_exists で親不一致
├── ConfigurationError           # yml/lock 不備、未存在テーブル指定
└── StaleLockError               # lock と yml/schema の digest 不一致
```

全て `#sql`, `#table`, `#reason`, `#tenant_context` を持ち、`ActiveSupport::Notifications.instrument("strong_multi_tenant.violation", ...)` で観測可能。

### 8. Public API (`StrongMultiTenant.bypass` / `.with_tenant` / `.allow_no_where`)

```ruby
StrongMultiTenant.bypass { Post.unscoped.find(id) }              # 全検査を無効化 (管理/バッチ)
StrongMultiTenant.with_tenant(42) { Post.find(id) }              # 一時切替
StrongMultiTenant.allow_no_where(:countries) { Country.all }     # NoWhere のみ許可
StrongMultiTenant.allow_no_where(:countries, :currencies) { ... }  # 複数指定
```

レイヤ整理:

- `bypass` — テナント検査 + NoWhere 検査の **両方をスキップ**。
- `allow_no_where` — **NoWhere 検査のみスキップ**。テナント検査は維持。
- いずれも `Current` 上でブロックスコープに管理（Fiber-safe）。
- 優先順位: `Current.bypass?` なら両方スキップ → `Current.allow_no_where_tables` で NoWhere のみスキップ。

### 9. `StrongMultiTenant::Railtie` (lib/strong_multi_tenant/railtie.rb)

- `config.strong_multi_tenant` 設定スロット（`digest_mismatch_mode: :raise | :warn`）。
- `after_initialize` で:
  1. `config/strong_multi_tenant.yml` を読む（未配置 → `ConfigurationError`）
  2. `config/strong_multi_tenant.lock.yml` を読む（未配置 → `ConfigurationError: run strong_multi_tenant:build`）
  3. lock の `source_digest` と現在の yml のハッシュを比較。`schema_digest` と `db/schema.rb` のハッシュも照合。
     - dev/test は `StaleLockError` で raise（既定）、prod は warn（ENV で切替可）。
  4. Registry に policies をロード、Adapter に prepend。
- `env.test?` / `env.development?` / `production` 全てで有効。prod のソフト運用は `digest_mismatch_mode: :warn` で段階導入。

schema introspection は build 時のみ、boot は lock を読むだけ。

### 10. rake タスク (lib/strong_multi_tenant/tasks/strong_multi_tenant.rake)

- `strong_multi_tenant:build` — yml + schema から lock を生成してディスクに書き出す。
- `strong_multi_tenant:check` — オンメモリで build → ディスク lock と diff。差分で非ゼロ終了（CI 用）。
- `strong_multi_tenant:graph` — policy グラフを dot 形式で出力（v1.1）。

### 11. インストーラジェネレータ (lib/generators/strong_multi_tenant/install_generator.rb)

- `rails g strong_multi_tenant:install` で:
  - `config/strong_multi_tenant.yml`（roots / direct / skip の雛形 + コメント説明）
  - `config/initializers/strong_multi_tenant.rb`（`digest_mismatch_mode` 等の設定）
  - `app/controllers/concerns/strong_multi_tenant_context.rb`（`before_action` で Current 設定する雛形）
- その後ユーザーは yml を埋めて `rake strong_multi_tenant:build` で初期 lock を生成。

## 設定ファイルの形式

### 手書き: `config/strong_multi_tenant.yml`

```yaml
# ルート: テーブル自体がテナント (id がテナントID)
roots:
  - organizations

# 直接: 自テーブルに tenant_column を持つ
direct:
  posts: organization_id
  users: organization_id
  invoices: organization_id

# 明示除外: FK が繋がっていても検査対象外にしたいもの
skip:
  - active_storage_blobs
  - solid_queue_jobs

# 親 ID 検査モード (v1 は trust_app のみ有効、他は NotImplementedError)
parent_check:
  # payment_transactions: runtime_exists   # v1.x で有効化予定
```

boot 時に「全エントリがスキーマに存在するか」を検証、未存在なら `ConfigurationError`。v1 では `parent_check:` セクションのパースだけ実装し、`trust_app` 以外の値は `NotImplementedError` を raise する（実装予定であることを明示）。

### 生成: `config/strong_multi_tenant.lock.yml`

```yaml
# AUTOGENERATED by strong_multi_tenant:build — DO NOT EDIT.
schema_digest: <db/schema.rb の SHA256>
source_digest: <strong_multi_tenant.yml の SHA256>

policies:
  organizations: { mode: root, tenant_column: id }
  posts:         { mode: direct, tenant_column: organization_id }
  users:         { mode: direct, tenant_column: organization_id }

  comments:
    mode: fk
    fk_columns: [post_id]
    parents: [posts]
    parent_check: trust_app

  comment_reports:
    mode: hybrid
    fk_columns: [comment_id]
    parents: [comments]
    tenant_column: organization_id
    parent_check: trust_app

skipped:
  explicit:    [active_storage_blobs, solid_queue_jobs]
  automatic:   [ar_internal_metadata, schema_migrations]
  unreachable: [countries, currencies]
```

Registry は lock を表引きするだけ（派生計算を boot で再実行しない）。

## Gem レイアウト

```
strong_multi_tenant/
├── strong_multi_tenant.gemspec
├── Gemfile
├── Rakefile
├── lib/
│   ├── strong_multi_tenant.rb              # public API (bypass, with_tenant, allow_no_where)
│   ├── strong_multi_tenant/
│   │   ├── version.rb
│   │   ├── current.rb
│   │   ├── policy.rb                       # mode / parent_check enum
│   │   ├── registry.rb                     # lock からのみ構築
│   │   ├── manifest.rb                     # yml + lock ローダ
│   │   ├── manifest/
│   │   │   ├── source.rb                   # yml パース + バリデーション
│   │   │   ├── builder.rb                  # source + schema から lock 構築
│   │   │   └── schema_reader.rb            # connection.foreign_keys ラッパ
│   │   ├── analyzer.rb                     # ← コア (pg_query)
│   │   ├── analyzer/
│   │   │   ├── walker.rb                   # AST 再帰
│   │   │   ├── predicate.rb                # WHERE 内のテナント述語判定
│   │   │   └── no_where.rb                 # NoWhere 検査
│   │   ├── adapter_guard.rb
│   │   ├── violation.rb                    # 例外体系
│   │   ├── tasks/
│   │   │   └── strong_multi_tenant.rake
│   │   └── railtie.rb
│   └── generators/
│       └── strong_multi_tenant/install_generator.rb
├── spec/
│   ├── dummy/                               # 最小 Rails アプリ (AR + PG)
│   ├── manifest/
│   │   ├── source_spec.rb
│   │   └── builder_spec.rb                  # FK グラフ、循環、複合FK
│   ├── analyzer_spec.rb                     # 広範な SQL パターン網羅
│   ├── analyzer/no_where_spec.rb
│   ├── adapter_guard_spec.rb
│   ├── registry_spec.rb
│   └── integration_spec.rb
└── README.md
```

## 依存

- `activerecord >= 7.1`
- `activesupport >= 7.1`
- `pg_query ~> 6.2`
- `pg` (開発/テスト時の直指定、本体は AR 経由)

## 段階的な実装順序

1. **gemspec / Gemfile / CI(GitHub Actions)** — Ruby 3.2+ / Rails 7.1,8.0 マトリクス、PG サービスコンテナ。
2. **`Current` + `Policy`** — mode / parent_check の enum、`allow_no_where_tables` Set を含む。純粋ロジック、ユニットテスト容易。
3. **`Manifest::Source`** — YAML パース + バリデーション（未存在テーブル検知、形式チェック）。
4. **`Manifest::Builder`** — FK グラフ BFS、`:fk` / `:hybrid` / `unreachable` 解決。循環検知。
5. **rake `strong_multi_tenant:build` / `check`** — ビルダを CLI から駆動。
6. **`Manifest` ローダ + `Registry`** — lock → Policy オブジェクト群を構築。
7. **`Analyzer` 骨格** — `PgQuery.parse` ラッパ + SELECT の単純ケース（1 テーブル WHERE 直書き）+ **NoWhere 検査**。
8. **`Analyzer` 拡張** — `:fk` / `:hybrid` / JOIN / 相関サブクエリ / 非相関サブクエリ / CTE / UNION / INSERT/UPDATE/DELETE。**各パターンを spec で網羅**（最大の作業量）。
9. **`AdapterGuard`** — dummy app で実クエリを流し、prepend の互換性を Rails 7.1 / 8.0 で確認。
10. **`Railtie`** — boot 時 lock ロード + digest 検証 + prepend 起動。
11. **`bypass` / `with_tenant` / `allow_no_where`** + ActiveSupport::Notifications 発火。
12. **install generator + README + 使用例**。

## 重要な設計判断とトレードオフ

- **情報源を YAML に一本化** — モデル DSL と YAML の二重管理を避ける。モデルクラスはそのままで、テナント境界はリポジトリ成果物として一箇所で可視化・レビュー可能。
- **規約ベースを廃止** — 列名推測（`organization_id` > `tenant_id` > `account_id`）は誤検知/漏れの温床。宣言と FK グラフという「事実」だけを使う。
- **書き換えしない（v1）** — `default_scope` のような暗黙スコープ注入はしない。「すり抜けた瞬間に落とす」責務に特化し、挙動が予測可能な境界を作る。
- **NoWhere 禁止を横断ルールとして置く** — policy のすり抜けや unreachable マスタでの全件スキャン事故を別レイヤで止める。`allow_no_where` で明示的に例外化する運用。
- **`:fk` の値検査省略** — Rails の `has_many` が発行する単純 `WHERE post_id = $1` を通すための意図的な妥協。v1 は trust_app で、`parent_check` 拡張ポイントを切って v1.x の `:runtime_exists` / v2 の `:rewrite` への道を残す。
- **lock ファイルを checked-in** — schema.rb と同じ運用。migration 追加 → `build` → lock コミット。`check` が CI で drift を落とす。
- **キャッシュは fingerprint 単位** — ポリシー構造は fingerprint に閉じるので安全。`Current.tenant_id` との突合は毎回。
- **生 `execute("...")` も対象** — 静的 SQL で `tenant_id` を書き忘れた場合もそこで止める。必要な場面は `StrongMultiTenant.bypass` を明示してもらう。
- **prepared statement** — binds 値は `ParamRef` として AST に現れるため、「`tenant_column = $N` の形で、対応する bind 値が Current.tenant_id と一致する」ところまで検査する。

## 検証計画

### ユニット (`Analyzer`)

以下の SQL パターンを pg_query で生成した固定 SQL で検査:

- 単純 `SELECT ... WHERE tenant_id = $1`
- テーブル別名、スキーマ修飾
- `JOIN` 先に :direct テーブルがある場合
- 相関サブクエリ / 非相関サブクエリ
- `WITH cte AS (...)` 内外
- `UNION ALL` 各枝
- `INSERT ... VALUES`, `INSERT ... SELECT`
- `UPDATE ... WHERE`, `DELETE ... WHERE`
- ポリシー未登録テーブルのみ触るクエリ（テナント検査は通る／NoWhere 検査は別途効く）
- FK 派生単独 `SELECT * FROM comments WHERE post_id = $1` が通る
- `SELECT * FROM comments`（WHERE 無し）が `NoWhereViolation`
- `:hybrid` で tenant_column / fk_column それぞれ単独で通る
- `parent_check: runtime_exists` 指定で v1 は `NotImplementedError`

### ユニット (`Manifest::Builder`)

- root → direct → fk → fk の多段で到達テーブルが正しく `:fk` 展開される
- 非正規化 tenant_column を持つ派生が `:hybrid` に昇格する
- 循環 FK（self-reference, 相互参照）でビルダが停止する
- 複合 FK が `fk_columns` 配列に展開される（v2 前提の枠のみ）
- `skip` 指定テーブルは `skipped.explicit` へ
- 到達しないテーブルは `skipped.unreachable` へ
- yml から direct エントリを削除 → lock から対応が消える

### 結合 (`spec/dummy`)

- `Post`（organization_id）, `Comment`（post_id のみ）を用意
- `Current.tenant_id = 1` で `Post.where(organization_id: 2)` → `TenantViolation` raise
- `Current.tenant_id = 1` で `Post.where(organization_id: 1)` → 通る
- `Comment.where(post_id: 1)` → 通る（`:fk` + `parent_check: trust_app`）
- `Comment.all` → `NoWhereViolation`
- `skip` 指定テーブルはテナント検査スキップ、ただし WHERE なしは `NoWhereViolation`
- `unreachable` マスタ系も同様（WHERE 必須）
- `StrongMultiTenant.allow_no_where(:countries) { Country.all }` → 通る
- `StrongMultiTenant.bypass { Post.all }` → 両検査スキップ
- `find_by_sql("SELECT * FROM posts")` → `NoWhereViolation`
- マイグレーション（`schema_migrations`）は通る（AR SCHEMA 早期 return）

### 結合 (Manifest)

- migration 追加（FK 追加） → `rake strong_multi_tenant:check` が非ゼロ終了
- yml を書き換えて `build` 未実行 → boot 時に `StaleLockError`（dev/test）
- `digest_mismatch_mode: :warn` で prod は起動成功 + warn

### バージョン / 性能

- Rails 7.1 / 7.2 / 8.0 で CI を回す。
- `benchmark-ips` で analyzer 1 回あたりの overhead を計測、fingerprint キャッシュ有効時に 20µs オーダーに収まるか確認。

## プラン受け入れ基準 (self-check)

実装着手前にこのプラン自体が下記を満たすかを確認する:

- [ ] 規約ベース自動検出（列名推測）の記述が残っていない
- [ ] モデル DSL (`rls_root` / `rls_tenant` / `rls_skip`) が登場しない
- [ ] yml + lock ファイルの運用が一貫して記述されている
- [ ] Policy mode が `:root / :direct / :fk / :hybrid` の 4 種で統一
- [ ] `:fk` の「値検査しない」トレードオフと、`parent_check` 拡張ポイントが明記されている
- [ ] NoWhere 禁止が独立ルールとして記述され、`allow_no_where` / `bypass` の違いが整理されている
- [ ] 例外体系（`NoWhereViolation` / `ParentTenantMismatch` / `StaleLockError` 等）が一覧化されている
- [ ] `check` による CI drift 検出運用が書かれている
- [ ] ポリモーフィック・複合 FK・JOIN 伝播・複数 root が v2 送りとして明示

## v2 以降に回すもの

- **ポリモーフィック関連** — 真の FK が無いため FK グラフで拾えない。v1.1 で yml に `polymorphic:` セクションを追加し `{ commentable: { Post: organization_id, Article: organization_id } }` 形式で手書きする案。v1 は該当モデルを `direct` に書いて回避。
- **`parent_check: :runtime_exists`** — AdapterGuard 内で対象 SQL 検出時に `SELECT 1 FROM <parent> WHERE id = $fk AND <tenant_col> = $tenant LIMIT 1` を先行発行、0 行なら `ParentTenantMismatch`。リクエスト内 LRU で検証済み `(table, id)` をキャッシュしオーバーヘッドを圧縮。v1.x。
- **`parent_check: :rewrite`** — `WHERE post_id = $1` を `... AND EXISTS (SELECT 1 FROM posts WHERE posts.id = $1 AND posts.organization_id = $2)` に伸長。「書き換えしない」原則の転換を伴うため v2 で議論。
- **JOIN 経由の親ポリシー伝播** — `comments JOIN posts ON ... WHERE posts.organization_id = $1` で comments の fk 列未束縛でも安全と見做す `:fk_via_join` を v2 で。
- **複数 root** — `roots:` が配列なのでビルダは対応するが、複数テナント軸（例: organization + workspace）の `Current.tenant_id` 切替設計は要検討。
- **複合 FK** — Rails では稀。`fk_columns` が既に配列なのでビルダ拡張で対応可能。
- **静的解析 CLI** — `strong_multi_tenant check path/to/*.sql` のような Rails 非依存経路。Analyzer コアは既に Rails 非依存に切り出してあるため、CLI ラッパのみ追加すれば動く。
- **MySQL adapter**。
- **PostgreSQL native RLS への export** — policy 定義から `CREATE POLICY` を生成。
