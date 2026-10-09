// =============================================================
// src/info.js - "Who am I?" information for the running container
// -------------------------------------------------------------
// - Build details (build number, Git commit) are baked into the
//   image by CodeBuild as environment variables.
// - When the app runs on AWS Fargate, ECS gives every container a
//   private "task metadata endpoint". We read it once at start-up
//   to learn the task ID and Availability Zone that serve requests.
// =============================================================
const os = require("node:os");
const config = require("./config");

const startedAt = new Date();

// Default values, used when running on a laptop (not on ECS)
const runtime = {
  taskId: "local",
  availabilityZone: "local",
  cluster: "local",
};

// Ask the ECS task metadata endpoint (v4) about this task.
// ECS sets ECS_CONTAINER_METADATA_URI_V4 automatically on Fargate.
async function loadEcsMetadata() {
  const uri = process.env.ECS_CONTAINER_METADATA_URI_V4;
  if (!uri) return runtime; // Not on ECS - keep the "local" values
  try {
    const res = await fetch(`${uri}/task`, { signal: AbortSignal.timeout(2000) });
    const task = await res.json();
    // TaskARN looks like arn:aws:ecs:region:acct:task/cluster/abc123... - keep the last part
    runtime.taskId = String(task.TaskARN || "unknown").split("/").pop();
    runtime.availabilityZone = task.AvailabilityZone || "unknown";
    runtime.cluster = String(task.Cluster || "unknown").split("/").pop();
  } catch (err) {
    console.warn("Could not read ECS task metadata:", err.message);
  }
  return runtime;
}

// Everything the home page and /api/info need, in one object
function getInfo() {
  return {
    app: config.appName,
    version: config.version,
    releaseName: config.releaseName,
    buildNumber: process.env.BUILD_NUMBER || "local",
    gitCommit: process.env.GIT_COMMIT || "local",
    taskId: runtime.taskId,
    availabilityZone: runtime.availabilityZone,
    cluster: runtime.cluster,
    hostname: os.hostname(),
    uptimeSeconds: Math.round((Date.now() - startedAt.getTime()) / 1000),
  };
}

module.exports = { getInfo, loadEcsMetadata };
