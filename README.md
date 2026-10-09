# TechNova Store – AWS CI/CD Pipeline to Amazon ECS (Lab Project, version 2.0)

Companion code for the lab guide **"Automated CI/CD Pipeline on AWS: GitHub → CodePipeline → CodeBuild → Amazon ECR → Amazon ECS (Fargate)"** by Sanjay Sharma (version 2.0, October 2026).

Every push to the `main` branch on GitHub is tested, built into a container image, stored in Amazon ECR, and deployed to Amazon ECS on AWS Fargate behind an Application Load Balancer.

- **Part A** – rolling update with the CodePipeline *Amazon ECS* deploy action (circuit breaker + automatic rollback)
- **Part B** – blue/green with AWS CodeDeploy (*Amazon ECS (Blue/Green)* action, two target groups, test listener)

Region used in the lab: **Asia Pacific (Mumbai) `ap-south-1`**.

---

## What changed in version 2.0

| Problem in version 1 | Fix in version 2.0 |
|---|---|
| The Build action used the pipeline variable `#{SourceVariables.CommitId}`. The wizard names namespaces automatically, so on some pipelines the variable cannot be resolved and **Build fails before CodeBuild starts**. | No pipeline variables are needed. `buildspec.yml` reads the commit ID from CodeBuild's own `CODEBUILD_RESOLVED_SOURCE_VERSION`. |
| CodeBuild's ECR permission was a JSON policy where you had to type your account ID. One typing mistake → `AccessDenied` on push. | Attach the AWS managed policy **AmazonEC2ContainerRegistryPowerUser** (two clicks, nothing to type) **before** the first run (Step 6.4). |
| **Privileged** mode (needed for Docker) was easy to miss in the CodeBuild pop-up. | Highlighted in Step 6.3, and `buildspec.yml` now stops with a clear `ERROR / FIX` message if Docker is unavailable. |
| A `latest` tag was pushed to an immutable repository and only worked if the exclusion filter was typed exactly. | Only one unique tag per build (`<commit>-<build number>`), so no exclusions are needed. |
| Several IAM JSON files and the task definition needed manual account-ID edits. | IAM policies use wildcards for account and Region (still scoped to the lab resources). The task definition has two clearly marked values you **paste** from the console (role ARN, image URI). |
| New AWS accounts can have a CodeBuild limit of 0 builds ("Build failed to start … Cannot have more than 0 builds in queue"). | Step 1 checks the quota in Service Quotas and shows how to request an increase before class. |
| Hard to tell why a build failed. | New `scripts/preflight-check.sh` tests every Step 1–7 setting (including the CodeBuild quota) from CloudShell and prints PASS/FAIL with the fix. |
| Test report layout | Tests grouped in one `describe()` so the JUnit report has a standard `<testsuite>` for CodeBuild reports. |
| Blue/green script could time out waiting | `create-bluegreen-service.sh` now waits for 2 healthy tasks with its own loop. |

---

## What is in this folder

