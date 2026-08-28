'use strict';

// Pure-offline execution of the actual dist/server.js insertion asset. No
// server, MCP, PLE, REST listener or engineering project is started.
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const patchRoot = __dirname;
const toolSource = fs.readFileSync(path.join(patchRoot, 'get_ctrlx_semantic_snapshot.tool.js'), 'utf8');
const vectors = JSON.parse(fs.readFileSync(path.join(patchRoot, 'semantic-canonical-vectors.json'), 'utf8'));

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value !== null && typeof value === 'object') {
    const result = {};
    for (const key of Object.keys(value).sort()) result[key] = canonicalize(value[key]);
    return result;
  }
  return value;
}

function canonicalJson(value) {
  return JSON.stringify(canonicalize(value));
}

function sha256(value) {
  return crypto.createHash('sha256').update(canonicalJson(value), 'utf8').digest('hex');
}

function schemaNode() {
  return {
    min() { return this; },
    max() { return this; },
    optional() { return this; },
    default() { return this; },
    describe() { return this; },
  };
}

function bodyStream(chunks, stats = {}) {
  let index = 0;
  stats.readCount = 0;
  stats.cancelCount = 0;
  return {
    getReader() {
      return {
        async read() {
          stats.readCount += 1;
          if (index >= chunks.length) return { done: true, value: undefined };
          const value = Buffer.isBuffer(chunks[index]) ? chunks[index] : Buffer.from(chunks[index]);
          index += 1;
          return { done: false, value };
        },
        async cancel() {
          stats.cancelCount += 1;
        },
        releaseLock() {},
      };
    },
  };
}

function responseFromText(value, options = {}) {
  const body = Buffer.from(String(value), 'utf8');
  return {
    ok: options.ok !== false,
    status: options.status || 200,
    body: bodyStream(options.chunks || [body], options.stats),
  };
}

function mappingResult(projectPath, mappingFacts) {
  return {
    contractVersion: 1,
    contractId: 'ctrlx-semantic-snapshot-v1',
    producer: 'codesys-persistent.get_ctrlx_semantic_snapshot',
    adapterPatchId: 'ctrlx-semantic-snapshot-v1',
    projectFilePath: projectPath,
    dirtyStateVerified: true,
    projectDirty: false,
    dirtyCheckCount: 2,
    dirtyBefore: false,
    dirtyAfter: false,
    scopeCount: mappingFacts.scopeCount,
    explicitTargetCount: mappingFacts.explicitTargetCount,
    recordCount: mappingFacts.recordCount,
    recordLimit: mappingFacts.recordLimit,
    traversalFailureCount: 0,
    recordsComplete: true,
    scopes: mappingFacts.scopes.map((scope, index) => ({
      ...scope,
      resolved: true,
      recordStart: index === 0 ? 0 : mappingFacts.scopes.slice(0, index).reduce((sum, item) => sum + item.recordCount, 0),
    })),
    // Reverse input deliberately; the producer must use ordinal canonical order.
    mappings: mappingFacts.records.slice().reverse().map((record) => ({
      ...record,
      resolved: true,
      mappingReadable: true,
      error: null,
    })),
  };
}

