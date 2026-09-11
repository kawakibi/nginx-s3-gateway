# Upstream sync: 2026-09-10

Branch: `chore/sync-upstream-2026-09-10`.

## Integration and remaining fork changes

Merge commit `dda6b4f` joins fork commit `f515da6` with upstream
[`a27035812d9bb7ab2f70266efa815a2635ebd63f`](https://github.com/nginx/nginx-s3-gateway/commit/a27035812d9bb7ab2f70266efa815a2635ebd63f).
Upstream `main` and release `2026-09-10` resolved to that same commit when
fetched. The merge retains both histories and brings in 69 upstream commits.

The merge resolves the four conflicts in `s3gateway.js`, `nginx.conf`,
`default.conf.template`, and `99-output-settings.sh`. It retains upstream's
normalization, signing, credentials, TLS verification, pagination, Docker
images, and Make-based test infrastructure. Subsequent commits contain the
focused dynamic-bucket fixes, tests, and fork CI restrictions separately from
the upstream merge.

- `dda6b4f`: merge the pinned upstream release.
- `f055641`: restrict publishing and Release Drafter to the official repository.
- `fix: preserve dynamic bucket routing across upstream gateway paths`:
  dynamic-bucket fixes, regression tests, and configuration documentation.

The remaining functional differences from the pinned upstream are:

- Optional bucket selection through `ALLOW_DYNAMIC_BUCKET_NAME` and
  `HEADER_DYNAMIC_BUCKET_NAME`, with the default header `X-Bucket-Name`.
  Header lookup is case-insensitive. Custom names such as
  `X-Custom-Bucket-Name` are supported.
- Dynamic mode defaults to disabled, uses upstream's boolean grammar, and
  requires `S3_STYLE=path`. Containers and the standalone installer apply the
  same validation and defaults.
- Signing, object paths, directory listings, and index probes use the selected
  bucket. Loopback probes forward only the configured bucket header.
- Missing or empty bucket headers return HTTP 500 before cache lookup or
  origin access, including direct index requests. Dynamic mode never falls
  back to `S3_BUCKET_NAME`. Health checks and CORS preflight work without the
  bucket header; preflight allows the configured header.
- Responses retain `X-Bucket`, `X-Cache-Status`, and
  `Content-Disposition: inline`.

Cache keys retain the upstream `s3gw-v2` tuple. The effective S3 URI includes
the selected bucket; sliced keys also include the slice byte range. This
separates buckets with identical keys and prevents reuse of pre-upgrade cache
entries. Expect a cold cache after upgrading.

The fork retains upstream lint and test jobs. All image publishing jobs and
Release Drafter require `github.repository == 'nginx/nginx-s3-gateway'`, so
NGINX-specific Azure and registry operations do not run in this fork.

## Validation

Validation used AWS CLI 1.46.1, checkmake 0.3.2, shellcheck 0.11.0, and rumdl 0.2.58.
The checkmake download was checked against its published SHA256 checksum;
rumdl matches the upstream workflow pin.

Commands use the repository's GNU Make interface:

```bash
make build NGINX_TYPE=oss
make test-dynamic-buckets NGINX_TYPE=oss
make ci NGINX_TYPE=oss
```

Validation results:

- `make lint`: passed.
- `make test-dynamic-buckets NGINX_TYPE=oss`: passed.
- `make ci NGINX_TYPE=oss`: interrupted at the user's request because of its
  local runtime. `virtual` and `virtual-v2` passed in full. The `path` entry
  passed unit and startup checks but was stopped during integration setup.
  Latest-njs and unprivileged were not run. The full CI matrix is incomplete.

Custom-header examples and test values were generalized after these runs.
Only lint checks were rerun for that cleanup; the Docker suites were not repeated.

Licensed NGINX Plus execution is skipped because repository certificates and
`license.jwt` are unavailable.

The new RustFS phase uses two non-default buckets containing different bytes
under identical object and index keys. It covers GET, HEAD, MISS then HIT,
1 KiB slices with a range spanning multiple slices, bucket-local 404s,
default and custom headers, missing headers, directory listings, pagination,
index probes, path rewrites, CORS, and SigV2/SigV4. It explicitly selects path
style within every integration leg, including latest-njs and unprivileged.
Ordinary upstream phases explicitly disable dynamic mode.

Unit tests cover static defaults, header lookup and casing, bucket-sensitive
signing and URIs, missing-header guards, and index probe forwarding.
Entrypoint tests cover boolean validation, addressing restrictions, and
displayed defaults. The standalone installer was linted and reviewed for
configuration parity; it was not installed onto the workstation.

## Local comparison

The original baseline remains on `127.0.0.1:18080`; the OSS candidate runs
separately on `127.0.0.1:18081` with a fresh container cache and the current
`.env`. The environment file is unchanged. No registry publishing or
production deployment is part of this update.

| Property | Baseline | Upgraded OSS candidate |
| -------- | -------- | ---------------------- |
| NGINX    | 1.29.4   | 1.31.5                 |
| njs      | 0.9.4    | 1.0.1                  |

Baseline image ID:
`sha256:f3b3aa7c690d823077f67d068f93b0d538550f98ee4924238cb1d0957364f1e0`.

Candidate image ID:
`sha256:655f2cfc268e66ce28046cf3e6fb918fd3edd47c0fd89622b6f361b075163fec`.

Two objects in separate buckets returned HTTP 200, the expected `X-Bucket`, one
`Content-Disposition: inline` header, and cache MISS then HIT. Their downloaded
contents match the pre-upgrade baselines. HEAD requests also returned HTTP 200
with the expected content lengths, bucket headers, and inline disposition:

| Object type |     Bytes | Baseline comparison |
| ----------- | --------: | ------------------- |
| PNG image   | 2,055,159 | SHA256 matched      |
| MP4 video   | 1,388,392 | SHA256 matched      |

The video request for bytes `1048000-1049000` crosses the 1 MiB slice boundary.
It returned HTTP 206 with `Content-Range: bytes 1048000-1049000/1388392` and
1,001 bytes matching the same interval in the full download. Missing bucket
headers on both warmed object paths and a direct index path returned HTTP 500;
`/health` returned HTTP 200. The candidate also passed `nginx -t`.

Deployment-specific bucket names, object keys, headers, container names, and
local artifact paths are omitted from this public report.
