FROM ruby:3.3.1-slim-bookworm AS base

RUN apt update && apt --fix-missing install -y build-essential pkg-config bash curl libpq-dev openssh-client \
     libpq-dev libsqlite3-dev libssl-dev libgeos-dev docker.io jq cmake libjson-c-dev libwebsockets-dev\
     && rm -rf /var/lib/apt/lists/*

RUN echo 'gem: --no-document' >> ~/.gemrc

WORKDIR /app

RUN cd / && git clone https://github.com/tsl0922/ttyd.git # apt-get install -y build-essential cmake git libjson-c-dev libwebsockets-dev
RUN cd /ttyd && mkdir build && cd build && cmake .. && make # COPY /ttyd/build/ttyd, /usr/lib/x86_64-linux-gnu/libuv.so.1

COPY Gemfile* /app/

RUN bundle install --jobs $(nproc) --retry=3 && \
    bundle clean --force && rm -rf /usr/local/bundle/cache/*

FROM ruby:3.3.1-slim-bookworm AS deploy
RUN apt update && apt install --fix-missing -y bash curl libpq-dev openssh-client \
      libssl-dev docker.io jq libwebsockets\
     && rm -rf /var/lib/apt/lists/*

COPY --from=base /usr/local/bundle /usr/local/bundle
COPY --from=base /usr/lib/x86_64-linux-gnu/libuv.so.1 /usr/lib/x86_64-linux-gnu/libuv.so.1
# E: lws_create_context: unable to load evlib plugin evlib_uv
# E: libwebsockets context creation failed
COPY --from=base /ttyd/build/ttyd /usr/local/bin

COPY . /app

ENV SERVER_ENV=production \
    RACK_ENV=production \
    PORT=7000

WORKDIR /app

# --start_period=5s (Unknown flag: start_period)
# HEALTHCHECK --interval=15s --timeout=2s --retries=3 CMD curl --fail http://127.0.0.1:$PORT/healthcheck || exit 1
CMD ls && bundle exec rackup -o 0.0.0.0 -p $PORT -s falcon
# docker-compose build --progress plain