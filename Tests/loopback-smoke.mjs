// SDK production delivery pipeline, synthetic local receiver only. No Google
// requests or real credentials. Apple native calls are separately spy-tested.
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';

for (const mode of ['active', 'passive']) {
  const received = [];
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const raw = Buffer.concat(chunks).toString();
    const body = raw ? JSON.parse(raw) : null;
    received.push({ path: req.url, body, signed: Boolean(req.headers['x-trackhub-signature']) });
    res.setHeader('Content-Type', 'application/json');
    if (req.url.endsWith('/cv-schema')) {
      res.end(JSON.stringify({ schemaVersion: 1, rules: [
        { from: 1, to: 1, event: 'install', coarse: 'low' },
        { from: 5, to: 5, event: 'trial_started', coarse: 'high' },
      ], lockOnEvents: [] }));
    } else {
      res.end(JSON.stringify({
        ok: true,
        install_uid: body?.install_uid,
        install_token: `thic_v1_${'A'.repeat(43)}`,
        conversion_update: { schema_version: 1, window: 0, fine: 7, coarse: 'high', lock_window: false },
      }));
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const args = ['run', 'live-check', `http://127.0.0.1:${server.address().port}`,
    `loopback-ingest-${randomUUID()}`, 'loopback-secret-fixture', '--loopback-fixture'];
  if (mode === 'passive') args.push('--passive');
  let output = '';
  try {
    await new Promise((resolve, reject) => {
      const child = spawn('swift', args, { stdio: ['ignore', 'pipe', 'pipe'] });
      child.stdout.on('data', data => { output += data; });
      child.stderr.on('data', data => { output += data; });
      const timer = setTimeout(() => { child.kill(); reject(new Error('loopback smoke timed out')); }, 120000);
      child.on('error', error => { clearTimeout(timer); reject(error); });
      child.on('exit', code => {
        clearTimeout(timer);
        code === 0 ? resolve() : reject(new Error(`live-check failed (${code}): ${output}`));
      });
    });
    for (const route of ['/install', '/sdk/session', '/sdk/track', '/sdk/identity', '/sdk/purchase-context']) {
      const matching = received.filter(item => item.path.endsWith(route));
      assert(matching.length > 0, `${mode}: missing ${route}; paths=${received.map(item => item.path)}`);
      assert(matching.every(item => item.signed), `${mode}: unsigned ${route}`);
      if (route !== '/sdk/identity') {
        assert(matching.some(item => item.body.odm_info === 'loopback-odm-fixture'), `${mode}: missing ODM on ${route}`);
      }
    }
    assert(received.some(item => item.body?.sdk_version === '3.1.3'), `${mode}: SDK version`);
    assert.equal(received.some(item => item.path.endsWith('/cv-schema')), mode === 'active', `${mode}: schema requests`);
    console.log(`PASS ${mode}: install, session, events, identity, purchase context and ODM delivered; CV schema ${mode === 'active' ? 'enabled' : 'disabled'}`);
  } catch (error) {
    console.error(output); // Loopback fixture only, never production data.
    throw error;
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}
