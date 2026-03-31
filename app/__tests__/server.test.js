'use strict';

const request = require('supertest');
const app     = require('../server');

describe('GET /', () => {
  it('returns 200 with app info', async () => {
    const res = await request(app).get('/');
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      message: 'Hello from ECS Fargate!',
      environment: expect.any(String),
      version:     expect.any(String),
      hostname:    expect.any(String),
      timestamp:   expect.any(String),
    });
  });
});

describe('GET /health', () => {
  it('returns 200 with healthy status', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'healthy' });
    expect(res.body.timestamp).toBeDefined();
  });
});

describe('GET /info', () => {
  it('returns 200 with runtime info', async () => {
    const res = await request(app).get('/info');
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      node:        expect.any(String),
      platform:    expect.any(String),
      arch:        expect.any(String),
      uptime:      expect.any(Number),
      environment: expect.any(String),
      hostname:    expect.any(String),
      cpus:        expect.any(Number),
    });
    expect(res.body.memory).toMatchObject({
      rss:       expect.any(Number),
      heapTotal: expect.any(Number),
      heapUsed:  expect.any(Number),
    });
  });
});

describe('GET /unknown-route', () => {
  it('returns 404 for unmatched paths', async () => {
    const res = await request(app).get('/does-not-exist');
    expect(res.status).toBe(404);
    expect(res.body).toMatchObject({ error: 'Not Found' });
  });
});
