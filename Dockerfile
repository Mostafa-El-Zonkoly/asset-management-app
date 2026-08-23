# syntax = docker/dockerfile:1

# Production Dockerfile for deploying the Portfolio App on Render (https://render.com).
# Render builds this automatically from render.yaml. To build by hand:
#   docker build -t portfolio-app .
# Assets are precompiled at build time; the database is prepared at boot
# (see bin/docker-entrypoint).

# Make sure RUBY_VERSION matches your target Ruby.
ARG RUBY_VERSION=3.3.4
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages (libpq5 for PostgreSQL, libvips for Active Storage images)
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libpq5 libvips && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    RAILS_SERVE_STATIC_FILES="true" \
    RAILS_LOG_TO_STDOUT="true"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Copy application code
COPY . .

# Make binstubs executable regardless of the checked-out file modes, then
# precompile bootsnap code and assets.
RUN chmod +x ./bin/* && \
    bundle exec bootsnap precompile app/ lib/

# Precompile assets for production without needing RAILS_MASTER_KEY / secrets.
# (tailwindcss-rails builds the stylesheet as part of assets:precompile.)
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Final stage for app image
FROM base

# Copy built artifacts: gems, application
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Ensure binstubs are executable in the final image, create a non-root user,
# and give it ownership of the runtime-writable directories.
RUN chmod +x ./bin/* && \
    groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

# Entrypoint runs db:prepare before booting the server (see bin/docker-entrypoint).
ENTRYPOINT ["bash", "bin/docker-entrypoint"]

# Render provides $PORT; Puma reads it via config/puma.rb.
EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
