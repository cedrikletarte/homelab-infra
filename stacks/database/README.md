# database — Shared Database (Postgres)

The single Postgres instance reused by the stacks that do not need their own (ADR 0004). Reachable on the `db_network` Docker network as `postgres:5432`, and on the LAN address only.

## Databases and accounts

Each app owns its database and nothing else; no app connects as a superuser.

| Database | Owner | Content |
|---|---|---|
| `n8n` | `n8n` | n8n's own tables (workflows, executions, credentials). Nobody else can connect to it |
| `homelab` | `postgres` | `homelab_alerts`, the reports of the maintenance scripts, CrowdSec and GitLab (through the n8n workflows) |

| Account | Rights | Used by |
|---|---|---|
| `postgres` | Superuser | Administration only (`POSTGRES_USER` in `.env`) |
| `n8n` | Owner of the `n8n` database | n8n itself (`stacks/management/.env`) |
| `homelab_writer` | `SELECT`, `INSERT` on `homelab_alerts` (`SELECT` because n8n inserts with `RETURNING`) | The n8n credential "Postgres account" of the notification workflows |
| `grafana_reader` | `SELECT` on `homelab_alerts` | The `homelab_alerts` data source of Grafana (`stacks/monitoring/.env`) |

Administration, from the server: `docker exec -it postgres psql -U postgres`.

## Fresh install

Restoring the `postgres_data` volume from the backup brings back the databases and the accounts as they were. On an empty volume, the image creates `POSTGRES_USER` as superuser and `POSTGRES_DB` on first startup, and the rest is created by hand, as `postgres`:

```sql
CREATE ROLE n8n LOGIN PASSWORD '<POSTGRES_PASSWORD of stacks/management/.env>';
CREATE DATABASE n8n OWNER n8n;
REVOKE CONNECT ON DATABASE n8n FROM PUBLIC;

CREATE ROLE homelab_writer LOGIN PASSWORD '<HOMELAB_WRITER_PASSWORD>';
CREATE ROLE grafana_reader LOGIN PASSWORD '<HOMELAB_ALERTS_READER_PASSWORD of stacks/monitoring/.env>';
CREATE DATABASE homelab;
REVOKE ALL ON DATABASE homelab FROM PUBLIC;
GRANT CONNECT ON DATABASE homelab TO homelab_writer, grafana_reader;

\c homelab
CREATE TABLE homelab_alerts (
    id serial PRIMARY KEY,
    source varchar(50),
    status varchar(10),
    message text,
    created_at timestamptz DEFAULT now(),
    logs text
);
GRANT USAGE ON SCHEMA public TO homelab_writer, grafana_reader;
GRANT SELECT, INSERT ON homelab_alerts TO homelab_writer;
GRANT USAGE ON SEQUENCE homelab_alerts_id_seq TO homelab_writer;
GRANT SELECT ON homelab_alerts TO grafana_reader;
```

n8n then starts on its empty database: import its workflows and credentials again.
