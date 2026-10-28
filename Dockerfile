# CoopCycle web, packaged for a single-box install.
#
# Upstream ships only a development compose (source bind-mounted, webpack dev
# server, composer run at container start). This image bakes a release instead:
# vendor/ installed without dev dependencies, the webpack assets compiled for
# production, and nginx + php-fpm in one container so the app answers HTTP on
# port 80 by itself. The same image runs the messenger worker (`worker` role).

ARG COOPCYCLE_VERSION=v6.19.0

# --- source ------------------------------------------------------------------
# REVISION is how the app names its own version (it maps the commit to a
# release tag); without it the admin bar reads "dev-master".
FROM alpine/git:v2.49.1 AS source
ARG COOPCYCLE_VERSION
RUN git clone --depth 1 --branch "${COOPCYCLE_VERSION}" \
      https://github.com/coopcycle/coopcycle-web.git /src \
 && git -C /src rev-parse HEAD > /src/REVISION \
 && rm -rf /src/.git

# --- PHP runtime, shared by the composer stage and the final image ------------
# Same extension set as upstream's docker/php/Dockerfile, minus xdebug and the
# dev tooling.
FROM php:8.5-fpm-alpine3.23 AS php-base

# opcache is built into PHP 8.5 and is not installed as an extension.
# imagick is built from a pinned git commit, as upstream builds it from git:
# the PECL release lags behind new PHP versions.
ENV APCU_VERSION=5.1.28 \
    PHPREDIS_VERSION=6.3.0 \
    IMAGICK_REF=55ed2e9fda264395636a2e27e51f31673f5566ab

RUN set -xe \
 && apk add --no-cache \
      icu zlib libpng libjpeg-turbo freetype libpq libzip unzip \
      jpegoptim optipng pngquant imagemagick \
      nginx supervisor fcgi openssl git su-exec \
 && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
      icu-dev postgresql-dev zlib-dev libpng-dev libjpeg-turbo-dev \
      freetype-dev libzip-dev imagemagick-dev \
 && docker-php-ext-configure gd --enable-gd \
      --with-freetype=/usr/include/ --with-jpeg=/usr/include/ \
 && docker-php-ext-install intl pdo_pgsql zip bcmath gd pcntl ftp \
 && pecl install apcu-${APCU_VERSION} redis-${PHPREDIS_VERSION} \
 && git init -q /tmp/imagick \
 && git -C /tmp/imagick fetch -q --depth 1 https://github.com/Imagick/imagick.git ${IMAGICK_REF} \
 && git -C /tmp/imagick checkout -q FETCH_HEAD \
 && (cd /tmp/imagick && phpize && ./configure && make -j"$(nproc)" && make install) \
 && docker-php-ext-enable --ini-name 20-apcu.ini apcu \
 && docker-php-ext-enable redis imagick \
 && apk del .build-deps \
 && rm -rf /tmp/pear /tmp/imagick

COPY --from=composer/composer:2.8.12-bin /composer /usr/local/bin/composer

WORKDIR /var/www/html

# --- vendor/ -------------------------------------------------------------------
FROM php-base AS vendor
COPY --from=source /src/composer.json /src/composer.lock ./
# --no-scripts: the auto-scripts boot the kernel, which needs a database
# config; they run in the final stage's entrypoint instead.
RUN COMPOSER_ALLOW_SUPERUSER=1 composer install \
      --prefer-dist --no-progress --no-interaction --no-dev --no-scripts \
 && rm -rf /root/.composer/cache

# --- compiled front-end assets ---------------------------------------------------
# glibc (Debian), not Alpine: upstream builds its release assets on Ubuntu, and
# tailwind's native binding is resolved for linux-x64-gnu.
FROM node:22.21.1-bookworm-slim AS assets
ENV CYPRESS_INSTALL_BINARY=0 \
    NODE_ENV=production
WORKDIR /src
COPY --from=source /src/ ./
# The Symfony UX controllers in assets/controllers.json resolve into vendor/.
COPY --from=vendor /var/www/html/vendor ./vendor
RUN npm ci --include=dev --no-audit --no-fund \
 && npm run sdk:build \
 && node_modules/.bin/encore production \
 && cp web/js/coopcycle.js web/build/ \
 && rm -rf node_modules

# --- final image -------------------------------------------------------------------
FROM php-base

ARG COOPCYCLE_VERSION
ENV APP_ENV=prod \
    APP_DEBUG=0 \
    APP_VERSION=${COOPCYCLE_VERSION} \
    COMPOSER_ALLOW_SUPERUSER=1

COPY --from=source --chown=www-data:www-data /src/ ./
COPY --from=vendor --chown=www-data:www-data /var/www/html/vendor ./vendor
COPY --from=assets --chown=www-data:www-data /src/web/build ./web/build
COPY --from=assets --chown=www-data:www-data /src/web/js ./web/js

# Dev/test-only trees: nothing in prod reads them.
#
# .env.dist becomes .env: Symfony loads it at boot, and it holds the defaults
# for the ~150 variables the config references -- most of them switches for
# integrations a small co-op does not use. Real environment variables win over
# it, so the deployment sets only what it needs, and every secret in it is
# overridden there (APP_SECRET, the OAuth and JWT keys, S3 and Centrifugo).
RUN rm -rf cypress tests features fixtures/ORM/test* storybook* .storybook* \
      js/app/**/__tests__ node_modules \
 && COMPOSER_ALLOW_SUPERUSER=1 composer dump-autoload --no-dev --optimize --no-scripts \
 && cp .env.dist .env \
 && chown www-data:www-data .env

COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/coopcycle-entrypoint /usr/local/bin/coopcycle-healthcheck \
 && rm -f /usr/local/etc/php-fpm.d/www.conf.default \
 && mkdir -p /run/nginx /var/lib/nginx/tmp \
 && chown -R www-data:www-data /var/lib/nginx

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/coopcycle-entrypoint"]
CMD ["web"]
