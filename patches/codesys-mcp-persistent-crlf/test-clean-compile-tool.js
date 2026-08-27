'use strict';

// Pure-offline execution of the actual dist/server.js insertion asset.
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(
  path.join(__dirname, 'clean_compile_project.tool.js'), 'utf8');

function schemaNode() {
  return { describe() { return this; } };
}

function validSummary(projectPath) {
  const warnings = [
    { severity: 'warning', text: 'fixture warning one' },
    { severity: 'warning', text: 'fixture warning two' },
  ];
  return {
    contractVersion: 1,
    contractId: 'ctrlx-clean-compile-v1',
    producer: 'codesys-persistent.clean_compile_project',
    adapterPatchId: 'ctrlx-clean-compile-v1',
    cleanInvocation: 'application.clean',
    buildInvocation: 'application.build',
    cleanInvocationCount: 1,
    buildInvocationCount: 1,
    cleanSucceeded: true,
    buildSucceeded: true,
    semanticRebuildVerified: true,
    messageEvidenceComplete: true,
    warningDetailsComplete: true,
    fresh: true,
    projectFilePath: projectPath,
    identityPreflightVerified: true,
    identityPostflightVerified: true,
    dirtyPreflightVerified: true,
    dirtyPostflightVerified: true,
    expectedCategoryCoverageVerified: true,
    categoryClearResults: [
      { category: 'Build', clearedAndVerified: true },
      { category: 'Additional code checks', clearedAndVerified: true },
    ],
    allExpectedCategoriesCleared: true,
    allExpectedCategoriesRead: true,
    explicitBuildSummaryVerified: true,
    patchPreflightVerified: true,
    verified: true,
    errorCount: 0,
    warningCount: warnings.length,
    messageCount: warnings.length,
    recordsComplete: true,
    typedRecordsVerified: true,
    diagnosticRowsComplete: true,
    records: warnings,
    diagnosticRows: warnings.map((item) => item.text),
  };
}

async function invoke(mutator, executorOverride) {
  let registered = null;
  let prepared = null;
  let timeout = null;
  const projectPath = path.resolve('clean-tool-fixture.project');
  const summary = validSummary(projectPath);
  if (mutator) mutator(summary);
  const output =
    `### CLEAN_COMPILE_SUMMARY_START ###\n${JSON.stringify(summary)}\n` +
    '### CLEAN_COMPILE_SUMMARY_END ###\nSCRIPT_SUCCESS';
  const context = {
    s: {
      tool(name, description, schema, handler) {
        assert.strictEqual(name, 'clean_compile_project');
        registered = handler;
      },
    },
    zod_1: { z: { string: schemaNode } },
    workspaceDir: process.cwd(),
    resolvePath: (value, workspace) => path.resolve(workspace, value),
    scriptManager: {
      prepareScriptWithHelpers(name, variables, helpers) {
        prepared = { name, variables, helpers };
        return 'fixture-script';
      },
    },
    executor: {
      async executeScript(script, requestedTimeout) {
        timeout = requestedTimeout;
        return executorOverride || { success: true, output, error: null };
      },
    },
    path,
    Buffer,
    console,
  };
  vm.runInNewContext(source, context, {
    filename: 'clean_compile_project.tool.js',
  });
  assert.strictEqual(typeof registered, 'function');
  const response = await registered({ projectFilePath: projectPath });
  return { response, prepared, timeout, projectPath };
}

async function main() {
  assert(!source.includes('clean_all'));
  assert(!source.includes('generate_code'));

  const success = await invoke();
  assert.strictEqual(success.response.isError, false);
  assert.strictEqual(success.prepared.name, 'clean_compile_project');
  assert.deepStrictEqual(
    Array.from(success.prepared.helpers),
    ['_text_utils', '_message_utils', 'ensure_project_open']);
  assert.strictEqual(success.timeout, 900000);
  assert(success.response.content[0].text.includes('semanticRebuildVerified'));

  for (const mutate of [
    (item) => { item.cleanInvocationCount = 2; },
    (item) => { item.cleanInvocation = null; },
    (item) => { item.semanticRebuildVerified = false; },
    (item) => { item.messageEvidenceComplete = false; },
    (item) => { item.dirtyPostflightVerified = false; },
    (item) => { item.recordsComplete = false; },
    (item) => { item.projectFilePath = path.resolve('other.project'); },
    (item) => {
      item.records[0].text = 'x'.repeat(4097);
      item.diagnosticRows[0] = item.records[0].text;
    },
  ]) {
    const rejected = await invoke(mutate);
    assert.strictEqual(rejected.response.isError, true);
  }

  const compileErrors = await invoke((item) => {
    item.errorCount = 1;
    item.messageCount = item.errorCount + item.warningCount;
    item.typedRecordsVerified = false;
    item.warningDetailsComplete = false;
    item.records = [];
  });
  assert.strictEqual(compileErrors.response.isError, true);
  assert(compileErrors.response.content[0].text.includes('CLEAN_COMPILE_SUMMARY_START'),
    'a trusted clean/build summary with compiler errors must remain available');

  const incompleteWarningDetails = await invoke((item) => {
    item.typedRecordsVerified = false;
    item.warningDetailsComplete = false;
    item.records = [];
  });
  assert.strictEqual(incompleteWarningDetails.response.isError, false);
  assert(incompleteWarningDetails.response.content[0].text.includes('warningDetailsComplete'));

  const secret = 'token=DO_NOT_EXPOSE';
  const failed = await invoke(null, {
    success: false,
    output: secret,
    error: secret,
  });
  assert.strictEqual(failed.response.isError, true);
  assert(!failed.response.content[0].text.includes('DO_NOT_EXPOSE'));

  const duplicate = validSummary(path.resolve('clean-tool-fixture.project'));
  const duplicateOutput =
    `### CLEAN_COMPILE_SUMMARY_START ###\n${JSON.stringify(duplicate)}\n` +
    '### CLEAN_COMPILE_SUMMARY_END ###\n' +
    `### CLEAN_COMPILE_SUMMARY_START ###\n${JSON.stringify(duplicate)}\n` +
    '### CLEAN_COMPILE_SUMMARY_END ###\nSCRIPT_SUCCESS';
  const duplicateResult = await invoke(null, {
    success: true,
    output: duplicateOutput,
    error: null,
  });
  assert.strictEqual(duplicateResult.response.isError, true);

  console.log('clean compile MCP response contract regression: OK');
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
