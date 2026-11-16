// Extension « Mon Hub » pour l'appli Claude (serveur MCP, sans dépendance).
// Elle relaie les demandes de Claude vers Mon Hub, qui écoute en local
// (127.0.0.1) avec une clé secrète écrite dans bridge.json.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');

function bridgeFile() {
  if (process.platform === 'win32') {
    const base = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
    return path.join(base, 'MonHub', 'bridge.json');
  }
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', 'MonHub', 'bridge.json');
  }
  return path.join(os.homedir(), '.config', 'MonHub', 'bridge.json');
}

function readBridge() {
  try {
    return JSON.parse(fs.readFileSync(bridgeFile(), 'utf8'));
  } catch (_) {
    return null;
  }
}

const NOT_OPEN = "Mon Hub n'est pas ouvert sur ce PC. Lance l'appli Mon Hub puis réessaie.";

function callHub(name, args) {
  const b = readBridge();
  if (!b) return Promise.resolve({ error: NOT_OPEN });
  const body = JSON.stringify({ name, arguments: args || {} });
  return new Promise((resolve) => {
    const req = http.request(
      {
        host: '127.0.0.1',
        port: b.port,
        path: '/call',
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
          Authorization: 'Bearer ' + b.key,
        },
        timeout: 120000,
      },
      (res) => {
        let data = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          try {
            resolve(JSON.parse(data));
          } catch (_) {
            resolve({ error: 'Réponse illisible de Mon Hub' });
          }
        });
      }
    );
    req.on('error', () => resolve({ error: NOT_OPEN }));
    req.on('timeout', () => req.destroy());
    req.end(body);
  });
}

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

async function handle(msg) {
  const { id, method, params } = msg;
  if (id === undefined || id === null) return; // notification
  try {
    switch (method) {
      case 'initialize':
        return send({
          jsonrpc: '2.0',
          id,
          result: {
            protocolVersion: (params && params.protocolVersion) || '2025-06-18',
            capabilities: { tools: { listChanged: false } },
            serverInfo: { name: 'mon-hub', version: '1.0.0' },
            instructions:
              "Mon Hub est l'appli personnelle de l'utilisateur (agenda, École Directe, mails, " +
              'Discord, Instagram, livres, Roblox). Les dates sont en heure locale.',
          },
        });
      case 'ping':
        return send({ jsonrpc: '2.0', id, result: {} });
      case 'tools/list': {
        const b = readBridge();
        return send({ jsonrpc: '2.0', id, result: { tools: (b && b.tools) || [] } });
      }
      case 'tools/call': {
        const r = await callHub(params.name, params.arguments);
        const text = r.error
          ? String(r.error)
          : typeof r.result === 'string'
          ? r.result
          : JSON.stringify(r.result, null, 1);
        return send({
          jsonrpc: '2.0',
          id,
          result: { content: [{ type: 'text', text }], isError: !!r.error },
        });
      }
      default:
        return send({ jsonrpc: '2.0', id, error: { code: -32601, message: 'Méthode inconnue : ' + method } });
    }
  } catch (e) {
    send({ jsonrpc: '2.0', id, error: { code: -32603, message: String(e) } });
  }
}

let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let i;
  while ((i = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, i).trim();
    buffer = buffer.slice(i + 1);
    if (!line) continue;
    try {
      handle(JSON.parse(line));
    } catch (_) {}
  }
});
