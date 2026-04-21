# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrongMultiTenant::Analyzer do
  let(:policies) do
    {
      organizations: { mode: "root", tenant_column: "id" },
      posts: { mode: "direct", tenant_column: "organization_id" },
      comments: { mode: "fk", fk_columns: ["post_id"], parents: ["posts"], parent_check: "trust_app" },
      comment_reports: {
        mode: "hybrid", tenant_column: "organization_id",
        fk_columns: ["comment_id"], parents: ["comments"], parent_check: "trust_app"
      }
    }
  end

  subject(:analyzer) { analyzer_for(policies) }

  before { StrongMultiTenant::Current.tenant_id = 1 }

  describe "root/direct tenant predicate" do
    it "passes a SELECT with tenant_column = const matching current" do
      r = analyzer.analyze("SELECT * FROM posts WHERE organization_id = 1 AND id = 5")
      expect(r).to be_ok
    end

    it "violates when tenant const mismatches current tenant_id" do
      r = analyzer.analyze("SELECT * FROM posts WHERE organization_id = 2 AND id = 5")
      expect(r.ok?).to be false
      expect(r.kind).to eq :tenant
      expect(r.table).to eq :posts
    end

    it "violates when tenant predicate is missing" do
      r = analyzer.analyze("SELECT * FROM posts WHERE id = 5")
      expect(r.ok?).to be false
      expect(r.kind).to eq :tenant
    end

    it "accepts a ParamRef when the bind matches tenant_id" do
      r = analyzer.analyze("SELECT * FROM posts WHERE organization_id = $1 AND id = $2", binds: [1, 5])
      expect(r).to be_ok
    end

    it "violates when ParamRef bind mismatches tenant_id" do
      r = analyzer.analyze("SELECT * FROM posts WHERE organization_id = $1", binds: [2])
      expect(r.ok?).to be false
    end

    it "honors table aliases" do
      r = analyzer.analyze("SELECT * FROM posts AS p WHERE p.organization_id = 1")
      expect(r).to be_ok
    end

    it "does not accept OR-strengthening" do
      r = analyzer.analyze("SELECT * FROM posts WHERE organization_id = 1 OR id = 2")
      expect(r.ok?).to be false
    end
  end

  describe "fk policy" do
    it "passes a simple fk predicate without value check" do
      r = analyzer.analyze("SELECT * FROM comments WHERE post_id = 999")
      expect(r).to be_ok
    end

    it "passes a ParamRef fk predicate (value not checked)" do
      r = analyzer.analyze("SELECT * FROM comments WHERE post_id = $1", binds: [999])
      expect(r).to be_ok
    end

    it "passes an IN list" do
      r = analyzer.analyze("SELECT * FROM comments WHERE post_id IN (1,2,3)")
      expect(r).to be_ok
    end

    it "violates when no fk predicate present (but WHERE exists)" do
      r = analyzer.analyze("SELECT * FROM comments WHERE body = 'hi'")
      expect(r.ok?).to be false
      expect(r.kind).to eq :tenant
    end
  end

  describe "hybrid policy" do
    it "passes on tenant_column binding" do
      r = analyzer.analyze("SELECT * FROM comment_reports WHERE organization_id = 1")
      expect(r).to be_ok
    end

    it "passes on fk binding" do
      r = analyzer.analyze("SELECT * FROM comment_reports WHERE comment_id = 99")
      expect(r).to be_ok
    end

    it "violates when neither predicate present" do
      r = analyzer.analyze("SELECT * FROM comment_reports WHERE id = 1")
      expect(r.ok?).to be false
    end
  end

  describe "NoWhere" do
    it "flags SELECT without WHERE" do
      r = analyzer.analyze("SELECT * FROM posts")
      expect(r.ok?).to be false
      expect(r.kind).to eq :no_where
    end

    it "flags WHERE TRUE" do
      r = analyzer.analyze("SELECT * FROM posts WHERE TRUE")
      expect(r.ok?).to be false
      expect(r.kind).to eq :no_where
    end

    it "allows allowlisted tables" do
      StrongMultiTenant.allow_no_where(:posts) do
        # still needs tenant predicate though — so this should fail as tenant, not no_where
        r = analyzer.analyze("SELECT * FROM posts")
        expect(r.ok?).to be false
        expect(r.kind).to eq :tenant
      end
    end

    it "is skipped in bypass" do
      StrongMultiTenant.bypass do
        r = analyzer.analyze("SELECT * FROM posts")
        expect(r).to be_ok
      end
    end

    it "flags UPDATE without WHERE" do
      r = analyzer.analyze("UPDATE posts SET title = 'x'")
      expect(r.ok?).to be false
      expect(r.kind).to eq :no_where
    end

    it "flags DELETE without WHERE" do
      r = analyzer.analyze("DELETE FROM posts")
      expect(r.ok?).to be false
      expect(r.kind).to eq :no_where
    end
  end

  describe "UPDATE / DELETE tenant predicate" do
    it "passes UPDATE ... WHERE organization_id = 1" do
      r = analyzer.analyze("UPDATE posts SET title = 'x' WHERE organization_id = 1 AND id = 5")
      expect(r).to be_ok
    end

    it "violates UPDATE ... WHERE id = 5 (no tenant)" do
      r = analyzer.analyze("UPDATE posts SET title = 'x' WHERE id = 5")
      expect(r.ok?).to be false
      expect(r.kind).to eq :tenant
    end

    it "passes DELETE ... WHERE fk on :fk table" do
      r = analyzer.analyze("DELETE FROM comments WHERE post_id = 5")
      expect(r).to be_ok
    end
  end

  describe "INSERT" do
    it "passes when tenant column is listed and matches current" do
      r = analyzer.analyze(
        "INSERT INTO posts (title, organization_id) VALUES ('hi', 1)"
      )
      expect(r).to be_ok
    end

    it "passes when tenant is via ParamRef" do
      r = analyzer.analyze(
        "INSERT INTO posts (title, organization_id) VALUES ($1, $2)",
        binds: ["hi", 1]
      )
      expect(r).to be_ok
    end

    it "violates when tenant const mismatches current" do
      r = analyzer.analyze(
        "INSERT INTO posts (title, organization_id) VALUES ('hi', 999)"
      )
      expect(r.ok?).to be false
      expect(r.kind).to eq :tenant
    end

    it "violates when tenant column is omitted" do
      r = analyzer.analyze("INSERT INTO posts (title) VALUES ('hi')")
      expect(r.ok?).to be false
      expect(r.kind).to eq :tenant
    end

    it "doesn't touch fk-only tables (values not checked)" do
      r = analyzer.analyze(
        "INSERT INTO comments (post_id, body) VALUES (5, 'hi')"
      )
      expect(r).to be_ok
    end
  end

  describe "JOIN" do
    it "v1: JOIN ON with column=column on :fk side does NOT satisfy fk binding (v2 feature)" do
      # Rails-style `has_many :comments` join produces `comments.post_id = posts.id`.
      # The plan defers JOIN-propagation of parent policy to v2 (:fk_via_join).
      sql = <<~SQL
        SELECT posts.* FROM posts
        INNER JOIN comments ON comments.post_id = posts.id
        WHERE posts.organization_id = 1
      SQL
      r = analyzer.analyze(sql)
      expect(r.ok?).to be false
      expect(r.table).to eq :comments
    end

    it "accepts fk-bound JOIN when fk column is equated to a const/param" do
      sql = <<~SQL
        SELECT c.* FROM comments AS c
        WHERE c.post_id = $1
      SQL
      r = analyzer.analyze(sql, binds: [42])
      expect(r).to be_ok
    end

    it "violates when a joined :direct table lacks tenant predicate" do
      policies2 = {
        organizations: { mode: "root", tenant_column: "id" },
        posts: { mode: "direct", tenant_column: "organization_id" },
        users: { mode: "direct", tenant_column: "organization_id" }
      }
      a = analyzer_for(policies2)
      sql = "SELECT * FROM posts INNER JOIN users ON users.id = posts.author_id WHERE posts.organization_id = 1"
      r = a.analyze(sql)
      expect(r.ok?).to be false
      expect(r.table).to eq :users
    end
  end

  describe "bypass / skip" do
    it "bypass skips tenant check" do
      StrongMultiTenant.bypass do
        r = analyzer.analyze("SELECT * FROM posts WHERE id = 5")
        expect(r).to be_ok
      end
    end

    it "with_tenant temporarily swaps tenant_id" do
      StrongMultiTenant.with_tenant(42) do
        r = analyzer.analyze("SELECT * FROM posts WHERE organization_id = 42")
        expect(r).to be_ok
      end
      # restored
      expect(StrongMultiTenant::Current.tenant_id).to eq 1
    end

    it "tables with no policy pass tenant check but still need WHERE" do
      a = analyzer_for(policies, skipped: { explicit: [:countries] })
      r = a.analyze("SELECT * FROM countries WHERE code = 'JP'")
      expect(r).to be_ok
      r2 = a.analyze("SELECT * FROM countries")
      expect(r2.ok?).to be false
      expect(r2.kind).to eq :no_where
    end

    it "passes transactional statements unchanged" do
      %w[BEGIN COMMIT ROLLBACK].each do |s|
        expect(analyzer.analyze(s)).to be_ok
      end
    end

    it "passes SET / SHOW" do
      expect(analyzer.analyze("SET client_min_messages TO WARNING")).to be_ok
      expect(analyzer.analyze("SHOW server_version")).to be_ok
    end
  end

  describe "subqueries / CTE" do
    it "checks CTE interior as its own scope" do
      sql = <<~SQL
        WITH scoped AS (SELECT * FROM posts WHERE organization_id = 1)
        SELECT * FROM scoped WHERE id = 2
      SQL
      r = analyzer.analyze(sql)
      expect(r).to be_ok
    end

    it "violates when CTE interior lacks tenant predicate" do
      sql = <<~SQL
        WITH scoped AS (SELECT * FROM posts WHERE id = 5)
        SELECT * FROM scoped
      SQL
      r = analyzer.analyze(sql)
      expect(r.ok?).to be false
    end

    it "checks UNION branches separately" do
      sql = <<~SQL
        SELECT id FROM posts WHERE organization_id = 1
        UNION ALL
        SELECT id FROM posts WHERE id = 5
      SQL
      r = analyzer.analyze(sql)
      expect(r.ok?).to be false
    end
  end
end
