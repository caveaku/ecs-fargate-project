# ─────────────────────────────────────────────────────────────
# Stage 1 – deps: install production dependencies only
# ─────────────────────────────────────────────────────────────
FROM node:20-alpine AS deps

WORKDIR /app

# Copy manifests first so Docker layer-caches npm install
COPY package.json package-lock.json* ./

# Install production dependencies only
RUN npm ci --omit=dev && \
    npm cache clean --force

# ─────────────────────────────────────────────────────────────
# Stage 2 – builder: run tests / lint (optional CI gate)
# ─────────────────────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

# Copy all deps (including devDeps) for testing
COPY package.json package-lock.json* ./
RUN npm ci

COPY . .

# If you have a build step (TypeScript, etc.) add it here:
# RUN npm run build

# ─────────────────────────────────────────────────────────────
# Stage 3 – runner: lean production image
# ─────────────────────────────────────────────────────────────
FROM node:20-alpine AS runner

# Install dumb-init for proper PID 1 signal handling
RUN apk add --no-cache dumb-init

WORKDIR /app

# Create a non-root user (UID 1001)
RUN addgroup --system --gid 1001 nodejs && \
    adduser  --system --uid 1001 nodeuser

# Copy production node_modules from deps stage
COPY --from=deps --chown=nodeuser:nodejs /app/node_modules ./node_modules

# Copy application source
COPY --chown=nodeuser:nodejs . .

# Drop to non-root
USER nodeuser

# Expose the application port
EXPOSE 3000

# Health check baked into the image
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

# Use dumb-init as PID 1 so signals are forwarded correctly
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "server.js"]