| Path | What it is | Used in lab step |
|------|-----------|------------------|
| `src/config.js` | **The file you edit to make a new release** (version, release name, banner colour) | Tests T1–T3, Part B |
| `src/app.js` | Express web app: `/`, `/health`, `/api/products`, `/api/products/:id`, `/api/info` | – |
| `src/info.js` | Reads build details and the ECS task metadata (task ID, Availability Zone) | – |
| `src/server.js` | Starts the server on port 8080 and shuts down cleanly on SIGTERM | – |
| `test/app.test.js` | 7 unit tests (Node.js built-in test runner, no extra services) | Step 7, Test T2 |
| `package.json`, `package-lock.json` | Dependencies (Express 5) and npm scripts | – |
| `Dockerfile` | Builds the image from the Amazon ECR Public `node:22-alpine` base, runs as non-root | Step 6 (CodeBuild) |
| `.dockerignore`, `.gitignore` | Files Docker / Git should skip | – |
| `buildspec.yml` | CodeBuild instructions: test → check Docker → check ECR → build → push → write deployment files | Step 6 |
| `deploy/taskdef.template.json` | Task definition template for blue/green (`<IMAGE1_NAME>` placeholder) | Part B |
| `deploy/appspec.yaml` | CodeDeploy AppSpec for ECS (`<TASK_DEFINITION>` placeholder) | Part B |
| `ecs/taskdef-console.json` | Task definition to paste in the ECS console JSON editor (paste 2 values) | Step 11 |
| `ecr/lifecycle-policy.json` | Keep only the 10 newest images | Step 4 (CLI version) |
| `iam/codepipeline-ecs-deploy-policy.json` | Pipeline role permissions for the Amazon ECS deploy action (nothing to edit) | Step 13 |
| `iam/codepipeline-codedeploy-policy.json` | Pipeline role permissions for the ECS (Blue/Green) action (nothing to edit) | Part B |
| `iam/codebuild-ecr-push-policy.json` | Optional least-privilege alternative to AmazonEC2ContainerRegistryPowerUser | Step 6.4 (optional) |
| `iam/*-trust-policy.json` | Trust policies (reference – the console creates these for you) | – |
| `scripts/preflight-check.sh` | **New:** checks connection, ECR, roles, log group, CodeBuild settings and pipeline state | Step 7 |
| `scripts/create-bluegreen-service.sh` | Creates the CodeDeploy-controlled ECS service (run in CloudShell) | Part B, step B3 |
| `scripts/cleanup.sh` | Lists (and with `--delete` removes) every lab resource | Clean-up |
| `docs/cli-equivalents.sh` | AWS CLI versions of the key console steps (reference only) | Appendix |

---

## Run it on your laptop (optional)

Requires Node.js 22 or newer.

```bash
npm install        # install dependencies
npm test           # run the 7 unit tests
npm start          # open http://localhost:8080
```

With Docker Desktop installed you can also build and run the container:

```bash
docker build -t technova-web .
docker run --rm -p 8080:8080 technova-web
```

---

## Push it to your GitHub repository

```bash
git init
git add .
git commit -m "Initial commit: TechNova web app v1.0.0"
git branch -M main
git remote add origin https://github.com/<your-username>/technova-web.git
git push -u origin main
```

---

## If the Build stage fails

1. Open the failed **Build** action → **View details** → **Logs**. Look for lines starting with `ERROR -` and `FIX -`.
2. If the stage says **Build failed to start … Cannot have more than 0 builds**, request a CodeBuild quota increase (Service Quotas → AWS CodeBuild → Linux/Small) or open a free Account and billing support case.
3. In AWS CloudShell (Mumbai) upload and run `bash preflight-check.sh`. Fix every `[FAIL]` line.
4. In CodePipeline choose **Retry** on the Build stage (or **Release change**).

---

## Make a release

1. Edit `src/config.js` – for example `version: "1.1.0"`, `releaseName: "Festival Sale"`, `themeColor: "#FF9900"`.
2. `git add . && git commit -m "Release 1.1.0" && git push`
3. Watch **CodePipeline → technova-web-pipeline**. Refresh the load balancer URL when Deploy succeeds.

The version must look like `1.2.3`. A version such as `2.0` fails the unit tests, and the pipeline stops before deploying (Test T2 in the lab).

---

## Clean up

Follow the clean-up section of the lab guide, or run in AWS CloudShell:

```bash
bash cleanup.sh            # report only
bash cleanup.sh --delete   # delete (asks you to type your account ID)
```

---

## Verified (version 2.0)

- `npm test` – 7/7 tests pass on Node.js 22.
- `docker build` and `docker run` – all endpoints answer; container runs as user `node`; graceful shutdown on SIGTERM.
- `buildspec.yml` dry-run in 5 scenarios – success (unique tag), no commit ID (`manual-N` tag), failing test, Docker unavailable, ECR not readable. Every failure stops before any push and prints `ERROR` / `FIX`.
- Generated `taskdef.json` and `ecs/taskdef-console.json` pass the Amazon ECS `RegisterTaskDefinition` API schema.
- `preflight-check.sh` tested against a mock AWS CLI (11/11 pass; 8 fail cases each with the right fix); `create-bluegreen-service.sh` wait loop tested against a mock; all AWS CLI calls and the 34 reference commands produce valid API requests.
- All shell scripts pass ShellCheck; all JSON and YAML files parse.
- Live AWS behaviour must still be confirmed in your own AWS account – see the *Verification report* page in the lab guide.
