  // ctrlX semantic snapshot contract v1 (2026-08-27)
  // Actual-only, read-only producer. Acceptance remains a Runner decision
  // against an action-bound, reviewed semantic baseline.
  s.tool(
    'get_ctrlx_semantic_snapshot',
    'Read deterministic actual ctrlX I/O mappings and the official PLE REST Symbol Configuration state. This tool never saves or mutates a project.',
    {
      projectFilePath: z.string().describe('Path to the exact currently-open PLC project.'),
      mappingScopes: z.array(z.object({
        devicePath: z.string().min(1),
        recursive: z.literal(true),
        includeAllMappableChannels: z.literal(true),
      })).max(64).optional().default([]),
      mappingTargets: z.array(z.object({
        devicePath: z.string().min(1),
        channelPath: z.string().min(1),
      })).max(512).optional().default([]),
      symbolApplicationPath: z.string().min(1).describe("Application path below /devices, e.g. 'Device/Plc Logic/Application'."),
    },
    async (args: {
      projectFilePath: string;
      mappingScopes: Array<{ devicePath: string; recursive: true; includeAllMappableChannels: true }>;
      mappingTargets: Array<{ devicePath: string; channelPath: string }>;
      symbolApplicationPath: string;
    }) => {
      const contractId = 'ctrlx-semantic-snapshot-v1';
      const producer = 'codesys-persistent.get_ctrlx_semantic_snapshot';
      const escProj = resolvePath(args.projectFilePath, workspaceDir);
      const hashUtf8 = (value: string): string => require('crypto')
        .createHash('sha256')
        .update(value, 'utf8')
        .digest('hex');
      const safeReason = (value: unknown): string => {
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
      const failure = (reason: unknown, reasonCode = 'SEMANTIC_SNAPSHOT_FAILED') => ({
        content: [{
          type: 'text' as const,
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
      const validPath = (value: string): boolean => {
        const segments = value.split('/');
        return segments.length > 0 && segments.every((segment) => segment.length > 0 && segment !== '.' && segment !== '..');
      };
      const canonicalize = (value: any): any => {
        if (Array.isArray(value)) return value.map(canonicalize);
        if (value !== null && typeof value === 'object') {
          const result: Record<string, any> = {};
          for (const key of Object.keys(value).sort()) result[key] = canonicalize(value[key]);
          return result;
        }
        return value;
      };
      const canonicalJson = (value: any): string => JSON.stringify(canonicalize(value));
      const sha256 = (value: any): string => require('crypto')
        .createHash('sha256')
        .update(canonicalJson(value), 'utf8')
        .digest('hex');
      const summarizeJsonShape = (value: any): Record<string, any> => {
        const summary = { objectCount: 0, arrayCount: 0, scalarCount: 0, nodeCount: 0, maxDepth: 0 };
        const walk = (item: any, depth: number): void => {
          summary.nodeCount += 1;
          summary.maxDepth = Math.max(summary.maxDepth, depth);
          if (Array.isArray(item)) {
            summary.arrayCount += 1;
            for (const child of item) walk(child, depth + 1);
          } else if (item !== null && typeof item === 'object') {
            summary.objectCount += 1;
            for (const key of Object.keys(item).sort()) walk(item[key], depth + 1);
          } else {
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
          recursive: true as const,
          includeAllMappableChannels: true as const,
        }));
        const targets = args.mappingTargets.map((target) => ({
          devicePath: sanitizePouPath(target.devicePath),
          channelPath: target.channelPath.trim(),
        }));
        const sanApp = sanitizePouPath(args.symbolApplicationPath);
        if (scopes.length === 0 && targets.length === 0) {
          return failure('At least one mapping scope or explicit mapping target is required.');
        }
        if (scopes.some((scope) => !validPath(scope.devicePath)) ||
            targets.some((target) => !validPath(target.devicePath) || target.channelPath.length === 0) ||
            !validPath(sanApp)) {
          return failure('A semantic snapshot path is empty, relative, or contains a dot segment.');
        }
        const scopePayload = Buffer.from(JSON.stringify(scopes), 'utf8').toString('base64');
        const targetPayload = Buffer.from(JSON.stringify(targets), 'utf8').toString('base64');

        const readMappings = async (): Promise<any> => {
          const script = scriptManager.prepareScriptWithHelpers(
            'get_ctrlx_semantic_snapshot',
            {
              PROJECT_FILE_PATH: escProj,
              MAPPING_SCOPES_B64: scopePayload,
              MAPPING_TARGETS_B64: targetPayload,
            },
            ['_text_utils', 'require_project_open', 'find_object_by_path']
          );
          const result = await executor.executeScript(script, 60_000);
          if (!result.success || !result.output.includes('SCRIPT_SUCCESS')) {
            const output = String(result.output ?? '');
            const errorText = String(result.error ?? '');
            throw new Error(
              `Mapping snapshot script failed; success=${result.success === true}; ` +
              `outputByteCount=${Buffer.byteLength(output, 'utf8')}; outputSha256=${hashUtf8(output)}; ` +
              `errorByteCount=${Buffer.byteLength(errorText, 'utf8')}; errorSha256=${hashUtf8(errorText)}.`
            );
          }
          const parsed = parseResultJson<any>(result.output);
          if (!parsed.ok) throw new Error('Mapping snapshot returned no valid RESULT_JSON block.');
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
            Array.isArray(data.mappings) && data.mappings.length === data.recordCount &&
            data.traversalFailureCount === 0 &&
            data.recordsComplete === true;
          if (!contractValid) throw new Error('Mapping snapshot contract is incomplete, dirty, or unverified.');
          return data;
        };

        const appSegments = sanApp.split('/');
        const restPath = `/plc/engineering/api/v2/devices/${appSegments.map(encodeURIComponent).join('/')}/symbol-config`;
        const readBoundedResponseBody = async (response: Response): Promise<{ body: string; rawPayloadByteCount: number }> => {
          const maximumBytes = 8 * 1024 * 1024;
          if (!response.body || typeof response.body.getReader !== 'function') {
            throw new Error('Symbol Configuration REST GET exposed no readable response body stream.');
          }
          const reader = response.body.getReader();
          const chunks: Buffer[] = [];
          let rawPayloadByteCount = 0;
          try {
            while (true) {
              const next = await reader.read();
              if (next.done) break;
              if (!next.value) throw new Error('Symbol Configuration REST body stream returned an empty chunk.');
              const chunk = Buffer.from(next.value);
              rawPayloadByteCount += chunk.byteLength;
              if (rawPayloadByteCount > maximumBytes) {
                try { await reader.cancel('semantic snapshot body limit exceeded'); } catch { /* best effort */ }
                throw new Error('SEMANTIC_SNAPSHOT_TOO_LARGE: Symbol Configuration REST response exceeded 8 MiB.');
              }
              chunks.push(chunk);
            }
          } finally {
            try { reader.releaseLock(); } catch { /* best effort */ }
          }
          return {
            body: Buffer.concat(chunks, rawPayloadByteCount).toString('utf8'),
            rawPayloadByteCount,
          };
        };
        const readSymbolConfig = async (): Promise<{ httpStatus: number; rawPayloadByteCount: number; payload: any; canonicalJson: string }> => {
          const controller = new AbortController();
          const timer = setTimeout(() => controller.abort(), 30_000);
          let response: Response;
          let body: string;
          let rawPayloadByteCount: number;
          try {
            // PLE's local extension validates the HTTP Host header.  The
            // loopback address reaches the listener but is rejected with
            // HTTP 400; the documented localhost authority is required.
            response = await fetch(`http://localhost:9002${restPath}`, { method: 'GET', signal: controller.signal });
            ({ body, rawPayloadByteCount } = await readBoundedResponseBody(response));
          } finally {
            clearTimeout(timer);
          }
          if (!response.ok) {
            throw new Error(
              `Symbol Configuration REST GET failed; httpStatus=${response.status}; ` +
              `bodyByteCount=${rawPayloadByteCount}; bodySha256=${hashUtf8(body)}.`
            );
          }
          try {
            const payload = canonicalize(JSON.parse(body));
            return { httpStatus: response.status, rawPayloadByteCount, payload, canonicalJson: canonicalJson(payload) };
          } catch {
            // PLE 2.6.8 labels this response application/json, but valid IEC
            // type text may contain quotes that the extension does not escape.
            // Preserve an exact, bounded semantic proof by hashing normalized
            // UTF-8 text as a JSON string; never forward the full payload.
            const normalizedText = body.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
            if (normalizedText.length === 0) throw new Error('Symbol Configuration REST GET returned an empty payload.');
            return {
              httpStatus: response.status,
              rawPayloadByteCount,
              payload: normalizedText,
              canonicalJson: JSON.stringify(normalizedText),
            };
          }
        };

        // A Clean Build makes PLE rebuild Symbol Configuration asynchronously.
        // The first successful REST response can therefore be a transient,
        // incomplete payload even though the project is clean.  Discard exactly
        // one bounded warm-up read, then retain the strict authoritative
        // double-read gate below.  A difference between the two authoritative
        // reads still fails closed.
        await readSymbolConfig();
        const mappingBefore = await readMappings();
        const symbolBefore = await readSymbolConfig();
        const mappingAfter = await readMappings();
        const symbolAfter = await readSymbolConfig();
        // The final ScriptEngine probe intentionally runs after every REST
        // read.  It closes the race where an unsaved IDE edit could occur
        // after mappingAfter and otherwise be sealed as a clean snapshot.
        const mappingFinal = await readMappings();
        const mappingStable = canonicalJson({ scopes: mappingBefore.scopes, records: mappingBefore.mappings }) ===
            canonicalJson({ scopes: mappingAfter.scopes, records: mappingAfter.mappings }) &&
          canonicalJson({ scopes: mappingAfter.scopes, records: mappingAfter.mappings }) ===
            canonicalJson({ scopes: mappingFinal.scopes, records: mappingFinal.mappings });
        const symbolStable = symbolBefore.canonicalJson === symbolAfter.canonicalJson;
        if (!mappingStable || !symbolStable || mappingBefore.projectFilePath !== mappingAfter.projectFilePath ||
            mappingAfter.projectFilePath !== mappingFinal.projectFilePath ||
            mappingBefore.projectDirty !== mappingAfter.projectDirty ||
            mappingAfter.projectDirty !== mappingFinal.projectDirty) {
          throw new Error('Project, I/O mapping, or Symbol Configuration facts changed during the double-read snapshot.');
        }

        const mappingRecords = mappingBefore.mappings.map((record: any) => {
          const fact: Record<string, any> = {};
          for (const key of Object.keys(record)) {
            if (key !== 'resolved' && key !== 'mappingReadable' && key !== 'error') fact[key] = record[key];
          }
          return fact;
        }).sort((left: any, right: any) => {
          const leftIdentity = String(left.channelIdentity ?? '');
          const rightIdentity = String(right.channelIdentity ?? '');
          if (leftIdentity < rightIdentity) return -1;
          if (leftIdentity > rightIdentity) return 1;
          const leftJson = canonicalJson(left);
          const rightJson = canonicalJson(right);
          return leftJson < rightJson ? -1 : (leftJson > rightJson ? 1 : 0);
        });
        const mappingFacts = canonicalize({
          scopeCount: mappingBefore.scopeCount,
          explicitTargetCount: mappingBefore.explicitTargetCount,
          recordCount: mappingBefore.recordCount,
          recordLimit: mappingBefore.recordLimit,
          scopes: mappingBefore.scopes.map((scope: any) => ({
            scopeIndex: scope.scopeIndex,
            devicePath: scope.devicePath,
            recursive: scope.recursive,
            rootName: scope.rootName,
            recordCount: scope.recordCount,
          })),
          records: mappingRecords,
        });
        const symbolPayloadSha256 = require('crypto')
          .createHash('sha256')
          .update(symbolBefore.canonicalJson, 'utf8')
          .digest('hex');
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
          projectFilePath: mappingBefore.projectFilePath,
          dirtyStateVerified: true,
          projectDirty: false,
          recordsComplete: true,
          stableAcrossRead: true,
          sources: {
            mapping: 'PLE ScriptEngine double-read plus final dirty-state guard',
            symbolConfig: {
              source: 'PLE REST api v2 warm-up plus authoritative double-read',
              applicationPath: sanApp,
              endpointPath: restPath,
              httpStatus: symbolBefore.httpStatus,
              rawPayloadByteCount: symbolBefore.rawPayloadByteCount,
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
        if (responseByteCount > 480 * 1024) {
          return failure(`Semantic snapshot response is ${responseByteCount} bytes; limit is 491520 bytes.`, 'SEMANTIC_SNAPSHOT_TOO_LARGE');
        }
        return { content: [{ type: 'text' as const, text: responseJson }], isError: false };
      } catch (error) {
        const message = safeReason(error instanceof Error ? error.message : error);
        return failure(
          message,
          message.startsWith('SEMANTIC_SNAPSHOT_TOO_LARGE:') ? 'SEMANTIC_SNAPSHOT_TOO_LARGE' : 'SEMANTIC_SNAPSHOT_FAILED'
        );
      }
    }
  );
