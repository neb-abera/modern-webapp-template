-- runtime-role.sql — the role the running app connects as.
--
-- The app's connection string is the one credential an attacker who finds an
-- injection, or a bug that builds SQL, gets to use. So the role behind it can
-- read and write rows and nothing else: it cannot CREATE, ALTER, DROP or
-- TRUNCATE, because it owns nothing. Schema changes are made by a different
-- role — the migrator, which owns the tables — in a separate deploy step
-- (`--migrate`, docs/deploying.md). An app that migrates on boot needs an
-- owner's connection string in the serving process, which is this file undone.
--
-- Run as the migrator — the role that owns the database and its tables —
-- against the app's database, before or after the first migration — default
-- privileges cover tables that do not exist yet:
--
--   psql -v ON_ERROR_STOP=1 -v runtime=app_runtime -v migrator=app_migrator \
--        -f scripts/db/runtime-role.sql
--
-- Idempotent. Both roles must already exist: creating a login, and how it
-- authenticates (a managed identity, or a password from a secret store), is
-- the platform's business and needs more privilege than the migrator has.
-- scripts/db/check-runtime-role.sh proves the grants below against a real
-- PostgreSQL on every `make verify`.

-- PostgreSQL 15+ no longer lets everyone create in public; said out loud so
-- it also holds on a database upgraded from before that.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM :"runtime";
GRANT USAGE ON SCHEMA public TO :"runtime";

-- Rows, and the sequences behind identity/serial columns. Not TRUNCATE, not
-- REFERENCES, not TRIGGER.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"runtime";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"runtime";

-- The same for every table and sequence the migrator creates from now on, so
-- a migration never has to remember a GRANT.
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"runtime";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator" IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"runtime";
