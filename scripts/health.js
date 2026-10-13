// Minimal health endpoint (HTTP 200 on PORT, default 8080) for platforms that probe a port: container
// orchestrators, load balancers, hosted container services. It also keeps the container's main process alive.
const http = require("http");
const port = Number(process.env.PORT || 8080);
http
  .createServer((req, res) => {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("ok\n");
  })
  .listen(port, "0.0.0.0", () => console.log(`[health] listening on ${port}`));
