import urllib.parse

import boto3
import urllib3

from observatory.sink import secret

_s3 = boto3.client("s3")
_http = urllib3.PoolManager()


def handler(event, context):
    """S3 ObjectCreated -> mirror the file into the Databricks managed volume."""
    creds = secret("DATABRICKS_SECRET_ARN")
    host = creds["host"].rstrip("/")
    headers = {"Authorization": f"Bearer {creds['token']}", "Content-Type": "application/octet-stream"}

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        if not key.startswith("raw/"):
            continue
        body = _s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        path = urllib.parse.quote(f"/Volumes/sc2/bronze/{key}", safe="/")
        r = _http.request("PUT", f"{host}/api/2.0/fs/files{path}?overwrite=true", body=body, headers=headers)
        if r.status not in (200, 204):
            raise RuntimeError(f"files API {r.status}: {r.data[:200]}")

    return {"synced": len(event.get("Records", []))}
