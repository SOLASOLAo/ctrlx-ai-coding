  // ctrlX clean compile tool contract v1 (2026-08-28)
  // Opt-in semantic rebuild: one application.clean(), then one
  // application.build(). The ordinary compile_project remains the fast path.
  s.tool(
    'clean_compile_project',
    'Performs one explicit application.clean() followed by one application.build(), then returns bounded same-call compiler evidence. Never saves the project.',
    {
      projectFilePath: z.string().describe('Path to the exact currently-open PLC project.'),
    },
    async (args: { projectFilePath: string }) => {
      const contractId = 'ctrlx-clean-compile-v1';
      const producer = 'codesys-persistent.clean_compile_project';
      const escaped = resolvePath(args.projectFilePath, workspaceDir);
      const script = scriptManager.prepareScriptWithHelpers(
        'clean_compile_project',
        { PROJECT_FILE_PATH: escaped },
        ['_text_utils', '_message_utils', 'ensure_project_open']
      );
      const result = await executor.executeScript(script, 900_000);
      const output = String(result.output ?? '');
      const startMarker = '### CLEAN_COMPILE_SUMMARY_START ###';
      const endMarker = '### CLEAN_COMPILE_SUMMARY_END ###';
      const start = output.indexOf(startMarker);
      const end = output.indexOf(endMarker);
      const uniqueMarkers = start >= 0 && end > start &&
        start === output.lastIndexOf(startMarker) &&
        end === output.lastIndexOf(endMarker);
      let summary: any = null;
      if (uniqueMarkers) {
        try {
          summary = JSON.parse(
            output.substring(start + startMarker.length, end).trim()
          );
        } catch {
          summary = null;
        }
      }

      const recordsValid = summary !== null && Array.isArray(summary.records) &&
        summary.records.every((record: any) => record !== null && typeof record === 'object' &&
          record.severity === 'warning' &&
          typeof record.text === 'string' && record.text.trim().length > 0 &&
          Buffer.byteLength(record.text, 'utf8') <= 4096) &&
        summary.records.reduce((total: number, record: any) =>
          total + Buffer.byteLength(record.text, 'utf8'), 0) <= 262144;
      const diagnosticsValid = summary !== null &&
        Array.isArray(summary.diagnosticRows) &&
        summary.diagnosticRows.every((row: any) =>
          typeof row === 'string' && row.trim().length > 0 &&
          Buffer.byteLength(row, 'utf8') <= 2048) &&
        summary.diagnosticRows.length <= 100 &&
        summary.diagnosticRows.reduce((total: number, row: string) =>
          total + Buffer.byteLength(row, 'utf8'), 0) <= 65536;
      const clearResultsValid = summary !== null &&
        Array.isArray(summary.categoryClearResults) &&
        summary.categoryClearResults.length === 2 &&
        summary.categoryClearResults.every((item: any) =>
          item !== null && typeof item === 'object' &&
          (item.category === 'Build' || item.category === 'Additional code checks') &&
          item.clearedAndVerified === true);
      const exactProject = summary !== null &&
        typeof summary.projectFilePath === 'string' &&
        path.resolve(summary.projectFilePath).toLowerCase() === path.resolve(escaped).toLowerCase();
      const countsValid = summary !== null &&
        Number.isInteger(summary.errorCount) && summary.errorCount >= 0 &&
        Number.isInteger(summary.warningCount) && summary.warningCount >= 0 &&
        Number.isInteger(summary.messageCount) &&
        summary.messageCount === summary.errorCount + summary.warningCount &&
        recordsValid && diagnosticsValid &&
        typeof summary.typedRecordsVerified === 'boolean' &&
        typeof summary.warningDetailsComplete === 'boolean' &&
        typeof summary.diagnosticRowsComplete === 'boolean' &&
        ((summary.typedRecordsVerified === true &&
          summary.warningDetailsComplete === true &&
          summary.errorCount === 0 &&
          summary.records.length === summary.warningCount) ||
         (summary.typedRecordsVerified === false &&
          summary.warningDetailsComplete === false &&
          summary.records.length === 0));
      const summaryJson = summary === null ? '' : JSON.stringify(summary);
      const responseSizeValid = Buffer.byteLength(summaryJson, 'utf8') <= 480 * 1024;
      const contractValid = result.success === true &&
        output.includes('SCRIPT_SUCCESS') &&
        uniqueMarkers && countsValid && clearResultsValid && exactProject && responseSizeValid &&
        summary.contractVersion === 1 &&
        summary.contractId === contractId &&
        summary.producer === producer &&
        summary.adapterPatchId === contractId &&
        summary.cleanInvocation === 'application.clean' &&
        summary.buildInvocation === 'application.build' &&
        summary.cleanInvocationCount === 1 &&
        summary.buildInvocationCount === 1 &&
        summary.cleanSucceeded === true &&
        summary.buildSucceeded === true &&
        summary.semanticRebuildVerified === true &&
        summary.messageEvidenceComplete === true &&
        summary.fresh === true &&
        summary.identityPreflightVerified === true &&
        summary.identityPostflightVerified === true &&
        summary.dirtyPreflightVerified === true &&
        summary.dirtyPostflightVerified === true &&
        summary.expectedCategoryCoverageVerified === true &&
        summary.allExpectedCategoriesCleared === true &&
        summary.allExpectedCategoriesRead === true &&
        summary.explicitBuildSummaryVerified === true &&
        summary.patchPreflightVerified === true &&
        summary.verified === true &&
        summary.recordsComplete === true;

      if (!contractValid) {
        return {
          content: [{
            type: 'text' as const,
            text: `Clean compile contract unavailable or rejected for ${escaped}.`,
          }],
          isError: true,
        };
      }
      return {
        content: [{
          type: 'text' as const,
          text: `${startMarker}\n${summaryJson}\n${endMarker}\n` +
            `Clean compilation complete for ${escaped}.\n` +
            `${summary.errorCount} error(s), ${summary.warningCount} warning(s).`,
        }],
        isError: summary.errorCount > 0,
      };
    }
  );
