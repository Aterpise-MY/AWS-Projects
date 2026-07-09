"""
AWS Glue Python-shell backfill job — MCF Server Room Inspection Dashboard.

Reads the synthetic legacy-format CSV from the backfill S3 bucket, cleans the
legacy gotchas, and UPSERTs into the private RDS PostgreSQL `srid.inspection_log`
table. The job runs inside the VPC via an attached Glue NETWORK connection
(private-app subnet + a SG allowed to reach the data SG on 5432), so it can
reach the private, non-public RDS instance.

Cleaning / transform rules:
  * strip units from string readings ("24.5 °C" -> 24.50, "52 %" -> 52,
    "417.3 V" -> 417.30, "12.4 A" -> 12.40) and cast to NUMERIC
  * derive a globally-unique log_id = per-plant offset + SharePoint list item id
      P1 -> 100000 + id     P2 -> 200000 + id
  * set source_site from the plant column
  * normalise inspector sAMAccountName to UPPER, upsert into srid.inspectors,
    resolve inspector_id
  * idempotent UPSERT (ON CONFLICT (log_id) DO UPDATE)

Credentials are read from Secrets Manager (never passed on the command line).
psycopg2 is supplied at runtime via --additional-python-modules psycopg2-binary.
"""

import csv
import io
import re
import sys

import boto3
import psycopg2
import psycopg2.extras
from awsglue.utils import getResolvedOptions

ARGS = getResolvedOptions(
    sys.argv,
    ["backfill_bucket", "backfill_key", "db_secret_arn", "region"],
)

PLANT_OFFSETS = {"P1": 100000, "P2": 200000}
_NUM = re.compile(r"[-+]?\d*\.?\d+")


def strip_units(value):
    """'24.5 °C' -> Decimal-safe float; '' / None -> None."""
    if value is None:
        return None
    m = _NUM.search(str(value))
    return float(m.group()) if m else None


def load_secret(region, arn):
    import json
    sm = boto3.client("secretsmanager", region_name=region)
    return json.loads(sm.get_secret_value(SecretId=arn)["SecretString"])


def read_csv(region, bucket, key):
    s3 = boto3.client("s3", region_name=region)
    body = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8")
    return list(csv.DictReader(io.StringIO(body)))


def main():
    rows = read_csv(ARGS["region"], ARGS["backfill_bucket"], ARGS["backfill_key"])
    print(f"read {len(rows)} source rows from "
          f"s3://{ARGS['backfill_bucket']}/{ARGS['backfill_key']}")

    secret = load_secret(ARGS["region"], ARGS["db_secret_arn"])
    conn = psycopg2.connect(
        host=secret["host"], port=int(secret["port"]), dbname=secret["dbname"],
        user=secret["username"], password=secret["password"],
        sslmode="require", connect_timeout=15,
    )
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            cur.execute("SET search_path = srid, public")

            # 1) Upsert distinct inspectors, then resolve id map.
            sams = sorted({(r["inspector_sam"] or "").strip().upper()
                           for r in rows if r.get("inspector_sam")})
            for sam in sams:
                cur.execute(
                    "INSERT INTO srid.inspectors (sam_account_name, display_name) "
                    "VALUES (%s, %s) ON CONFLICT (sam_account_name) DO NOTHING",
                    (sam, sam),
                )
            cur.execute("SELECT inspector_id, sam_account_name FROM srid.inspectors")
            id_map = {r[1]: r[0] for r in cur.fetchall()}

            # 2) Build cleaned inspection_log rows.
            payload = []
            for r in rows:
                plant = r["plant"].strip().upper()
                offset = PLANT_OFFSETS[plant]
                log_id = offset + int(r["list_item_id"])
                sam = (r["inspector_sam"] or "").strip().upper() or None
                payload.append((
                    log_id,
                    plant,
                    r["inspection_date"],
                    r["shift"].strip().upper(),
                    r["inspected_at"],
                    id_map.get(sam),
                    sam,
                    strip_units(r["temperature"]),
                    strip_units(r["humidity"]),
                    strip_units(r["ups1_voltage"]),
                    strip_units(r["ups1_current"]),
                    strip_units(r["ups2_voltage"]),
                    strip_units(r["ups2_current"]),
                    r.get("status"),
                    psycopg2.extras.Json(r),   # raw_source audit copy
                ))

            # 3) Idempotent UPSERT keyed on the offset log_id.
            psycopg2.extras.execute_values(
                cur,
                """
                INSERT INTO srid.inspection_log (
                    log_id, source_site, inspection_date, shift, inspected_at,
                    inspector_id, sam_account_name, temperature_c, humidity_pct,
                    ups1_voltage_v, ups1_current_a, ups2_voltage_v, ups2_current_a,
                    status, raw_source
                ) VALUES %s
                ON CONFLICT (log_id) DO UPDATE SET
                    source_site      = EXCLUDED.source_site,
                    inspection_date  = EXCLUDED.inspection_date,
                    shift            = EXCLUDED.shift,
                    inspected_at     = EXCLUDED.inspected_at,
                    inspector_id     = EXCLUDED.inspector_id,
                    sam_account_name = EXCLUDED.sam_account_name,
                    temperature_c    = EXCLUDED.temperature_c,
                    humidity_pct     = EXCLUDED.humidity_pct,
                    ups1_voltage_v   = EXCLUDED.ups1_voltage_v,
                    ups1_current_a   = EXCLUDED.ups1_current_a,
                    ups2_voltage_v   = EXCLUDED.ups2_voltage_v,
                    ups2_current_a   = EXCLUDED.ups2_current_a,
                    status           = EXCLUDED.status,
                    raw_source       = EXCLUDED.raw_source
                """,
                payload,
                template=None,
                page_size=500,
            )

            # 4) Report per-plant counts + id ranges for verification.
            cur.execute(
                "SELECT source_site, COUNT(*), MIN(log_id), MAX(log_id) "
                "FROM srid.inspection_log GROUP BY source_site ORDER BY source_site"
            )
            summary = cur.fetchall()

        conn.commit()
        for site, cnt, lo, hi in summary:
            print(f"  {site}: rows={cnt} log_id range {lo}..{hi}")
        print(f"backfill complete: {len(payload)} rows upserted")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
