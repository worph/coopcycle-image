# coopcycle-web image

Production image for the AppStoreLab `CoopCycle` app. Upstream
(`coopcycle/coopcycle-web`) publishes development images only; this builds a
release tag into one image: `vendor/` without dev dependencies, the webpack
assets compiled for production, nginx + php-fpm under supervisord.

Published to `ghcr.io/worph/coopcycle-image` by
`.github/workflows/docker-publish.yml`: a `vX.Y.Z` tag publishes `X.Y.Z`,
`X.Y` and `X`, and every push to `main` publishes `main`. The image version is
this repo's own; the CoopCycle release it builds is `COOPCYCLE_VERSION` in the
Dockerfile (v1.0.0 builds CoopCycle v6.19.0).

```bash
docker build --platform linux/amd64 -t coopcycle-web:dev .
```

amd64 only, because the app's PostGIS dependency is amd64 only.

Roles (the container's command):

- `web` (default): wait for Postgres, create the schema or apply migrations,
  create the S3 buckets, warm the cache, run `coopcycle:setup`, seed the four
  mandatory settings and the admin account when absent, then serve on :80.
- `worker`: `messenger:consume async scheduler_default`, in a loop.

`/usr/local/lib/coopcycle/bootstrap.php set-password <user>` sets a password
from `$COOPCYCLE_ADMIN_PASSWORD`. Upstream's `nucleos:user:change-password`
reports success without saving anything.

State lives in `/data` (`jwt/`, `images/`, `media/`, `logs/`).
