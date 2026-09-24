#!/bin/bash
# As tabelas usam FORCE ROW LEVEL SECURITY: a conta da aplicação NÃO pode ser
# superusuário nem ter BYPASSRLS, senão o isolamento por tenant deixa de valer.
# Por isso as migrações (seed) rodam com a conta "admin" (Flyway) e a API usa
# "milebag_app", que só recebe os privilégios de DML sobre o que o admin criar.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
CREATE ROLE milebag_app LOGIN PASSWORD '${MILEBAG_APP_SENHA}' NOSUPERUSER NOBYPASSRLS;
CREATE DATABASE milebag OWNER ${POSTGRES_USER};
SQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname milebag <<SQL
GRANT ALL ON SCHEMA public TO milebag_app;
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO milebag_app;
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public GRANT USAGE,SELECT ON SEQUENCES TO milebag_app;
SQL
