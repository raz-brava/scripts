# s3-batch-copy

Tools for copying objects between S3 buckets. Two complementary approaches:

| Script | Use it when |
|--------|-------------|
| [`s3-batch-copy.sh`](#s3-batch-copysh) | Source and destination are in the **same account** — let AWS do the work server-side via an S3 Batch Operations job. |
| [`s3-cross-account-mirror.py`](#s3-cross-account-mirrorpy) | Source is in **another account** (assumed cross-account role) and you want to stream objects through your own process with resume/idempotency. |

Both are standalone executables: run them directly, no `source` required.

## s3-batch-copy.sh

A wrapper around `aws s3control create-job` that kicks off an
**S3 Batch Operations** job to copy objects from one bucket to another. The
manifest is generated on the fly by AWS (`S3JobManifestGenerator`) and filtered
by one or more key prefixes — no need to build a manifest CSV yourself.

By design there are **no defaults** — every value must be passed explicitly,
and confirmation behaviour must be chosen on each run. This prevents unintended
mistakes such as copying into the wrong bucket or account. If anything is
missing the script lists exactly what and exits without calling AWS.

It's already executable — run it from this folder (`./s3-batch-copy.sh --help`)
or symlink it onto your `PATH` (`ln -s "$PWD/s3-batch-copy.sh" ~/bin/s3-batch-copy`).

### Usage

```
s3-batch-copy.sh [options]

Required:
  --region REGION           AWS region
  --account-id ID           AWS account id
  --source-bucket NAME      Bucket to copy objects FROM
  --target-bucket NAME      Bucket to copy objects TO
  --prefix PREFIX           Key prefix to include; repeatable, at least one required
  --priority N              Job priority
  --role-arn ARN            IAM role ARN for the job
                            (or pass --role-name to derive it; one is required)
  --role-name NAME          IAM role name; derives arn:aws:iam::<account-id>:role/<name>

Confirmation (one is required):
  --confirm                 Create the job paused; confirm it in the S3 console first
  --no-confirm              Start the job immediately (--no-confirmation-required)

Optional:
  --report                  Enable a completion report (requires --report-bucket)
  --report-bucket NAME      Bucket to write the completion report to
  --dry-run                 Print the aws command instead of running it
  -h, --help                Show help
```

#### Examples

Preview the command for a copy without running it:

```sh
./s3-batch-copy.sh \
  --region eu-central-1 --account-id 123456789012 \
  --source-bucket my-src --target-bucket my-dst \
  --prefix logs/ --prefix data/ \
  --priority 10 --role-name S3BatchCopyRole \
  --confirm --dry-run
```

With a completion report, started immediately (no console confirmation):

```sh
./s3-batch-copy.sh \
  --region eu-central-1 --account-id 123456789012 \
  --source-bucket my-src --target-bucket my-dst \
  --prefix data/ --priority 10 --role-name S3BatchCopyRole \
  --report --report-bucket my-reports --no-confirm
```

#### Notes

- There are **no defaults**: every required flag above must be supplied, and you
  must pick either `--confirm` (review and start from the S3 console) or
  `--no-confirm` (start immediately) on each run.
- The IAM role must already exist and have permission to read the source bucket
  and write the target bucket. See the
  [AWS docs on Batch Operations IAM roles](https://docs.aws.amazon.com/AmazonS3/latest/userguide/batch-ops-iam-role-policies.html).
- Use `--dry-run` first when changing buckets or prefixes — it prints the exact
  `aws` command so you can eyeball it before anything runs.

**Requirements:** AWS CLI v2 configured for the target account; permission to
call `s3control:CreateJob` and to pass the batch-copy role.

## s3-cross-account-mirror.py

Streams every object from a **source bucket in another AWS account** into a
destination bucket, through the running process — nothing is staged on local
disk. Built for long, large transfers (hundreds of GB):

- **Auto-refreshing cross-account credentials** — the source is read via an
  assumed role whose STS credentials refresh transparently before expiry, so a
  multi-hour list/transfer never dies with `ExpiredToken`. The destination is
  written with the process's own native identity (default credential chain /
  IRSA) — a separate session in a separate account.
- **Resumable / idempotent** — an object already present at the destination
  with the same size is skipped, so a re-run continues where it left off
  (`--no-skip-check` disables this for a known-empty destination).
- **Parallel** — work fans out across `--processes` OS processes (real
  multi-core, each lists its own shard) and `--workers` threads each; total
  in-flight transfers = processes × workers. Per-object multipart streaming is
  tunable via the `--multipart-*` flags.
- **Date-windowed** — it enumerates only the hour-level prefixes
  (`<src-prefix><YYYY>/<MM>/<DD>/<HH>/`) inside `--start-date`..`--end-date`,
  so irrelevant dates are never listed.

By design the **identity/selection values have no defaults** — the source and
destination buckets/regions/prefixes, the cross-account role, and the date
window must all be passed explicitly, so a run can never silently target the
wrong bucket, account, or date range. Only the parallelism/tuning knobs keep
sensible defaults. Run `./s3-cross-account-mirror.py --help` for the full list.
Key flags:

```
  source (assumed cross-account role) — all required
  --src-bucket / --src-region / --src-prefix
  --src-role-arn            role to assume for read access
  --src-session-name        RoleSessionName for the AssumeRole call
  --src-external-id         ExternalId for AssumeRole (pass '' to omit)

  destination (native identity) — all required
  --dst-bucket / --dst-region / --dst-prefix

  selection
  --start-date / --end-date YYYY-MM-DD, inclusive window (required)
  --exclude SUBSTRING       skip keys containing this substring; repeatable
                            (optional, nothing excluded unless given)

  parallelism / tuning (have defaults)
  --processes / --workers
  --multipart-threshold / --multipart-chunksize / --multipart-concurrency

  behaviour
  --no-skip-check           skip the per-object HeadObject existence check
  --dry-run                 list and report, copy nothing
```

### Examples

Dry-run a window to see what would be copied (everything required is supplied):

```sh
./s3-cross-account-mirror.py \
  --src-bucket their-logs --src-region eu-west-2 --src-prefix api-vpc/ \
  --src-role-arn arn:aws:iam::111122223333:role/reader \
  --src-session-name mirror-run --src-external-id '' \
  --dst-bucket my-archive --dst-region eu-central-1 --dst-prefix vpc/ \
  --start-date 2026-01-01 --end-date 2026-01-31 \
  --dry-run
```

The same window for real, with an exclude and more parallelism:

```sh
./s3-cross-account-mirror.py \
  --src-bucket their-logs --src-region eu-west-2 --src-prefix api-vpc/ \
  --src-role-arn arn:aws:iam::111122223333:role/reader \
  --src-session-name mirror-run --src-external-id '' \
  --dst-bucket my-archive --dst-region eu-central-1 --dst-prefix incoming/ \
  --start-date 2026-01-01 --end-date 2026-01-31 \
  --exclude CloudTrail-Digest --exclude .tmp \
  --processes 8 --workers 24
```

**Requirements:** Python 3 with `boto3`; native credentials able to assume the
source role and write the destination bucket. Keep `--processes` at or under the
pod/host CPU limit.
