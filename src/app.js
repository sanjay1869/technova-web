// =============================================================
// src/app.js - the Express web application (routes only)
// -------------------------------------------------------------
// We build the app here and start it in server.js. Keeping them
// separate lets the unit tests start the app on a random port.
// =============================================================
const express = require("express");
const config = require("./config");
const { getInfo } = require("./info");

// A tiny in-memory product catalogue (no database needed for the lab)
const products = [
  { id: 1, name: "Wireless Mouse", price: 799, currency: "INR", inStock: true },
  { id: 2, name: "Mechanical Keyboard", price: 3499, currency: "INR", inStock: true },
  { id: 3, name: "27-inch Monitor", price: 15999, currency: "INR", inStock: false },
  { id: 4, name: "USB-C Docking Station", price: 5999, currency: "INR", inStock: true },
];

// Escape text before putting it into HTML (basic safety habit)
const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

function createApp() {
  const app = express();
  app.disable("x-powered-by"); // Do not advertise the framework

  // Health check used by the Application Load Balancer target group.
  // It must be fast and must not depend on other services.
  app.get("/health", (req, res) => {
    res.status(200).json({ status: "ok" });
  });

  // JSON API: list all products
  app.get("/api/products", (req, res) => {
    res.json({ count: products.length, products });
  });

  // JSON API: one product by id, or 404 if it does not exist
  app.get("/api/products/:id", (req, res) => {
    const product = products.find((p) => p.id === Number(req.params.id));
    if (!product) return res.status(404).json({ error: "Product not found" });
    return res.json(product);
  });

  // JSON API: version, build and the task that served this request
  app.get("/api/info", (req, res) => {
    res.json(getInfo());
  });

  // Home page: shows the release and which container answered
  app.get("/", (req, res) => {
    const i = getInfo();
    const rows = [
      ["Version", i.version],
      ["Release", i.releaseName],
      ["Build number", i.buildNumber],
      ["Git commit", i.gitCommit],
      ["ECS task ID", i.taskId],
      ["Availability Zone", i.availabilityZone],
      ["Container hostname", i.hostname],
    ]
      .map(([k, v]) => `<tr><th>${esc(k)}</th><td>${esc(v)}</td></tr>`)
      .join("");
    res.type("html").send(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(i.app)} v${esc(i.version)}</title>
<style>
 body{margin:0;font-family:Arial,Helvetica,sans-serif;background:#f4f6f8;color:#16191f}
 header{background:${esc(config.themeColor)};color:#fff;padding:28px 32px}
 header h1{margin:0;font-size:28px} header p{margin:6px 0 0;opacity:.9}
 main{max-width:760px;margin:24px auto;padding:0 16px}
 .card{background:#fff;border-radius:10px;box-shadow:0 1px 4px rgba(0,0,0,.1);padding:20px 24px;margin-bottom:18px}
 table{border-collapse:collapse;width:100%} th,td{text-align:left;padding:8px;border-bottom:1px solid #e9ebed}
 th{width:40%;color:#545b64} .tag{display:inline-block;background:#ff9900;color:#16191f;border-radius:12px;padding:2px 10px;font-weight:bold}
 a{color:#0972d3}
</style></head>
<body><header><h1>${esc(i.app)}</h1><p>Deployed automatically by AWS CodePipeline to Amazon ECS on AWS Fargate</p></header>
<main><div class="card"><p><span class="tag">v${esc(i.version)}</span> &nbsp; ${esc(i.releaseName)}</p>
<table>${rows}</table></div>
<div class="card"><b>Try the API:</b> <a href="/api/products">/api/products</a> &middot; <a href="/api/info">/api/info</a> &middot; <a href="/health">/health</a>
<p>Refresh this page: the load balancer sends you to different tasks, so the task ID can change.</p></div></main></body></html>`);
  });

  // Anything else: JSON 404
  app.use((req, res) => res.status(404).json({ error: "Not found" }));

  return app;
}

module.exports = { createApp, products };