async function invokeTool(mappingData, symbolPayloads, options = {}) {
  let registered = null;
  let symbolRead = 0;
  let mappingRead = 0;
  let executorCalls = 0;
  const fetchUris = [];
  const z = {
    string: schemaNode,
    literal: schemaNode,
    object: schemaNode,
    array: schemaNode,
  };
  const context = {
    s: {
      tool(name, description, schema, handler) {
        assert.strictEqual(name, 'get_ctrlx_semantic_snapshot');
        registered = handler;
      },
    },
    zod_1: { z },
    workspaceDir: process.cwd(),
    resolvePath: (value, workspace) => path.resolve(workspace, value),
    sanitizePouPath: (value) => value.replace(/\\/g, '/').replace(/^\/+|\/+$/g, ''),
    scriptManager: { prepareScriptWithHelpers: () => 'fixture-script' },
    executor: {
      executeScript: async () => {
        executorCalls += 1;
        return options.executorResult ||
          ({ success: true, output: 'SCRIPT_SUCCESS\nRESULT_JSON:{}', error: null });
      },
    },
    result_parser_1: {
      parseResultJson: () => {
        const sequence = options.mappingDataSequence || [mappingData];
        const data = sequence[Math.min(mappingRead, sequence.length - 1)];
        mappingRead += 1;
        return { ok: true, data };
      },
    },
    fetch: async (uri, init) => {
      fetchUris.push(String(uri));
      if (options.fetchResponseFactory) return options.fetchResponseFactory(uri, init);
      if (options.fetchResponse) return options.fetchResponse;
      const payload = symbolPayloads[Math.min(symbolRead, symbolPayloads.length - 1)];
      symbolRead += 1;
      return responseFromText(options.rawSymbolBodies ? String(payload) : JSON.stringify(payload));
    },
    AbortController,
    Buffer,
    console,
    clearTimeout,
    encodeURIComponent,
    path,
    process,
    require,
    setTimeout: options.setTimeout || setTimeout,
  };
  vm.runInNewContext(toolSource, context, { filename: 'get_ctrlx_semantic_snapshot.tool.js' });
  assert.strictEqual(typeof registered, 'function');
  const response = await registered({
    projectFilePath: mappingData.projectFilePath,
    mappingScopes: [{
      devicePath: 'Device/Realtime_Data/ethercat_master_instances_fixture',
      recursive: true,
      includeAllMappableChannels: true,
    }],
    mappingTargets: [],
    symbolApplicationPath: 'Device/Plc Logic/Application',
  });
  response.fetchUris = fetchUris;
  response.executorCalls = executorCalls;
  return response;
}

