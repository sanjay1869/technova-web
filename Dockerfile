# =============================================================
# Dockerfile - recipe to build the TechNova container image
# -------------------------------------------------------------
# Base image comes from Amazon ECR Public (the official Docker
# "node" image mirrored by AWS). Pulling from ECR Public inside
# CodeBuild avoids Docker Hub's anonymous pull rate limits.
# =============================================================

# 1. Start from Node.js 22 on Alpine Linux (small and secure)
FROM public.ecr.aws/docker/library/node:22-alpine

# 2. Production mode, and the port the app listens on
ENV NODE_ENV=production \
    PORT=8080

# 3. All app files live in /app inside the container
WORKDIR /app

# 4. Copy only the dependency lists first. Docker caches this layer,
#    so "npm ci" re-runs only when dependencies change.
COPY package.json package-lock.json ./

# 5. Install exact versions from package-lock.json, without dev tools
RUN npm ci --omit=dev && npm cache clean --force

# 6. Copy the application source code
COPY src ./src

# 7. Build details passed in by CodeBuild (--build-arg). They are
#    shown on the home page so you can see which build is live.
ARG BUILD_NUMBER=local
ARG GIT_COMMIT=local
ENV BUILD_NUMBER=${BUILD_NUMBER} \
    GIT_COMMIT=${GIT_COMMIT}

# 8. Security: run as the built-in non-root "node" user
USER node

# 9. Document the port (the task definition maps 8080)
EXPOSE 8080

# 10. Start the web server
CMD ["node", "src/server.js"]
