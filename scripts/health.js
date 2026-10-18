// Gateway on PORT (default 8080). Answers HTTP 200 `ok` for platforms that probe a port (container orchestrators,
// load balancers, hosted container services) and keeps the container's main process alive.
// When entrypoint.sh started code-server it sets CODE_UPSTREAM (its loopback port), and /code/* is proxied there,
// WebSockets included, with the /code prefix stripped. Without it /code is a 404 and nothing else changes.
const http = require("http");
const net = require("net");
const port = Number(process.env.PORT || 8080);
const upstream = Number(process.env.CODE_UPSTREAM || 0);
const defaultFolder = `${process.env.HOME || "/home/node"}/work`;

const isCode = (url) => /^\/code(?:[/?]|$)/.test(url);
const stripPrefix = (url) => url.replace(/^\/code/, "") || "/";

const server = http.createServer((req, res) => {
  if (!isCode(req.url)) {
    res.writeHead(200, { "content-type": "text/plain" });
    return res.end("ok\n");
  }
  if (!upstream) {
    res.writeHead(404, { "content-type": "text/plain" });
    return res.end("code-server is not enabled (set CODE_PASSWORD)\n");
  }
  // A bare /code opens the default working directory; /code?folder=... and /code/... go through untouched.
  if (req.url === "/code") {
    res.writeHead(302, { location: `/code/?folder=${encodeURIComponent(defaultFolder)}` });
    return res.end();
  }
  const proxied = http.request(
    { host: "127.0.0.1", port: upstream, method: req.method, path: stripPrefix(req.url), headers: req.headers },
    (up) => {
      res.writeHead(up.statusCode, up.headers);
      up.pipe(res);
    }
  );
  proxied.on("error", () => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end("code-server is not reachable\n");
  });
  req.pipe(proxied);
});

// VS Code runs over WebSockets: replay the upgrade request on a raw socket to code-server and pipe both ways.
server.on("upgrade", (req, socket, head) => {
  if (!upstream || !isCode(req.url)) return socket.destroy();
  const up = net.connect(upstream, "127.0.0.1", () => {
    const lines = [`${req.method} ${stripPrefix(req.url)} HTTP/${req.httpVersion}`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
    up.write(lines.join("\r\n") + "\r\n\r\n");
    if (head && head.length) up.write(head);
    socket.pipe(up).pipe(socket);
  });
  up.on("error", () => socket.destroy());
  socket.on("error", () => up.destroy());
});

server.listen(port, "0.0.0.0", () =>
  console.log(`[health] listening on ${port}${upstream ? ` (/code -> 127.0.0.1:${upstream})` : ""}`)
);
