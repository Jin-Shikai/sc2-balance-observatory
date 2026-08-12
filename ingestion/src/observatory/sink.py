import functools
import gzip
import json
import os
from datetime import datetime, timezone

import boto3


def utcnow():
    return datetime.now(timezone.utc)


def raw_key(source, endpoint, ts, name="data", hourly=False):
    part = f"dt={ts:%Y-%m-%d}" + (f"/hh={ts:%H}" if hourly else "")
    return f"raw/source={source}/endpoint={endpoint}/{part}/{name}.json.gz"


@functools.cache
def _s3():
    return boto3.client("s3")


def put_raw(source, endpoint, payload, params=None, name="data", hourly=False, ts=None):
    ts = ts or utcnow()
    doc = {
        "ingest_ts": ts.isoformat(),
        "request_params": {k: str(v) for k, v in (params or {}).items()},
        "payload": payload,
    }
    _s3().put_object(
        Bucket=os.environ["BUCKET"],
        Key=raw_key(source, endpoint, ts, name, hourly),
        Body=gzip.compress(json.dumps(doc, separators=(",", ":")).encode()),
        ContentType="application/json",
        ContentEncoding="gzip",
    )


@functools.cache
def secret(env_var):
    arn = os.environ[env_var]
    value = boto3.client("secretsmanager").get_secret_value(SecretId=arn)["SecretString"]
    return json.loads(value)
