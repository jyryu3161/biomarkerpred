#!/usr/bin/env python3
"""Search diseases and save complete, immutable Open Targets association snapshots.

Only public disease identifiers are sent. Association scores describe disease–gene
associations, not drug response or drug target membership. The R engine applies
score thresholds to the saved snapshot; this fetcher never truncates by score.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
import uuid

API_URL = "https://api.platform.opentargets.org/api/v4/graphql"
SEARCH_QUERY = '''query SearchDiseases($query: String!, $size: Int!) {
  search(queryString: $query, entityNames: ["disease"], page: {index: 0, size: $size}) {
    hits { id name description entity }
  }
}'''
TARGET_QUERY = '''query DiseaseTargets($id: String!, $index: Int!, $size: Int!) {
  disease(efoId: $id) { id name
    associatedTargets(page: {index: $index, size: $size}) {
      count rows { target { id approvedSymbol } score }
    }
  }
}'''
MIGRATION = (
    "Drug-linked score fetching is retired: Drug.linkedTargets is unavailable and "
    "drug target membership is not a disease-association score. Use 'search --query TEXT', "
    "then 'fetch --disease-id ONTOLOGY_ID --output-dir DIR'. Choose the disease explicitly; "
    "generate_opentargets_configs.py attaches that snapshot to a base configuration."
)


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def sha256(value):
    return hashlib.sha256(value).hexdigest()


def strict_json(raw):
    def invalid(value):
        raise ValueError(f"Non-finite JSON number in API response: {value}")
    return json.loads(raw, parse_constant=invalid)


def request_bytes(endpoint, body, timeout=30):
    """Bounded retries for transient transport/HTTP failures; never retry bad data."""
    for attempt in range(3):
        try:
            request = Request(endpoint, data=body, headers={
                "Content-Type": "application/json", "Accept": "application/json",
                "User-Agent": "BioMarkerPred-evidence/1.0"}, method="POST")
            with urlopen(request, timeout=timeout) as response:
                return response.read()
        except HTTPError as error:
            if error.code not in (429, 500, 502, 503, 504) or attempt == 2:
                raise ValueError(f"Open Targets HTTP request failed with status {error.code}") from error
        except (URLError, TimeoutError, OSError) as error:
            if attempt == 2:
                raise ValueError(f"Open Targets request failed: {error}") from error
        time.sleep(0.5 * (attempt + 1))
    raise AssertionError("unreachable")


def query_api(query, variables, endpoint, transport=request_bytes):
    request = json_bytes({"query": query, "variables": variables})
    response = transport(endpoint, request)
    value = strict_json(response)
    if not isinstance(value, dict):
        raise ValueError("Open Targets returned a non-object JSON response")
    if value.get("errors"):
        raise ValueError(f"Open Targets GraphQL errors: {json.dumps(value['errors'], ensure_ascii=False)}")
    if not isinstance(value.get("data"), dict):
        raise ValueError("Open Targets response has no data object")
    return value["data"], request, response


def nonempty_string(value, label):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"Missing or invalid {label}")
    return value


def disease_identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_:-]+", value):
        raise ValueError("Disease ID must be an ontology identifier containing letters, digits, underscores, colons or hyphens")
    return value


def search_diseases(query, size=20, endpoint=API_URL, transport=request_bytes):
    if len(query.strip()) < 2 or not 1 <= size <= 100:
        raise ValueError("Search needs at least two characters and size from 1 to 100")
    data, request, response = query_api(SEARCH_QUERY, {"query": query, "size": size}, endpoint, transport)
    search = data.get("search")
    if not isinstance(search, dict) or not isinstance(search.get("hits"), list):
        raise ValueError("Open Targets search response has no hits list")
    hits = []
    identifiers = set()
    for hit in search["hits"]:
        if not isinstance(hit, dict) or hit.get("entity") != "disease":
            raise ValueError("Open Targets returned an unexpected search entity")
        identifier = disease_identifier(hit.get("id"))
        if identifier in identifiers:
            raise ValueError("Open Targets returned duplicate disease search identifiers")
        identifiers.add(identifier)
        hits.append({"disease_id": identifier, "name": nonempty_string(hit.get("name"), "disease name"),
                     "description": hit.get("description")})
    if len(hits) > size:
        raise ValueError("Open Targets returned more search hits than requested")
    return {"ok": True, "operation": "search", "query": query, "hits": hits,
            "api_url": endpoint, "request_sha256": sha256(request), "response_sha256": sha256(response)}


def fetch_snapshot(disease_id, output_dir, page_size=3000, endpoint=API_URL, transport=request_bytes):
    disease_identifier(disease_id)
    if not 1 <= page_size <= 3000:
        raise ValueError("Page size must be from 1 to 3000")
    output_dir = Path(output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    pending = Path(tempfile.mkdtemp(prefix=".pending-", dir=output_dir))
    try:
        exchanges = pending / "requests"
        exchanges.mkdir()
        targets, identifiers, pages = [], set(), []
        expected_count, disease_name = None, None
        while True:
            index = len(pages)
            variables = {"id": disease_id, "index": index, "size": page_size}
            data, request, response = query_api(TARGET_QUERY, variables, endpoint, transport)
            disease = data.get("disease")
            if not isinstance(disease, dict):
                raise ValueError(f"No disease found for {disease_id}; use search to select a current ontology ID")
            if disease.get("id") != disease_id:
                raise ValueError("Open Targets returned a different disease identifier")
            name = nonempty_string(disease.get("name"), "disease name")
            if disease_name is not None and name != disease_name:
                raise ValueError("Disease name changed during pagination; retry for a consistent snapshot")
            disease_name = name
            associated = disease.get("associatedTargets")
            if not isinstance(associated, dict):
                raise ValueError("Disease response has no associatedTargets object")
            count, rows = associated.get("count"), associated.get("rows")
            if type(count) is not int or not 0 <= count <= 1_000_000 or not isinstance(rows, list) or len(rows) > page_size:
                raise ValueError("Invalid Open Targets pagination response")
            if expected_count is not None and count != expected_count:
                raise ValueError("Target count changed during pagination; no partial evidence was published")
            expected_count = count
            for row in rows:
                if not isinstance(row, dict) or not isinstance(row.get("target"), dict):
                    raise ValueError("Missing Open Targets target record")
                target = row["target"]
                identifier = nonempty_string(target.get("id"), "target identifier")
                symbol = nonempty_string(target.get("approvedSymbol"), "approved gene symbol")
                score = row.get("score")
                if type(score) not in (int, float) or not math.isfinite(score) or not 0 <= score <= 1:
                    raise ValueError("Association scores must be finite numbers between 0 and 1")
                if identifier in identifiers:
                    raise ValueError("Repeated target across pages; no partial evidence was published")
                identifiers.add(identifier)
                targets.append({"gene_symbol": symbol, "ensembl_id": identifier, "score": score})
            if len(targets) > count:
                raise ValueError("Open Targets returned more targets than its recorded count")
            request_path = f"requests/{index:05d}.request.json"
            response_path = f"requests/{index:05d}.response.json"
            (pending / request_path).write_bytes(request)
            (pending / response_path).write_bytes(response)
            pages.append({"index": index, "variables": variables, "rows": len(rows),
                          "request_file": request_path, "response_file": response_path,
                          "request_sha256": sha256(request), "response_sha256": sha256(response)})
            if len(targets) == count:
                break
            if len(rows) < page_size:
                raise ValueError("Pagination ended before its recorded total; no partial evidence was published")
        with (pending / "genes.csv").open("w", encoding="utf-8", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=["gene_symbol", "ensembl_id", "score"])
            writer.writeheader()
            writer.writerows(targets)
        csv_hash = sha256((pending / "genes.csv").read_bytes())
        fetched_at = datetime.now(timezone.utc).isoformat()
        metadata = {"schema_version": 1, "source": "Open Targets Platform", "api_url": endpoint,
                    "release": None, "disease_id": disease_id, "efo_id": disease_id, "disease_name": disease_name,
                    "fetched_at": fetched_at, "gene_count": len(targets), "csv_sha256": csv_hash,
                    "complete": True, "query_variables": {"disease_id": disease_id, "page_size": page_size,
                    "pages": len(pages), "expected_count": expected_count}, "pages": pages,
                    "interpretation": "Disease-gene association scores; not evidence of drug-response prediction. All targets are retained; apply a prespecified score threshold in the analysis configuration."}
        (pending / "metadata.json").write_bytes(json_bytes(metadata))
        cache_key = f"{disease_id.replace(':', '_')}-{uuid.uuid4().hex}"
        destination = output_dir / cache_key
        pending.rename(destination)
        return {"ok": True, "operation": "fetch", "cache_key": cache_key,
                "file_path": str(destination / "genes.csv"), "metadata_path": str(destination / "metadata.json"),
                "gene_count": len(targets), "provenance": metadata}
    finally:
        if pending.exists():
            shutil.rmtree(pending)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if any(value.split("=", 1)[0] in {"--drugs", "--mapping-file", "--score-threshold"} for value in argv):
        print(json.dumps({"ok": False, "error": MIGRATION}), file=sys.stdout)
        return 2
    parser = argparse.ArgumentParser(description=__doc__, epilog=MIGRATION)
    subparsers = parser.add_subparsers(dest="command", required=True)
    search = subparsers.add_parser("search", help="Search public disease/phenotype names")
    search.add_argument("--query", required=True)
    search.add_argument("--size", type=int, default=20)
    fetch = subparsers.add_parser("fetch", help="Fetch every associated target into a new immutable snapshot")
    fetch.add_argument("--disease-id", required=True)
    fetch.add_argument("--output-dir", type=Path, required=True)
    fetch.add_argument("--page-size", type=int, default=3000)
    for command in (search, fetch):
        command.add_argument("--api-url", default=API_URL, help="GraphQL endpoint (recorded in provenance)")
    args = parser.parse_args(argv)
    try:
        if urlparse(args.api_url).scheme not in ("https", "http"):
            raise ValueError("API URL must use HTTPS or HTTP")
        result = search_diseases(args.query, args.size, args.api_url) if args.command == "search" else fetch_snapshot(
            args.disease_id, args.output_dir, args.page_size, args.api_url)
    except (ValueError, OSError, TypeError, KeyError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
