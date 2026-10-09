// =============================================================
// test/app.test.js - unit tests (Node.js built-in test runner)
// -------------------------------------------------------------
// No extra test libraries and no AWS services are needed.
// Each test starts the app on a random free port and calls it.
// If ANY test fails, "npm test" fails, CodeBuild fails, and the
// pipeline stops BEFORE anything is deployed.
// =============================================================
const { describe, test, before, after } = require("node:test");
const assert = require("node:assert/strict");
const { createApp, products } = require("../src/app");
const config = require("../src/config");

// describe() groups the tests into one <testsuite> in the JUnit report,
// which is the layout CodeBuild test reports expect.
describe("TechNova API", () => {
  let server;
  let baseUrl;

  before(async () => {
    server = createApp().listen(0); // port 0 = pick any free port
    await new Promise((resolve) => server.once("listening", resolve));
    baseUrl = `http://127.0.0.1:${server.address().port}`;
  });

  after(() => server.close());

  test("GET /health returns 200 and status ok", async () => {
    const res = await fetch(`${baseUrl}/health`);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { status: "ok" });
  });

  test("GET /api/products returns the full catalogue", async () => {
    const res = await fetch(`${baseUrl}/api/products`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.count, products.length);
    assert.ok(body.products.every((p) => p.id && p.name && p.price > 0));
  });

  test("GET /api/products/:id returns one product", async () => {
    const res = await fetch(`${baseUrl}/api/products/2`);
    assert.equal(res.status, 200);
    assert.equal((await res.json()).name, "Mechanical Keyboard");
  });

  test("GET /api/products/:id returns 404 for an unknown product", async () => {
    const res = await fetch(`${baseUrl}/api/products/999`);
    assert.equal(res.status, 404);
  });

  test("GET /api/info reports the configured version", async () => {
    const res = await fetch(`${baseUrl}/api/info`);
    const body = await res.json();
    assert.equal(body.version, config.version);
    assert.match(body.version, /^\d+\.\d+\.\d+$/, "version must look like 1.2.3");
  });

  test("GET / shows the version on the home page", async () => {
    const res = await fetch(`${baseUrl}/`);
    assert.equal(res.status, 200);
    assert.match(await res.text(), new RegExp(`v${config.version.replace(/\./g, "\\.")}`));
  });

  test("unknown routes return a JSON 404", async () => {
    const res = await fetch(`${baseUrl}/does-not-exist`);
    assert.equal(res.status, 404);
    assert.equal((await res.json()).error, "Not found");
  });
});
