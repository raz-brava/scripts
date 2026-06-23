#!/usr/bin/env python3
"""Mirror every object from a customer (Form3) S3 bucket into our own bucket,
which lives in a DIFFERENT AWS account.

Design goals (we expect ~600GB across many objects, so the run is long):

* Source (customer) access uses an assumed cross-account role with
  *auto-refreshing* credentials. A long ListObjectsV2 walk or a slow transfer
  will never fail with `ExpiredToken` because botocore refreshes the STS
  credentials transparently before they expire.
* Destination access uses the pod's NATIVE identity (the default credential
  chain / IRSA) -- a separate session, separate account.
* Objects are streamed source -> destination through the pod with multipart
  upload. Nothing is staged on local disk, so the total volume never needs
  local storage. Each object is the "chunk": read it, upload it, move on.
* The job is resumable/idempotent: an object already present in the
  destination with the same size is skipped, so a re-run continues where an
  interrupted run left off.

Parallelism: work is split across PROCESSES separate OS processes (each with
its own Python interpreter -> its own GIL -> real multi-core scaling), and
within each process WORKERS threads transfer objects concurrently. Total
in-flight transfers = PROCESSES * WORKERS. The leaf date-prefixes are
enumerated once and round-robin sharded across the processes, so each process
also lists its own share (parallel listing, no single producer bottleneck).

Every value is a flag (see `--help`). The identity/selection values (buckets,
regions, prefixes, the cross-account role, and the date window) have NO
defaults and MUST be passed explicitly, so a run can never silently target the
wrong bucket, account, or date range. Only the parallelism/tuning knobs keep
sensible defaults.
"""
import argparse
import multiprocessing as mp
import sys
import threading
from concurrent.futures import (
    ProcessPoolExecutor,
    ThreadPoolExecutor,
    as_completed,
)
from datetime import date, datetime, timedelta

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.config import Config
from botocore.credentials import RefreshableCredentials
from botocore.exceptions import ClientError
from botocore.session import get_session

# --- Tuning defaults ---
#
# Only the parallelism / multipart knobs below carry defaults. The
# identity/selection values (buckets, regions, prefixes, the cross-account role,
# and the date window) have NO defaults and are required flags -- see
# parse_args -- so a run can never silently target the wrong place.

# Parallelism. Separate OS processes escape the GIL and use multiple cores; keep
# PROCESSES at/under the pod's CPU limit. Concurrent transfers = PROCESSES * WORKERS.
DEFAULT_PROCESSES = 6
DEFAULT_WORKERS = 16

# Per-object multipart streaming. Big objects are split into parts; small ones
# upload in one shot. Peak memory ~= WORKERS * MULTIPART_CONCURRENCY * chunksize.
DEFAULT_MULTIPART_THRESHOLD = 16 * 1024 * 1024  # 16 MB
DEFAULT_MULTIPART_CHUNKSIZE = 8 * 1024 * 1024  # 8 MB
DEFAULT_MULTIPART_CONCURRENCY = 2


def days(start, end):
    d = start
    while d <= end:
        yield d
        d += timedelta(days=1)


def make_boto_config(workers):
    # Size the HTTP connection pool to the thread count, otherwise threads queue
    # on boto3's default pool of 10 and extra workers do nothing. Headroom is
    # added for multipart part-uploads which each grab their own connection.
    return Config(
        retries={"max_attempts": 10, "mode": "adaptive"},
        max_pool_connections=max(10, workers * 2),
    )


def assume_role_session(role_arn, session_name, region, external_id, boto_config):
    """A boto3 Session whose credentials auto-refresh by re-calling AssumeRole.

    The base STS client uses the pod's native identity to assume the
    cross-account role; RefreshableCredentials re-runs `refresh()` shortly
    before expiry, so arbitrarily long operations never see ExpiredToken.
    """
    sts = boto3.client("sts", config=boto_config)

    def refresh():
        params = {"RoleArn": role_arn, "RoleSessionName": session_name}
        if external_id:
            params["ExternalId"] = external_id
        creds = sts.assume_role(**params)["Credentials"]
        return {
            "access_key": creds["AccessKeyId"],
            "secret_key": creds["SecretAccessKey"],
            "token": creds["SessionToken"],
            "expiry_time": creds["Expiration"].isoformat(),
        }

    refreshable = RefreshableCredentials.create_from_metadata(
        metadata=refresh(),
        refresh_using=refresh,
        method="sts-assume-role",
    )
    botocore_session = get_session()
    botocore_session._credentials = refreshable
    botocore_session.set_config_variable("region", region)
    return boto3.Session(botocore_session=botocore_session)


