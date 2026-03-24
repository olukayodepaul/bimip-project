# ---------- Build Stage ----------
FROM elixir:1.18.4-alpine AS build

# Install build dependencies
RUN apk add --no-cache git build-base curl bash npm

# Set working directory
WORKDIR /app

# Copy project files
COPY mix.exs mix.lock ./
COPY config config
COPY lib lib
COPY priv priv

# Install Hex, Rebar, dependencies
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod && \
    mix deps.compile

# Compile the project and build release
RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix release

# ---------- Runtime Stage ----------
FROM alpine:3.18 AS app

# Install runtime dependencies including C++ libraries for Beam
RUN apk add --no-cache \
    bash \
    openssl \
    ncurses-libs \
    libgcc \
    libstdc++

WORKDIR /app

# Copy release from build stage
COPY --from=build /app/_build/prod/rel/bimips ./

# Expose application ports
EXPOSE 4000 4001

# Start the release
ENTRYPOINT ["bin/bimips"]
CMD ["start"]
