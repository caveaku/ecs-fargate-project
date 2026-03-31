'use strict';

const express = require('express');
const os = require('os');

const app = express();
const PORT = process.env.PORT || 3000;
const ENV = process.env.NODE_ENV || 'development';

app.use(express.json());

// Request logger middleware
app.use((req, res, next) => {
  const timestamp = new Date().toISOString();
  console.log(JSON.stringify({
    timestamp,
    method: req.method,
    path: req.path,
    ip: req.ip,
    userAgent: req.get('User-Agent'),
  }));
  next();
});

// Root endpoint
app.get('/', (req, res) => {
  res.json({
    message: 'Hello from ECS Fargate!',
    hostname: os.hostname(),
    environment: ENV,
    version: process.env.APP_VERSION || '1.0.0',
    timestamp: new Date().toISOString(),
  });
});

// Health check endpoint — must return 200 for ALB target group
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
  });
});

// Info endpoint
app.get('/info', (req, res) => {
  res.json({
    node: process.version,
    platform: process.platform,
    arch: process.arch,
    uptime: Math.floor(process.uptime()),
    memory: {
      rss: process.memoryUsage().rss,
      heapTotal: process.memoryUsage().heapTotal,
      heapUsed: process.memoryUsage().heapUsed,
    },
    environment: ENV,
    hostname: os.hostname(),
    cpus: os.cpus().length,
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not Found', path: req.path });
});

// Global error handler
app.use((err, req, res, _next) => {
  console.error(JSON.stringify({ level: 'error', message: err.message, stack: err.stack }));
  res.status(500).json({ error: 'Internal Server Error' });
});

// Graceful shutdown
const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(JSON.stringify({
    level: 'info',
    message: `Server listening on port ${PORT}`,
    environment: ENV,
    pid: process.pid,
  }));
});

const shutdown = (signal) => {
  console.log(JSON.stringify({ level: 'info', message: `Received ${signal}, shutting down gracefully` }));
  server.close(() => {
    console.log(JSON.stringify({ level: 'info', message: 'HTTP server closed' }));
    process.exit(0);
  });
  // Force exit after 10s
  setTimeout(() => process.exit(1), 10_000);
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

module.exports = app;
