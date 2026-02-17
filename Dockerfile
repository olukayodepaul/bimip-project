# ---------- Build Stage ----------
FROM hexpm/elixir:1.18.4-erlang-27.7-alpine AS build

RUN apk add --no-cache build-base git bash

WORKDIR /app

# Copy mix files and get deps
COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod

# Copy the rest of the app
COPY . .

# Compile and build escript
RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix escript.build

# ---------- Runtime Stage ----------
FROM alpine:3.18

RUN apk add --no-cache bash openssl ncurses-libs

WORKDIR /app

# Copy compiled escript
COPY --from=build /app/bimips .

# Copy runtime config
COPY --from=build /app/config ./config
COPY --from=build /app/priv ./priv

EXPOSE 4000 4001

ENTRYPOINT ["./bimips"]
CMD ["start"]
