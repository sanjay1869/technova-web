// =============================================================
// src/server.js - starts the web server
// -------------------------------------------------------------
// The container runs "node src/server.js". The port comes from the
// PORT environment variable (8080 in the Dockerfile).
// =============================================================
const { createApp } = require("./app");
const { loadEcsMetadata } = require("./info");

const PORT = Number(process.env.PORT) || 8080;

async function main() {
  await loadEcsMetadata(); // learn our ECS task ID and AZ (if on ECS)
  const server = createApp().listen(PORT, () => {
    console.log(`TechNova web app listening on port ${PORT}`);
  });

  // ECS sends SIGTERM before it stops a task (for example during a
  // deployment). Finish in-flight requests, then exit cleanly.
  process.on("SIGTERM", () => {
    console.log("SIGTERM received - shutting down gracefully");
    server.close(() => process.exit(0));
  });
}

main();
