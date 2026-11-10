#!/usr/bin/env python3
"""Generate a SLSA v1.0 provenance document for a gardenlinux/container-* build.

Usage:
  python3 generate-provenance.py \
    --app APP \
    --version VERSION \
    --image-digest sha256:... \       # repeat for multi-image
    --image-name ghcr.io/... \        # repeat, paired with --image-digest
    --sbom-dir sbom/ \
    --log-zip /tmp/build-logs-RUN_ID.zip \
    --output /tmp/provenance.json

Environment variables consumed (all set by GitHub Actions):
  GITHUB_REPOSITORY, GITHUB_REF, GITHUB_SHA,
  GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_EVENT_NAME,
  GITHUB_ACTOR_ID, GITHUB_SERVER_URL
"""
import argparse, glob, hashlib, json, os, sys
from datetime import datetime, timezone


def sha256file(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--image-name", action="append", dest="image_names", default=[])
    ap.add_argument("--image-digest", action="append", dest="image_digests", default=[])
    ap.add_argument("--sbom-dir", required=True)
    ap.add_argument("--log-zip", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    if len(args.image_names) != len(args.image_digests):
        sys.exit("--image-name and --image-digest must be paired")

    repo       = os.environ["GITHUB_REPOSITORY"]
    ref        = os.environ["GITHUB_REF"]
    sha        = os.environ["GITHUB_SHA"]
    run_id     = os.environ["GITHUB_RUN_ID"]
    run_attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "1")
    event      = os.environ["GITHUB_EVENT_NAME"]
    actor_id   = os.environ.get("GITHUB_ACTOR_ID", "")
    server_url = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    started_on = os.environ.get("GITHUB_EVENT_HEAD_COMMIT_TIMESTAMP", "")

    subjects = []

    # Container images
    for name, digest in zip(args.image_names, args.image_digests):
        subjects.append({
            "name": name,
            "digest": {"sha256": digest.removeprefix("sha256:")}
        })

    # SBOM files
    for path in sorted(glob.glob(os.path.join(args.sbom_dir, "*.cdx.json"))):
        subjects.append({
            "name": os.path.basename(path),
            "digest": {"sha256": sha256file(path)}
        })

    # Build logs
    subjects.append({
        "name": os.path.basename(args.log_zip),
        "digest": {"sha256": sha256file(args.log_zip)}
    })

    provenance = {
        "_type": "https://in-toto.io/Statement/v1",
        "predicateType": "https://slsa.dev/provenance/v1",
        "subject": subjects,
        "predicate": {
            "buildDefinition": {
                "buildType": "https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1",
                "externalParameters": {
                    "inputs": {"version": args.version},
                    "workflow": {
                        "ref": ref,
                        "repository": f"https://github.com/{repo}",
                        "path": f".github/workflows/build-{args.app}-fips.yml"
                    }
                },
                "internalParameters": {
                    "github": {
                        "actor_id": actor_id,
                        "event_name": event
                    }
                },
                "resolvedDependencies": [
                    {
                        "uri": f"git+https://github.com/{repo}@{ref}",
                        "digest": {"gitCommit": sha}
                    }
                ]
            },
            "runDetails": {
                "builder": {
                    "id": f"{server_url}/{repo}/.github/workflows/build-{args.app}-fips.yml@{ref}"
                },
                "metadata": {
                    "invocationId": f"{server_url}/{repo}/actions/runs/{run_id}/attempts/{run_attempt}",
                    "startedOn": started_on,
                    "finishedOn": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                }
            }
        }
    }

    with open(args.output, "w") as f:
        json.dump(provenance, f, indent=2)
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
