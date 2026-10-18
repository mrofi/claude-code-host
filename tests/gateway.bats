#!/usr/bin/env bats
# health.js: health answer on /, and the optional /code proxy to code-server (a stub upstream here).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export PORT=$((20000 + RANDOM % 5000))
  UP=$((26000 + RANDOM % 5000))
  # Stub upstream: echoes the path it received, and answers WebSocket upgrades with 101.
  node -e '
    const http=require("http");
    const s=http.createServer((q,r)=>{r.end("upstream:"+q.url)});
    s.on("upgrade",(q,so)=>{so.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\npath:"+q.url);so.end()});
    s.listen('"$UP"',"127.0.0.1")' &
  echo $! > "$BATS_TEST_TMPDIR/up.pid"
}
teardown() {
  kill "$(cat "$BATS_TEST_TMPDIR/up.pid")" 2>/dev/null || true
  [[ -n "${gw:-}" ]] && kill "$gw" 2>/dev/null || true
}
start() { node "$BATS_TEST_DIRNAME/../scripts/health.js" >/dev/null & gw=$!; for _ in $(seq 30); do curl -s -o /dev/null "localhost:$PORT/" && return; sleep 0.1; done; }

@test "/ answers ok, with or without code-server" {
  start
  [ "$(curl -s localhost:$PORT/)" = "ok" ]
  [ "$(curl -s localhost:$PORT/anything)" = "ok" ]
}

@test "/code is a 404 when code-server is not enabled" {
  start
  [ "$(curl -s -o /dev/null -w '%{http_code}' localhost:$PORT/code/)" = "404" ]
}

@test "/code/* is proxied with the prefix stripped, query kept" {
  CODE_UPSTREAM=$UP start
  [ "$(curl -s "localhost:$PORT/code/?folder=/home/node/work/x")" = "upstream:/?folder=/home/node/work/x" ]
  [ "$(curl -s localhost:$PORT/code/static/a.js)" = "upstream:/static/a.js" ]
  [ "$(curl -s localhost:$PORT/)" = "ok" ]
}

@test "bare /code redirects to the default working directory" {
  CODE_UPSTREAM=$UP start
  run curl -s -o /dev/null -w '%{http_code} %{redirect_url}' localhost:$PORT/code
  [ "$output" = "302 http://localhost:$PORT/code/?folder=$(node -p "encodeURIComponent('$HOME/work')")" ]
}

@test "a path that only starts with /code is not proxied" {
  CODE_UPSTREAM=$UP start
  [ "$(curl -s localhost:$PORT/codeish)" = "ok" ]
}

@test "WebSocket upgrades on /code are proxied" {
  CODE_UPSTREAM=$UP start
  run curl -s --max-time 3 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' localhost:$PORT/code/stable-abc/
  [[ "$output" == *"path:/stable-abc/"* ]]
}

@test "a dead upstream gives 502, not a crash" {
  CODE_UPSTREAM=1 start
  [ "$(curl -s -o /dev/null -w '%{http_code}' localhost:$PORT/code/)" = "502" ]
  [ "$(curl -s localhost:$PORT/)" = "ok" ]
}