class Mirror:
    """Owns one process's S3 clients and transfer state. Clients are created
    here (after any fork/spawn) -- never share boto3 clients across processes."""

    def __init__(self, args):
        self.args = args
        boto_config = make_boto_config(args.workers)
        # Source: assumed-role, refreshable. Destination: native pod identity.
        self.src = assume_role_session(
            args.src_role_arn, args.src_session_name, args.src_region,
            args.src_external_id, boto_config,
        ).client("s3", region_name=args.src_region, config=boto_config)
        self.dst = boto3.client("s3", region_name=args.dst_region, config=boto_config)

        self.transfer = TransferConfig(
            multipart_threshold=args.multipart_threshold,
            multipart_chunksize=args.multipart_chunksize,
            max_concurrency=args.multipart_concurrency,
            use_threads=True,
        )

        self._lock = threading.Lock()
        self.copied = self.skipped = self.errored = 0
        self.bytes_copied = 0

    def _dst_key(self, key):
        return f"{self.args.dst_prefix}{key}"

    def _already_mirrored(self, key, size):
        """True if the destination already holds this object at the same size."""
        try:
            head = self.dst.head_object(Bucket=self.args.dst_bucket, Key=self._dst_key(key))
        except ClientError as e:
            if e.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
                return False
            raise
        return head["ContentLength"] == size

    def _mirror_one(self, key, size):
        if not self.args.no_skip_check and self._already_mirrored(key, size):
            with self._lock:
                self.skipped += 1
            return

        if self.args.dry_run:
            with self._lock:
                self.copied += 1
                self.bytes_copied += size
            print(f"[dry-run] would copy {key} ({size} bytes)")
            return

        # Stream straight from source to destination -- no local disk.
        body = self.src.get_object(Bucket=self.args.src_bucket, Key=key)["Body"]
        try:
            self.dst.upload_fileobj(
                body, self.args.dst_bucket, self._dst_key(key), Config=self.transfer
            )
        finally:
            body.close()

        with self._lock:
            self.copied += 1
            self.bytes_copied += size
            if self.copied % 500 == 0:  # periodic per-process heartbeat
                print(f"[progress] copied={self.copied} "
                      f"bytes={self.bytes_copied / 1e9:.2f}GB")

    # --- listing ---

    def _children(self, prefix):
        """Immediate "subfolders" of prefix (one delimiter level)."""
        paginator = self.src.get_paginator("list_objects_v2")
        for page in paginator.paginate(
            Bucket=self.args.src_bucket, Prefix=prefix, Delimiter="/"
        ):
            for cp in page.get("CommonPrefixes", []):
                yield cp["Prefix"]

    def enumerate_leaf_prefixes(self):
        """All <src_prefix><YYYY>/<MM>/<DD>/<HH>/ prefixes in the date window.
        VPC flow logs are <src-prefix><YYYY>/<MM>/<DD>/<HH>/<file>.gz, so we list
        the hour subfolders of each wanted day. Cheap (CommonPrefixes only), and
        the many hour-level leaves shard nicely across processes for parallel
        listing."""
        leaves = []
        for d in days(self.args.start_date, self.args.end_date):
            day_prefix = f"{self.args.src_prefix}{d.year:04d}/{d.month:02d}/{d.day:02d}/"
            leaves.extend(self._children(day_prefix))  # <src-prefix><Y>/<M>/<D>/<HH>/
        return leaves

    def _objects_under(self, prefixes):
        paginator = self.src.get_paginator("list_objects_v2")
        for prefix in prefixes:
            for page in paginator.paginate(Bucket=self.args.src_bucket, Prefix=prefix):
                for obj in page.get("Contents", []):
                    key = obj["Key"]
                    if any(s in key for s in self.args.exclude):
                        with self._lock:
                            self.skipped += 1
                        continue
                    yield key, obj["Size"]

    # --- transfer ---

    def mirror_prefixes(self, prefixes):
        """List objects under the given prefixes and transfer them with a thread
        pool. Returns (copied, skipped, errored, bytes_copied) for this process."""
        with ThreadPoolExecutor(max_workers=self.args.workers) as pool:
            # Bound in-flight futures so we don't materialize every key at once.
            inflight = set()
            for key, size in self._objects_under(prefixes):
                inflight.add(pool.submit(self._submit, key, size))
                if len(inflight) >= self.args.workers * 4:
                    done = next(as_completed(inflight))
                    inflight.discard(done)
            for _ in as_completed(inflight):
                pass
        return (self.copied, self.skipped, self.errored, self.bytes_copied)

    def _submit(self, key, size):
        # Per-object error isolation: one bad object must not abort the run.
        try:
            self._mirror_one(key, size)
        except Exception as e:  # noqa: BLE001 - log and keep going
            with self._lock:
                self.errored += 1
            print(f"[error] {key}: {e}", file=sys.stderr)


