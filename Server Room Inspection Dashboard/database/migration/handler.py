"""
MCF Server Room Inspection Dashboard — in-VPC migration / query Lambda.

Runs inside the private-app subnets with the app security group, so it can
reach the private RDS PostgreSQL instance on 5432 (the data SG already allows
5432 from the app SG). It never has a public IP.

It is the reusable schema-migration + verification mechanism for every phase.

Actions (event["action"]):
  * "migrate" (default) — apply every bundled sql/NNN_*.sql file in sorted
      order inside its own transaction, then set the srid_app login password
      from Secrets Manager (parameterised, never logged).
  * "query"  — run a read-only SQL string (event["sql"]) and return the rows.
  * "exec"   — run a single ad-hoc SQL statement (event["sql"]) and commit.

Credentials come only from the db secret (env DB_SECRET_ARN). Nothing sensitive
is ever printed. psycopg2 connects with sslmode=require (RDS forces SSL).
"""

import glob
import json
import os

import boto3
import psycopg2
import psycopg2.extras

_SECRETS = boto3.client("secretsmanager")
SQL_DIR = os.path.join(os.path.dirname(__file__), "sql")


def _load_secret():
    arn = os.environ["DB_SECRET_ARN"]
    resp = _SECRETS.get_secret_value(SecretId=arn)
    return json.loads(resp["SecretString"])


def _connect(secret):
    return psycopg2.connect(
        host=secret["host"],
        port=int(secret["port"]),
        dbname=secret["dbname"],
        user=secret["username"],
        password=secret["password"],
        sslmode="require",
        connect_timeout=10,
    )


def _migrate(conn, secret):
    applied = []
    files = sorted(glob.glob(os.path.join(SQL_DIR, "*.sql")))
    if not files:
        raise RuntimeError(f"no .sql files bundled under {SQL_DIR}")

    for path in files:
        with open(path, "r", encoding="utf-8") as fh:
            ddl = fh.read()
        with conn:  # transaction per file
            with conn.cursor() as cur:
                cur.execute(ddl)
        applied.append(os.path.basename(path))

    # Set the application role password from the secret (parameterised).
    app_user = secret.get("app_username", "srid_app")
    app_pw = secret.get("app_password")
    if app_pw:
        with conn:
            with conn.cursor() as cur:
                # Role name cannot be bound; it is a fixed constant, not input.
                cur.execute(
                    f'ALTER ROLE {app_user} WITH LOGIN PASSWORD %s', (app_pw,)
                )

    # Post-migration inventory for the caller.
    with conn.cursor() as cur:
        cur.execute(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema = 'srid' ORDER BY table_name"
        )
        objects = [r[0] for r in cur.fetchall()]

    return {"applied": applied, "srid_objects": objects}


def _query(conn, sql):
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(sql)
        rows = cur.fetchall()
    # Make Decimal/date JSON-serialisable.
    return json.loads(json.dumps(rows, default=str))


def _exec(conn, sql):
    with conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            affected = cur.rowcount
    return {"rowcount": affected}


def handler(event, _context):
    event = event or {}
    action = event.get("action", "migrate")
    secret = _load_secret()
    conn = _connect(secret)
    try:
        if action == "migrate":
            result = _migrate(conn, secret)
        elif action == "query":
            result = {"rows": _query(conn, event["sql"])}
        elif action == "exec":
            result = _exec(conn, event["sql"])
        else:
            raise ValueError(f"unknown action: {action}")
    finally:
        conn.close()

    return {"ok": True, "action": action, **result}
