FROM elixir:1.15-alpine

# Install build dependencies
RUN apk add --no-cache build-base git

WORKDIR /app

# Copy mix files
COPY mix.exs mix.lock ./

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install dependencies
RUN mix deps.get

# Copy application files
COPY . .

RUN mkdir -p priv/repo/migrations
COPY priv/repo/migrations/* priv/repo/migrations/

# Compile the application
RUN mix compile

CMD ["mix", "run", "--no-halt"]