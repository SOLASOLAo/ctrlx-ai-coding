    // ctrlX semantic snapshot contract v1 (2026-08-27)
    // Actual-only, read-only producer. Acceptance remains a Runner decision.
    s.tool('get_ctrlx_semantic_snapshot', 'Read deterministic actual ctrlX I/O mappings and the official PLE REST Symbol Configuration state. This tool never saves or mutates a project.', {
        projectFilePath: zod_1.z.string().describe('Path to the exact currently-open PLC project.'),
        mappingScopes: zod_1.z.array(zod_1.z.object({
            devicePath: zod_1.z.string().min(1),
            recursive: zod_1.z.literal(true),
            includeAllMappableChannels: zod_1.z.literal(true),
        })).max(64).optional().default([]),
        mappingTargets: zod_1.z.array(zod_1.z.object({
            devicePath: zod_1.z.string().min(1),
            channelPath: zod_1.z.string().min(1),
        })).max(512).optional().default([]),
        symbolApplicationPath: zod_1.z.string().min(1).describe("Application path below /devices, e.g. 'Device/Plc Logic/Application'."),
    }, async (args) => {
        const contractId = 'ctrlx-semantic-snapshot-v1';
        const producer = 'codesys-persistent.get_ctrlx_semantic_snapshot';
        const escProj = resolvePath(args.projectFilePath, workspaceDir);
        const hashUtf8 = (value) => require('crypto').createHash('sha256').update(value, 'utf8').digest('hex');
        const safeReason = (value) => {
            const raw = String(value ?? 'Semantic snapshot failed.');
            let result = raw
                .replace(/[\u0000-\u001f\u007f]+/g, ' ')
                .replace(/\b(password|passwd|pwd|secret|token|api[_-]?key|authorization)\s*[:=]\s*[^\s,;]+/gi, '$1=[REDACTED]')
                .replace(/\b(Bearer|Basic)\s+[A-Za-z0-9+/_=.-]+/gi, '$1 [REDACTED]')
                .trim();
            const maximumBytes = 4096;
            if (Buffer.byteLength(result, 'utf8') > maximumBytes) {
                result = Buffer.from(result, 'utf8').subarray(0, maximumBytes).toString('utf8');
                result = result.replace(/\ufffd+$/g, '').trimEnd() + ' [TRUNCATED]';
            }
            return result || 'Semantic snapshot failed.';
        };
        const failure = (reason, reasonCode = 'SEMANTIC_SNAPSHOT_FAILED') => ({
            content: [{
                    type: 'text',
                    text: JSON.stringify({
                        contractVersion: 1,
                        contractId,
                        producer,
                        adapterPatchId: contractId,
                        capturedAtUtc: new Date().toISOString(),
                        projectFilePath: escProj,
                        recordsComplete: false,
                        stableAcrossRead: false,
                        reasonCode,
                        reason: safeReason(reason),
                    }),
                }],
            isError: true,
        });
        const validPath = (value) => {
            const segments = value.split('/');
            return segments.length > 0 && segments.every((segment) => segment.length > 0 && segment !== '.' && segment !== '..');
        };
        const canonicalize = (value) => {
            if (Array.isArray(value))
                return value.map(canonicalize);
            if (value !== null && typeof value === 'object') {
                const result = {};
                for (const key of Object.keys(value).sort())
                    result[key] = canonicalize(value[key]);
                return result;
            }
            return value;
        };
        const canonicalJson = (value) => JSON.stringify(canonicalize(value));
        const sha256 = (value) => require('crypto').createHash('sha256').update(canonicalJson(value), 'utf8').digest('hex');
        const summarizeJsonShape = (value) => {
            const summary = { objectCount: 0, arrayCount: 0, scalarCount: 0, nodeCount: 0, maxDepth: 0 };
            const walk = (item, depth) => {
                summary.nodeCount += 1;
                summary.maxDepth = Math.max(summary.maxDepth, depth);
                if (Array.isArray(item)) {
                    summary.arrayCount += 1;
                    for (const child of item)
                        walk(child, depth + 1);
                }
                else if (item !== null && typeof item === 'object') {
                    summary.objectCount += 1;
                    for (const key of Object.keys(item).sort())
                        walk(item[key], depth + 1);
                }
                else {
                    summary.scalarCount += 1;
                }
            };
            walk(value, 0);
            return {
                rootKind: Array.isArray(value) ? 'array' : (value === null ? 'null' : typeof value),
                topLevelKeys: value !== null && typeof value === 'object' && !Array.isArray(value)
                    ? Object.keys(value).sort()
                    : [],
                ...summary,
            };
        };
        try {
            const scopes = args.mappingScopes.map((scope) => ({
                devicePath: sanitizePouPath(scope.devicePath),
                recursive: true,
                includeAllMappableChannels: true,
            }));
            const targets = args.mappingTargets.map((target) => ({
                devicePath: sanitizePouPath(target.devicePath),
                channelPath: target.channelPath.trim(),
            }));
            const sanApp = sanitizePouPath(args.symbolApplicationPath);
            if (scopes.length === 0 && targets.length === 0)
                return failure('At least one mapping scope or explicit mapping target is required.');
            if (scopes.some((scope) => !validPath(scope.devicePath)) ||
                targets.some((target) => !validPath(target.devicePath) || target.channelPath.length === 0) ||
                !validPath(sanApp)) {
                return failure('A semantic snapshot path is empty, relative, or contains a dot segment.');
            }
            const scopePayload = Buffer.from(JSON.stringify(scopes), 'utf8').toString('base64');
            const targetPayload = Buffer.from(JSON.stringify(targets), 'utf8').toString('base64');
            const readMappings = async () => {
                const script = scriptManager.prepareScriptWithHelpers('get_ctrlx_semantic_snapshot', {
                    PROJECT_FILE_PATH: escProj,
                    MAPPING_SCOPES_B64: scopePayload,
                    MAPPING_TARGETS_B64: targetPayload,
                }, ['_text_utils', 'require_project_open', 'find_object_by_path']);
                const result = await executor.executeScript(script, 60000);
                if (!result.success || !result.output.includes('SCRIPT_SUCCESS')) {
                    const output = String(result.output ?? '');
                    const errorText = String(result.error ?? '');
                    throw new Error(`Mapping snapshot script failed; success=${result.success === true}; ` +
                        `outputByteCount=${Buffer.byteLength(output, 'utf8')}; outputSha256=${hashUtf8(output)}; ` +
                        `errorByteCount=${Buffer.byteLength(errorText, 'utf8')}; errorSha256=${hashUtf8(errorText)}.`);
                }
                const parsed = (0, result_parser_1.parseResultJson)(result.output);
                if (!parsed.ok)
                    throw new Error('Mapping snapshot returned no valid RESULT_JSON block.');
                const data = parsed.data;
                const sameProject = typeof data.projectFilePath === 'string' &&
                    path.resolve(data.projectFilePath).toLowerCase() === path.resolve(escProj).toLowerCase();
                const contractValid = data.contractVersion === 1 &&
                    data.contractId === contractId &&
                    data.producer === producer &&
                    data.adapterPatchId === contractId &&
                    sameProject && data.dirtyStateVerified === true && data.projectDirty === false &&
                    data.dirtyCheckCount === 2 && data.dirtyBefore === false && data.dirtyAfter === false &&
                    data.scopeCount === scopes.length && data.explicitTargetCount === targets.length &&
                    Number.isInteger(data.recordCount) && data.recordCount >= 0 && data.recordCount <= 2048 &&
                    data.recordLimit === 2048 && Array.isArray(data.scopes) && data.scopes.length === scopes.length &&
                    data.scopes.every((scope) => scope !== null && typeof scope === 'object' &&
                        scope.resolved === true && (scope.error === undefined || scope.error === null || scope.error === '')) &&
                    Array.isArray(data.mappings) && data.mappings.length === data.recordCount &&
                    data.mappings.every((record) => record !== null && typeof record === 'object' &&
                        record.resolved === true && record.mappingReadable === true &&
                        (record.error === undefined || record.error === null || record.error === '')) &&
                    data.traversalFailureCount === 0 &&
                    data.recordsComplete === true;
                if (!contractValid)
                    throw new Error('Mapping snapshot contract is incomplete, dirty, or unverified.');
                return data;
            };
            const projectMappingFacts = (data) => {
                const records = data.mappings.map((record) => {
                    const fact = {};
                    for (const key of Object.keys(record)) {
                        if (key !== 'resolved' && key !== 'mappingReadable' && key !== 'error')
                            fact[key] = record[key];
                    }
                    return fact;
                }).sort((left, right) => {
                    const leftIdentity = String(left.channelIdentity ?? '');
                    const rightIdentity = String(right.channelIdentity ?? '');
                    if (leftIdentity < rightIdentity)
                        return -1;
                    if (leftIdentity > rightIdentity)
                        return 1;
                    const leftJson = canonicalJson(left);
                    const rightJson = canonicalJson(right);
                    return leftJson < rightJson ? -1 : (leftJson > rightJson ? 1 : 0);
                });
                return canonicalize({
                    scopeCount: data.scopeCount,
                    explicitTargetCount: data.explicitTargetCount,
                    recordCount: data.recordCount,
                    recordLimit: data.recordLimit,
                    scopes: data.scopes.map((scope) => ({
                        scopeIndex: scope.scopeIndex,
                        devicePath: scope.devicePath,
                        recursive: scope.recursive,
                        rootName: scope.rootName,
                        recordCount: scope.recordCount,
                    })),
                    records,
                });
            };
            const appSegments = sanApp.split('/');
            const restPath = `/plc/engineering/api/v2/devices/${appSegments.map(encodeURIComponent).join('/')}/symbol-config`;
            const readBoundedResponseBody = async (response) => {
                const maximumBytes = 8 * 1024 * 1024;
                if (!response.body || typeof response.body.getReader !== 'function') {
                    throw new Error('Symbol Configuration REST GET exposed no readable response body stream.');
                }
                const reader = response.body.getReader();
                const chunks = [];
                let rawPayloadByteCount = 0;
                try {
                    while (true) {
                        const next = await reader.read();
                        if (next.done)
                            break;
                        if (!next.value)
                            throw new Error('Symbol Configuration REST body stream returned an empty chunk.');
                        const chunk = Buffer.from(next.value);
                        rawPayloadByteCount += chunk.byteLength;
                        if (rawPayloadByteCount > maximumBytes) {
                            try {
                                await reader.cancel('semantic snapshot body limit exceeded');
                            }
                            catch { /* best effort */ }
                            throw new Error('SEMANTIC_SNAPSHOT_TOO_LARGE: Symbol Configuration REST response exceeded 8 MiB.');
                        }
                        chunks.push(chunk);
                    }
                }
                finally {
                    try {
                        reader.releaseLock();
                    }
                    catch { /* best effort */ }
                }
                const rawPayload = Buffer.concat(chunks, rawPayloadByteCount);
                return {
                    body: rawPayload.toString('utf8'),
                    rawPayloadByteCount,
                    rawPayloadSha256: require('crypto').createHash('sha256').update(rawPayload).digest('hex'),
                };
            };
            const readSymbolConfig = async () => {
                const controller = new AbortController();
                const timer = setTimeout(() => controller.abort(), 30000);
                let response;
                let body;
                let rawPayloadByteCount;
                let rawPayloadSha256;
                try {
                    // PLE's local extension validates the HTTP Host header.  The
                    // loopback address reaches the listener but is rejected with
                    // HTTP 400; the documented localhost authority is required.
                    response = await fetch(`http://localhost:9002${restPath}`, { method: 'GET', signal: controller.signal });
                    ({ body, rawPayloadByteCount, rawPayloadSha256 } = await readBoundedResponseBody(response));
                }
                finally {
                    clearTimeout(timer);
                }
                if (!response.ok) {
                    throw new Error(`Symbol Configuration REST GET failed; httpStatus=${response.status}; ` +
                        `bodyByteCount=${rawPayloadByteCount}; bodySha256=${hashUtf8(body)}.`);
                }
                try {
                    const payload = canonicalize(JSON.parse(body));
                    return { httpStatus: response.status, rawPayloadByteCount, rawPayloadSha256, payload, canonicalJson: canonicalJson(payload) };
                }
                catch {
                    // PLE 2.6.8 labels this response application/json, but valid IEC
                    // type text may contain quotes that the extension does not escape.
                    // Preserve an exact, bounded semantic proof by hashing normalized
                    // UTF-8 text as a JSON string; never forward the full payload.
                    const normalizedText = body.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
                    if (normalizedText.length === 0)
                        throw new Error('Symbol Configuration REST GET returned an empty payload.');
                    return {
                        httpStatus: response.status,
                        rawPayloadByteCount,
                        rawPayloadSha256,
                        payload: normalizedText,
                        canonicalJson: JSON.stringify(normalizedText),
                    };
                }
            };
            const summarizeSymbolRead = (value) => ({
                httpStatus: value.httpStatus,
                rawPayloadByteCount: value.rawPayloadByteCount,
                rawPayloadSha256: value.rawPayloadSha256,
                canonicalPayloadByteCount: Buffer.byteLength(value.canonicalJson, 'utf8'),
                canonicalPayloadSha256: hashUtf8(value.canonicalJson),
            });
            // A Clean Build makes PLE rebuild Symbol Configuration asynchronously,
            // sometimes through more than one successful but incomplete response.
            // Require a bounded pair of consecutive equal settle reads, discard the
            // whole settle phase, then retain the independent authoritative
            // triple-read and final ScriptEngine mapping/dirty guard below.
            const maximumSettleReads = 4;
            const settleObservations = [];
            let previousSettle = null;
            let settledSymbol = null;
            for (let index = 0; index < maximumSettleReads; index += 1) {
                const current = await readSymbolConfig();
                settleObservations.push(summarizeSymbolRead(current));
                if (previousSettle !== null && previousSettle.canonicalJson === current.canonicalJson) {
                    settledSymbol = current;
                    break;
                }
                previousSettle = current;
                if (index + 1 < maximumSettleReads)
                    await new Promise((resolve) => setTimeout(resolve, 250));
            }
            if (settledSymbol === null) {
                throw new Error(`Symbol Configuration did not settle within ${maximumSettleReads} bounded reads; ` +
                    `observations=${JSON.stringify(settleObservations)}.`);
            }
            const mappingBefore = await readMappings();
            const symbolBefore = await readSymbolConfig();
            const mappingAfter = await readMappings();
            const symbolAfter = await readSymbolConfig();
            const mappingFinal = await readMappings();
            const symbolFinal = await readSymbolConfig();
            // This last ScriptEngine probe intentionally runs after every REST
            // read. It closes the race where an unsaved IDE edit could occur
            // after symbolFinal and otherwise be sealed as a clean snapshot.
            const mappingGuard = await readMappings();
            const mappingFacts = projectMappingFacts(mappingBefore);
            const mappingAfterFacts = projectMappingFacts(mappingAfter);
            const mappingFinalFacts = projectMappingFacts(mappingFinal);
            const mappingGuardFacts = projectMappingFacts(mappingGuard);
            const mappingHashes = [
                sha256(mappingFacts),
                sha256(mappingAfterFacts),
                sha256(mappingFinalFacts),
                sha256(mappingGuardFacts),
            ];
            const mappingStable = mappingHashes.every((value) => value === mappingHashes[0]);
            const authoritativeSymbols = [symbolBefore, symbolAfter, symbolFinal];
            const symbolSummaries = [summarizeSymbolRead(settledSymbol), ...authoritativeSymbols.map(summarizeSymbolRead)];
            const symbolStable = authoritativeSymbols.every((value) => value.canonicalJson === symbolBefore.canonicalJson);
            const normalizedProjectPaths = [mappingBefore, mappingAfter, mappingFinal, mappingGuard]
                .map((item) => path.resolve(item.projectFilePath).toLowerCase());
            const projectIdentityStable = normalizedProjectPaths.every((value) => value === path.resolve(escProj).toLowerCase());
            const dirtyStable = [mappingBefore, mappingAfter, mappingFinal, mappingGuard].every((item) => item.projectDirty === false);
            if (!mappingStable || !symbolStable || !projectIdentityStable || !dirtyStable) {
                const unstableComponents = [];
                if (!mappingStable)
                    unstableComponents.push('mappingFacts');
                if (!symbolStable)
                    unstableComponents.push('symbolConfig');
                if (!projectIdentityStable)
                    unstableComponents.push('projectIdentity');
                if (!dirtyStable)
                    unstableComponents.push('dirtyState');
                throw new Error(`Semantic snapshot authoritative stability failed; unstableComponents=${unstableComponents.join(',')}; ` +
                    `mappingSha256=${mappingHashes.join(',')}; symbolReads=${JSON.stringify(symbolSummaries)}.`);
            }
            const symbolPayloadSha256 = require('crypto').createHash('sha256').update(symbolBefore.canonicalJson, 'utf8').digest('hex');
            const symbolFacts = canonicalize({
                applicationPath: sanApp,
                canonicalPayloadByteCount: Buffer.byteLength(symbolBefore.canonicalJson, 'utf8'),
                payloadSha256: symbolPayloadSha256,
                shapeSummary: summarizeJsonShape(symbolBefore.payload),
            });
            const canonicalFacts = canonicalize({ mapping: mappingFacts, symbolConfig: symbolFacts });
            const snapshot = {
                contractVersion: 1,
                contractId,
                producer,
                adapterPatchId: contractId,
                capturedAtUtc: new Date().toISOString(),
                projectFilePath: escProj,
                dirtyStateVerified: true,
                projectDirty: false,
                recordsComplete: true,
                stableAcrossRead: true,
                sources: {
                    mapping: 'PLE ScriptEngine semantic-projection triple-read plus final mapping/dirty guard',
                    symbolConfig: {
                        source: 'PLE REST api v2 bounded settle plus authoritative triple-read',
                        applicationPath: sanApp,
                        endpointPath: restPath,
                        httpStatus: symbolBefore.httpStatus,
                        rawPayloadByteCount: symbolBefore.rawPayloadByteCount,
                        rawPayloadSha256: symbolBefore.rawPayloadSha256,
                        settleReadCount: settleObservations.length,
                        authoritativeReadCount: 3,
                    },
                },
                canonicalFacts,
                hashes: {
                    algorithm: 'SHA-256',
                    canonicalization: 'ctrlx-semantic-canonical-json-v1',
                    mappingSha256: sha256(mappingFacts),
                    symbolConfigSha256: sha256(symbolFacts),
                    snapshotSha256: sha256(canonicalFacts),
                },
            };
            const responseJson = JSON.stringify(snapshot);
            const responseByteCount = Buffer.byteLength(responseJson, 'utf8');
            if (responseByteCount > 480 * 1024)
                return failure(`Semantic snapshot response is ${responseByteCount} bytes; limit is 491520 bytes.`, 'SEMANTIC_SNAPSHOT_TOO_LARGE');
            return { content: [{ type: 'text', text: responseJson }], isError: false };
        }
        catch (error) {
            const message = safeReason(error instanceof Error ? error.message : error);
            return failure(message, message.startsWith('SEMANTIC_SNAPSHOT_TOO_LARGE:') ? 'SEMANTIC_SNAPSHOT_TOO_LARGE' : 'SEMANTIC_SNAPSHOT_FAILED');
        }
    });