def _run_shard(args, prefixes):
    """Process entrypoint: build fresh clients in this process and mirror the
    assigned shard of prefixes. Must be module-level so it is picklable."""
    return Mirror(args).mirror_prefixes(prefixes)


def _parse_date(s):
    try:
        return datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        raise argparse.ArgumentTypeError(f"invalid date '{s}', expected YYYY-MM-DD")


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )

    # Identity/selection: NO defaults -- every one is required so a run can never
    # silently target the wrong bucket, account, prefix, or date range.
    src = p.add_argument_group("source (customer bucket, assumed cross-account role) -- all required")
    src.add_argument("--src-bucket", required=True)
    src.add_argument("--src-region", required=True)
    src.add_argument("--src-prefix", required=True)
    src.add_argument("--src-role-arn", required=True)
    src.add_argument("--src-session-name", required=True,
                     help="RoleSessionName for the AssumeRole call")
    src.add_argument("--src-external-id", required=True,
                     help="ExternalId for AssumeRole; pass an empty string ('') to omit it")

    dst = p.add_argument_group("destination (our bucket, native pod identity) -- all required")
    dst.add_argument("--dst-bucket", required=True)
    dst.add_argument("--dst-region", required=True)
    dst.add_argument("--dst-prefix", required=True)

    sel = p.add_argument_group("selection")
    sel.add_argument("--start-date", type=_parse_date, required=True,
                     help="inclusive window start, YYYY-MM-DD (required)")
    sel.add_argument("--end-date", type=_parse_date, required=True,
                     help="inclusive window end, YYYY-MM-DD (required)")
    sel.add_argument("--exclude", action="append", metavar="SUBSTRING",
                     help="skip keys containing this substring; repeatable "
                          "(optional, no default -- nothing is excluded unless given)")

    par = p.add_argument_group("parallelism / tuning")
    par.add_argument("--processes", type=int, default=DEFAULT_PROCESSES,
                     help="parallel OS processes (escape the GIL, use multiple cores)")
    par.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                     help="transfer threads per process")
    par.add_argument("--multipart-threshold", type=int, default=DEFAULT_MULTIPART_THRESHOLD,
                     help="bytes above which an object is uploaded multipart")
    par.add_argument("--multipart-chunksize", type=int, default=DEFAULT_MULTIPART_CHUNKSIZE,
                     help="multipart part size in bytes")
    par.add_argument("--multipart-concurrency", type=int, default=DEFAULT_MULTIPART_CONCURRENCY,
                     help="concurrent parts per object")

    beh = p.add_argument_group("behaviour")
    beh.add_argument("--no-skip-check", action="store_true",
                     help="skip the per-object HeadObject existence check (faster on a "
                          "known-empty destination; loses resume-skip)")
    beh.add_argument("--dry-run", action="store_true", help="list and report, copy nothing")

    args = p.parse_args(argv)

    if args.exclude is None:
        args.exclude = []
    if args.start_date > args.end_date:
        p.error(f"--start-date ({args.start_date}) is after --end-date ({args.end_date})")
    return args


def main(argv=None):
    args = parse_args(argv)

    # Enumerate the leaf date-prefixes once, then shard them across processes.
    prefixes = Mirror(args).enumerate_leaf_prefixes()
    if not prefixes:
        print("no matching prefixes in date window -- nothing to do")
        return 0

    nproc = max(1, args.processes)
    shards = [prefixes[i::nproc] for i in range(nproc)]
    shards = [s for s in shards if s]
    print(
        f"{len(prefixes)} leaf prefixes -> {len(shards)} processes x "
        f"{args.workers} threads ({len(shards) * args.workers} concurrent transfers)"
    )

    if len(shards) == 1:
        # Single shard: run inline, no process pool overhead.
        copied, skipped, errored, bytes_copied = _run_shard(args, shards[0])
    else:
        copied = skipped = errored = bytes_copied = 0
        ctx = mp.get_context("spawn")  # spawn -> clean interpreter, fork-safe with boto3/ssl
        with ProcessPoolExecutor(max_workers=len(shards), mp_context=ctx) as pool:
            futures = [pool.submit(_run_shard, args, shard) for shard in shards]
            for f in as_completed(futures):
                c, s, e, b = f.result()
                copied += c
                skipped += s
                errored += e
                bytes_copied += b

    print(
        f"\ndone: copied={copied} skipped={skipped} errored={errored} "
        f"bytes={bytes_copied} ({bytes_copied / 1e9:.2f} GB)"
    )
    return 1 if errored else 0


if __name__ == "__main__":
    sys.exit(main())
