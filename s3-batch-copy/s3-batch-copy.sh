#!/usr/bin/env bash
#
# s3-batch-copy — create an S3 Batch Operations job that copies objects from a
# source bucket into a target bucket, using a generated manifest filtered by
# one or more key prefixes.
#
# This is a thin wrapper around `aws s3control create-job` with the
# S3PutObjectCopy operation and an S3JobManifestGenerator.
#
# By design there are NO defaults: every value (account, region, buckets,
# prefixes, role, priority) must be passed explicitly. This prevents
# unintended mistakes such as copying into the wrong bucket or account.
#
# Standalone executable — run it directly, no need to source.

set -euo pipefail

# --- configuration (all set via flags; no defaults) ---
REGION=""
ACCOUNT_ID=""
SOURCE_BUCKET=""
TARGET_BUCKET=""
PRIORITY=""
ROLE_ARN=""
ROLE_NAME=""
PREFIXES=()                              # one or more --prefix; at least one required
ENABLE_REPORT=false
REPORT_BUCKET=""                         # required when --report is set
CONFIRM=""                               # must be set true/false via --confirm / --no-confirm
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: s3-batch-copy.sh [options]

Creates an S3 Batch Operations copy job (aws s3control create-job).

There are NO defaults — every value below is required (except where noted)
so that nothing is ever assumed. This prevents unintended mistakes such as
copying into the wrong bucket or account.

Required options:
  --region REGION           AWS region
  --account-id ID           AWS account id
  --source-bucket NAME      Bucket to copy objects FROM
  --target-bucket NAME      Bucket to copy objects TO
  --prefix PREFIX           Key prefix to include; repeatable, at least one required
  --priority N              Job priority
  --role-arn ARN | --role-name NAME
                            IAM role for the job. Pass the full ARN, or a name
                            from which the ARN is derived as
                            arn:aws:iam::<account-id>:role/<name>. One is required.

Confirmation (one is required):
  --confirm                 Create the job paused; confirm it in the S3 console
                            before it runs (--confirmation-required)
  --no-confirm              Start the job immediately (--no-confirmation-required)

Optional:
  --report                  Enable a completion report (requires --report-bucket)
  --report-bucket NAME      Bucket to write the completion report to
  --dry-run                 Print the aws command instead of running it
  -h, --help                Show this help

Example:
  ./s3-batch-copy.sh \
    --region eu-central-1 --account-id 123456789012 \
    --source-bucket my-src --target-bucket my-dst \
    --prefix logs/ --prefix data/ \
    --priority 10 --role-name S3BatchCopyRole \
    --confirm --dry-run
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)        REGION="$2"; shift 2 ;;
    --account-id)    ACCOUNT_ID="$2"; shift 2 ;;
    --source-bucket) SOURCE_BUCKET="$2"; shift 2 ;;
    --target-bucket) TARGET_BUCKET="$2"; shift 2 ;;
    --prefix)        PREFIXES+=("$2"); shift 2 ;;
    --priority)      PRIORITY="$2"; shift 2 ;;
    --role-arn)      ROLE_ARN="$2"; shift 2 ;;
    --role-name)     ROLE_NAME="$2"; shift 2 ;;
    --report)        ENABLE_REPORT=true; shift ;;
    --report-bucket) REPORT_BUCKET="$2"; shift 2 ;;
    --confirm)       CONFIRM=true; shift ;;
    --no-confirm)    CONFIRM=false; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "s3-batch-copy: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# Collect every missing required value and report them all at once.
missing=()
[[ -z "$REGION" ]]        && missing+=("--region")
[[ -z "$ACCOUNT_ID" ]]    && missing+=("--account-id")
[[ -z "$SOURCE_BUCKET" ]] && missing+=("--source-bucket")
[[ -z "$TARGET_BUCKET" ]] && missing+=("--target-bucket")
[[ -z "$PRIORITY" ]]      && missing+=("--priority")
[[ ${#PREFIXES[@]} -eq 0 ]]                 && missing+=("--prefix")
[[ -z "$ROLE_ARN" && -z "$ROLE_NAME" ]]     && missing+=("--role-arn|--role-name")
[[ -z "$CONFIRM" ]]                         && missing+=("--confirm|--no-confirm")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "s3-batch-copy: missing required option(s): ${missing[*]}" >&2
  echo "Run with --help for usage." >&2
  exit 2
fi

# Derive the role ARN from the name if the full ARN wasn't given.
if [[ -z "$ROLE_ARN" ]]; then
  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
fi

# Build the MatchAnyPrefix JSON array: ["a/","b/"].
prefix_json=""
for p in "${PREFIXES[@]}"; do
  [[ -n "$prefix_json" ]] && prefix_json+=", "
  prefix_json+="\"${p}\""
done
prefix_json="[${prefix_json}]"

# Build the report JSON.
if [[ "$ENABLE_REPORT" == true ]]; then
  if [[ -z "$REPORT_BUCKET" ]]; then
    echo "s3-batch-copy: --report requires --report-bucket" >&2
    exit 2
  fi
  report_json="{ \"Enabled\": true, \"Bucket\": \"arn:aws:s3:::${REPORT_BUCKET}\", \"Format\": \"Report_CSV_20180820\", \"ReportScope\": \"AllTasks\" }"
else
  report_json='{ "Enabled": false }'
fi

# --confirmation-required creates the job paused (confirm in the console first);
# --no-confirmation-required starts it immediately.
if [[ "$CONFIRM" == true ]]; then
  confirm_flag="--confirmation-required"
else
  confirm_flag="--no-confirmation-required"
fi

operation_json="{
      \"S3PutObjectCopy\": {
        \"TargetResource\": \"arn:aws:s3:::${TARGET_BUCKET}\"
      }
    }"

manifest_json="{
      \"S3JobManifestGenerator\": {
        \"ExpectedBucketOwner\": \"${ACCOUNT_ID}\",
        \"SourceBucket\": \"arn:aws:s3:::${SOURCE_BUCKET}\",
        \"EnableManifestOutput\": false,
        \"Filter\": { \"KeyNameConstraint\": { \"MatchAnyPrefix\": ${prefix_json} } }
      }
    }"

cmd=(aws s3control create-job
  --region "$REGION"
  --account-id "$ACCOUNT_ID"
  "$confirm_flag"
  --priority "$PRIORITY"
  --role-arn "$ROLE_ARN"
  --operation "$operation_json"
  --manifest-generator "$manifest_json"
  --report "$report_json")

if [[ "$DRY_RUN" == true ]]; then
  printf '%q ' "${cmd[@]}"
  printf '\n'
  exit 0
fi

"${cmd[@]}"
