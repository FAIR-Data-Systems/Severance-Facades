# ── Build stage ───────────────────────────────────────────────────────────────
# Alpine keeps this as thin as the public images get. build-base is only
# needed here to compile the json gem's native extension; it never reaches
# the runtime stage.
FROM ruby:3.2-alpine AS builder

WORKDIR /app

RUN apk add --no-cache build-base

# Gem layer cached separately so a code-only change skips re-bundling.
# BUNDLE_WITHOUT=test keeps rspec/rack-test out of the shipped image.
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without 'test' && \
    bundle install --jobs 4 --retry 3


# ── Runtime stage ─────────────────────────────────────────────────────────────
# No build tools, no volume to chown at startup (unlike Severance's own
# containers) -- so no privileged setup step, no entrypoint script, and the
# app can run as the non-root user from the very first line.
FROM ruby:3.2-alpine

RUN addgroup -S beacon && \
    adduser -S -G beacon -h /app -s /sbin/nologin beacon

WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle

# `bundle exec` needs the Gemfile itself present at runtime (to resolve/activate the already-vendored
# gems above), not just the vendored gems -- confirmed live: omitting this fails every run with
# "Could not locate Gemfile", even though /usr/local/bundle has everything bundle install put there.
# (Found while building this facade's own docker-compose.yml and actually running the image for the
# first time -- the README's "Known gaps" note about this build being unverified was accurate.)
COPY --chown=beacon:beacon Gemfile Gemfile.lock VERSION app.rb config.ru ./
COPY --chown=beacon:beacon lib/ ./lib/

# net-imap ships as a Ruby "default gem" baked into this base image at whatever version that Ruby
# patch release bundled (0.3.9 here) -- pinning a newer version in the Gemfile (unused by this app;
# pulled in purely to get a patched version) installs it alongside the old one rather than replacing
# it, since Bundler and RubyGems' own default-gem installation use different paths. The stale,
# vulnerable default copy still sits on disk either way; remove it explicitly so it isn't there at
# all. Same fix as Severance's external/internal/shallot-facade Dockerfiles; must run before USER
# drops root below, since removing a system gem needs write access to /usr/local/lib/ruby/gems.
RUN gem uninstall -i /usr/local/lib/ruby/gems/3.2.0 net-imap --all --force || true

# Not just documentation -- GET /info reads this same file at runtime
# (see app.rb) so the running version is queryable, not just labeled.
ARG BEACON_FACADE_VERSION
LABEL org.opencontainers.image.title="beacon-facade" \
      org.opencontainers.image.version="${BEACON_FACADE_VERSION}" \
      org.opencontainers.image.description="Beacon v2-shaped facade for CARE-SM-2 over Severance"

USER beacon

# 4567 is just the documented default -- both app.rb and the shell-form CMD
# below read BEACON_PORT/BEACON_BIND from the environment at runtime, so
# `docker run -e BEACON_PORT=...` (or docker-compose environment:)
# overrides it. BEACON_-prefixed so it can't collide with unrelated env
# vars on a host that also runs Severance (or anything else) alongside
# this facade. EXPOSE only documents the default; it doesn't restrict
# whatever port is actually bound.
ENV BEACON_PORT=4567 BEACON_BIND=0.0.0.0
EXPOSE 4567

CMD ["sh", "-c", "bundle exec rackup -o ${BEACON_BIND} -p ${BEACON_PORT}"]