async function main() {
  assert(!toolSource.includes('localeCompare'), 'canonical order must not be locale-dependent');
  assert(!toolSource.includes('expectedVariable'), 'actual-only tool must not accept expected values');
  const vector = vectors.vectors[0];
  const symbolCanonical = canonicalJson(vector.symbolPayloadInput);
  assert.strictEqual(symbolCanonical, vector.expectedSymbolPayloadCanonicalJson);
  assert.strictEqual(Buffer.byteLength(symbolCanonical, 'utf8'), vector.expectedSymbolPayloadUtf8Bytes);
  assert.strictEqual(sha256(vector.symbolPayloadInput), vector.expectedSymbolPayloadSha256);
  assert.strictEqual(canonicalJson(vector.canonicalFactsInput), vector.expectedCanonicalFactsJson);
  assert.strictEqual(sha256(vector.canonicalFactsInput.mapping), vector.expectedMappingSha256);
  assert.strictEqual(sha256(vector.canonicalFactsInput.symbolConfig), vector.expectedSymbolConfigSha256);
  assert.strictEqual(sha256(vector.canonicalFactsInput), vector.expectedSnapshotSha256);

  const projectPath = path.resolve('semantic-fixture.project');
  const mapping = mappingResult(projectPath, vector.canonicalFactsInput.mapping);
  const transientWarmupPayload = { transient: 'discard this incomplete first read' };
  const response = await invokeTool(mapping, [
    transientWarmupPayload,
    vector.symbolPayloadInput,
    vector.symbolPayloadInput,
  ]);
  assert.strictEqual(response.isError, false, response.content[0].text);
  assert.strictEqual(response.fetchUris.length, 3,
    'one bounded Symbol warm-up read must precede the authoritative double-read');
  assert.strictEqual(response.executorCalls, 3,
    'the final ScriptEngine dirty-state guard must run after both REST reads');
  assert(response.fetchUris.every((uri) => uri.startsWith('http://localhost:9002/')),
    'PLE REST calls must use the localhost authority accepted by the extension');
  assert(response.fetchUris.every((uri) => !uri.startsWith('http://127.0.0.1:9002/')),
    'numeric loopback authority is rejected by the PLE extension with HTTP 400');
  assert(Buffer.byteLength(response.content[0].text, 'utf8') < 480 * 1024);
  assert(response.content[0].text.includes('通道β'));
  assert(!response.content[0].text.includes('"payload":'), 'full Symbol payload must not cross MCP');
  const payload = JSON.parse(response.content[0].text);
  assert.deepStrictEqual(payload.canonicalFacts, vector.canonicalFactsInput);
  assert.strictEqual(payload.hashes.mappingSha256, vector.expectedMappingSha256);
  assert.strictEqual(payload.hashes.symbolConfigSha256, vector.expectedSymbolConfigSha256);
  assert.strictEqual(payload.hashes.snapshotSha256, vector.expectedSnapshotSha256);
  assert(!response.content[0].text.includes('discard this incomplete first read'),
    'the discarded warm-up payload must not influence the authoritative snapshot');

  const changed = await invokeTool(mapping, [
    vector.symbolPayloadInput,
    vector.symbolPayloadInput,
    { changed: true },
  ]);
  assert.strictEqual(changed.isError, true);
  assert.strictEqual(JSON.parse(changed.content[0].text).reasonCode, 'SEMANTIC_SNAPSHOT_FAILED');

  const dirtyFinalMapping = {
    ...mapping,
    projectDirty: true,
    dirtyAfter: true,
  };
  const dirtyAfterSecondMapping = await invokeTool(
    mapping,
    [vector.symbolPayloadInput, vector.symbolPayloadInput, vector.symbolPayloadInput],
    { mappingDataSequence: [mapping, mapping, dirtyFinalMapping] }
  );
  assert.strictEqual(dirtyAfterSecondMapping.isError, true,
    'an edit after mappingAfter must be rejected by the final ScriptEngine probe');
  assert.strictEqual(dirtyAfterSecondMapping.executorCalls, 3);
  assert.strictEqual(dirtyAfterSecondMapping.fetchUris.length, 3);

  const malformedPlePayload = '{\r\n  "variableType": "STRING := "quoted IEC text""\r\n}';
  const malformedResponse = await invokeTool(
    mapping,
    [malformedPlePayload, malformedPlePayload, malformedPlePayload],
    { rawSymbolBodies: true }
  );
  assert.strictEqual(malformedResponse.isError, false, malformedResponse.content[0].text);
  const malformedSnapshot = JSON.parse(malformedResponse.content[0].text);
  assert.strictEqual(malformedSnapshot.canonicalFacts.symbolConfig.shapeSummary.rootKind, 'string');
  assert.strictEqual(malformedSnapshot.canonicalFacts.symbolConfig.shapeSummary.nodeCount, 1);
  assert(!malformedResponse.content[0].text.includes('quoted IEC text'),
    'opaque malformed PLE payload must not cross the MCP boundary');

  const changedMalformed = await invokeTool(
    mapping,
    [malformedPlePayload, malformedPlePayload, malformedPlePayload + 'changed'],
    { rawSymbolBodies: true }
  );
  assert.strictEqual(changedMalformed.isError, true,
    'opaque Symbol text must still pass the same double-read stability gate');

  const largeFacts = {
    scopeCount: 1,
    explicitTargetCount: 0,
    recordCount: 1600,
    recordLimit: 2048,
    scopes: [{
      scopeIndex: 0,
      devicePath: 'Device/Realtime_Data/Large',
      recursive: true,
      rootName: 'Large',
      recordCount: 1600,
    }],
    records: Array.from({ length: 1600 }, (_, index) => ({
      actualVariable: `Application.Peripherals.${String(index).padStart(4, '0')}.${'测'.repeat(220)}`,
      channelIdentity: `scope:000000:0:${String(index).padStart(6, '0')}`,
    })),
  };
  const tooLarge = await invokeTool(
    mappingResult(projectPath, largeFacts),
    [vector.symbolPayloadInput, vector.symbolPayloadInput]
  );
  assert.strictEqual(tooLarge.isError, true);
  const tooLargePayload = JSON.parse(tooLarge.content[0].text);
  assert.strictEqual(tooLargePayload.reasonCode, 'SEMANTIC_SNAPSHOT_TOO_LARGE');
  assert.strictEqual(tooLargePayload.recordsComplete, false);

  const secret = 'token=DO_NOT_EXPOSE_THIS_VALUE';
  const executorFailure = await invokeTool(mapping, [vector.symbolPayloadInput], {
    executorResult: {
      success: false,
      output: `${secret}${'x'.repeat(2 * 1024 * 1024)}`,
      error: `Authorization: Bearer ${secret}`,
    },
  });
  assert.strictEqual(executorFailure.isError, true);
  assert(!executorFailure.content[0].text.includes('DO_NOT_EXPOSE_THIS_VALUE'));
  assert(executorFailure.content[0].text.includes('outputSha256='));
  assert(Buffer.byteLength(executorFailure.content[0].text, 'utf8') < 16 * 1024);

  const restFailure = await invokeTool(mapping, [vector.symbolPayloadInput], {
    fetchResponse: responseFromText(`${secret}${'y'.repeat(64 * 1024)}`, { ok: false, status: 500 }),
  });
  assert.strictEqual(restFailure.isError, true);
  assert(!restFailure.content[0].text.includes('DO_NOT_EXPOSE_THIS_VALUE'));
  assert(restFailure.content[0].text.includes('bodySha256='));
  assert(Buffer.byteLength(restFailure.content[0].text, 'utf8') < 16 * 1024);

  const oversizeStats = {};
  const oversizeChunks = Array.from({ length: 8 }, () => Buffer.alloc(1024 * 1024, 0x61));
  oversizeChunks.push(Buffer.from([0x62]));
  oversizeChunks.push(Buffer.from('must-not-be-read'));
  const oversizeBody = await invokeTool(mapping, [vector.symbolPayloadInput], {
    fetchResponse: {
      ok: true,
      status: 200,
      body: bodyStream(oversizeChunks, oversizeStats),
      text: async () => { throw new Error('response.text() must never be called'); },
    },
  });
  assert.strictEqual(oversizeBody.isError, true);
  assert.strictEqual(JSON.parse(oversizeBody.content[0].text).reasonCode, 'SEMANTIC_SNAPSHOT_TOO_LARGE');
  assert.strictEqual(oversizeStats.readCount, 9,
    'stream consumption must stop on the first byte above 8 MiB');
  assert.strictEqual(oversizeStats.cancelCount, 1);

  const slowBody = await invokeTool(mapping, [vector.symbolPayloadInput], {
    setTimeout: (callback) => setTimeout(callback, 10),
    fetchResponseFactory: (uri, init) => ({
      ok: true,
      status: 200,
      body: {
        getReader() {
          return {
            read() {
              return new Promise((resolve, reject) => {
                init.signal.addEventListener('abort', () => reject(new Error('fixture body aborted')), { once: true });
              });
            },
            async cancel() {},
            releaseLock() {},
          };
        },
      },
    }),
  });
  assert.strictEqual(slowBody.isError, true,
    'the REST timeout must remain active until the complete body has been consumed');
  assert.strictEqual(JSON.parse(slowBody.content[0].text).reasonCode, 'SEMANTIC_SNAPSHOT_FAILED');

  // The MCP transport accepts one JSON line up to 1 MiB. Even an inner
  // response consisting entirely of the two JSON characters that expand on
  // outer serialization (quote and backslash) must stay below that boundary.
  const worstCaseInner = '\"\\'.repeat((480 * 1024) / 2);
  assert.strictEqual(Buffer.byteLength(worstCaseInner, 'utf8'), 480 * 1024);
  const outerEnvelope = JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    result: { content: [{ type: 'text', text: worstCaseInner }], isError: false },
  });
  assert(
    Buffer.byteLength(outerEnvelope, 'utf8') < 1024 * 1024,
    '480 KiB compact response must remain below the 1 MiB MCP JSON-line cap after worst-case escaping'
  );

  console.log('semantic tool final-dirty/stream-timeout/8-MiB/compact-canonical regression: OK');
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
