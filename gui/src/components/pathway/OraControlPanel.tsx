import { useState, useEffect } from "react";
import { useAnalysisStore } from "@/stores/analysisStore";
import { useOraStore, EVIDENCE_LABELS, type EvidenceType } from "@/stores/oraStore";
import { useConfigStore } from "@/stores/configStore";
import { readTextFile, runOra, cancelOra } from "@/lib/tauri/commands";

/** Extract all unique genes from auc_iterations.csv */
function parseGenesFromAucCsv(raw: string): string[] {
  const lines = raw.trim().split(/\r?\n/);
  if (lines.length < 2) return [];

  const unquote = (s: string) => s.trim().replace(/^"(.*)"$/, "$1");
  const headers = lines[0]
    .split(",")
    .map((h) => unquote(h).toLowerCase().replace(/[_\s]/g, ""));

  const geneCol = ["selectedgenes", "genes", "selectedgene", "gene"]
    .map((c) => headers.indexOf(c))
    .find((i) => i !== -1);

  if (geneCol === undefined || geneCol === -1) return [];

  const allGenes = new Set<string>();
  for (let i = 1; i < lines.length; i++) {
    const fields = lines[i].split(",").map(unquote);
    const geneStr = fields[geneCol] ?? "";
    for (const g of geneStr.split(/[;,]+/)) {
      const trimmed = g.trim();
      if (trimmed && trimmed !== "+") allGenes.add(trimmed);
    }
  }
  return Array.from(allGenes).sort();
}

/**
 * Extract genes from Final_Stepwise_Total.csv
 * Format: Variable column contains "GENE1 + GENE2 + GENE3"
 */
function parseGenesFromStepwiseCsv(raw: string): string[] {
  const lines = raw.trim().split(/\r?\n/);
  if (lines.length < 2) return [];

  const unquote = (s: string) => s.trim().replace(/^"(.*)"$/, "$1");
  const headers = lines[0]
    .split(",")
    .map((h) => unquote(h).toLowerCase());

  const varCol = headers.indexOf("variable");
  if (varCol === -1) return [];

  const allGenes = new Set<string>();
  for (let i = 1; i < lines.length; i++) {
    const fields = lines[i].split(",").map(unquote);
    const varStr = fields[varCol] ?? "";
    // Split by " + " (gene formula format)
    for (const g of varStr.split(/\s*\+\s*/)) {
      const trimmed = g.trim();
      if (trimmed) allGenes.add(trimmed);
    }
  }
  return Array.from(allGenes).sort();
}

export function OraControlPanel() {
  const outputDir = useAnalysisStore((s) => s.outputDir);
  const analysisStatus = useAnalysisStore((s) => s.status);
  const backend = useConfigStore((s) => s.backend);
  const oraStatus = useOraStore((s) => s.status);
  const ppiConfidence = useOraStore((s) => s.ppiConfidence);
  const setPpiConfidence = useOraStore((s) => s.setPpiConfidence);
  const ppiEvidenceTypes = useOraStore((s) => s.ppiEvidenceTypes);
  const toggleEvidenceType = useOraStore((s) => s.toggleEvidenceType);
  const setStatus = useOraStore((s) => s.setStatus);
  const setResultDir = useOraStore((s) => s.setResultDir);
  const appendLog = useOraStore((s) => s.appendLog);
  const setProgress = useOraStore((s) => s.setProgress);

  const [genes, setGenes] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);
  const [expanded, setExpanded] = useState(false);

  // Load genes: try auc_iterations.csv first, fallback to Final_Stepwise_Total.csv
  useEffect(() => {
    if (!outputDir || analysisStatus !== "completed") {
      setGenes([]);
      return;
    }
    setLoading(true);

    // Try auc_iterations.csv first, then StepBin or StepSurv Final_Stepwise_Total.csv
    readTextFile(`${outputDir}/auc_iterations.csv`)
      .then((content) => {
        const parsed = parseGenesFromAucCsv(content);
        if (parsed.length > 0) {
          setGenes(parsed);
          return;
        }
        throw new Error("empty");
      })
      .catch(() => {
        // Fallback: Final_Stepwise_Total.csv (Variable column: "GENE1 + GENE2 + GENE3")
        // Try StepBin (binary) first, then StepSurv (survival)
        return readTextFile(`${outputDir}/StepBin/Final_Stepwise_Total.csv`)
          .then((content) => {
            const parsed = parseGenesFromStepwiseCsv(content);
            if (parsed.length > 0) { setGenes(parsed); return; }
            throw new Error("empty");
          })
          .catch(() =>
            readTextFile(`${outputDir}/StepSurv/Final_Stepwise_Total.csv`)
              .then((content) => setGenes(parseGenesFromStepwiseCsv(content)))
              .catch(() => setGenes([]))
          );
      })
      .finally(() => setLoading(false));
  }, [outputDir, analysisStatus]);

  const handleRun = async () => {
    if (genes.length === 0 || !outputDir) return;

    const pathwayDir = `${outputDir}/pathway`;
    setResultDir(pathwayDir);
    setStatus("running");
    setProgress(0, 0, "");
    // Clear previous logs
    useOraStore.setState({ logs: [] });
    appendLog(`Starting pathway analysis with ${genes.length} candidate genes...`);

    try {
      await runOra(genes, pathwayDir, ppiConfidence, 9606, backend, ppiEvidenceTypes);
    } catch (e) {
      appendLog(`Failed to start: ${e}`);
      setStatus("failed");
    }
  };

  const handleCancel = async () => {
    try {
      await cancelOra();
      appendLog("Pathway analysis cancelled by user");
      setStatus("idle");
    } catch (e) {
      appendLog(`Cancel failed: ${e}`);
    }
  };

  const isRunning = oraStatus === "running";
  const canRun =
    genes.length > 0 && !isRunning && analysisStatus === "completed";

  return (
    <div className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">Pathway Analysis Control</h3>

      {/* Gene info */}
      <div className="mb-3">
        {loading ? (
          <p className="text-xs text-muted-foreground">
            Loading candidate genes...
          </p>
        ) : genes.length > 0 ? (
          <div>
            <div className="flex items-center gap-2 mb-1">
              <span className="text-xs font-medium">
                {genes.length} candidate genes detected
              </span>
              <button
                onClick={() => setExpanded(!expanded)}
                className="text-xs text-primary hover:underline"
              >
                {expanded ? "Hide" : "Show"}
              </button>
            </div>
            {expanded && (
              <div className="bg-muted/30 rounded p-2 text-xs font-mono max-h-24 overflow-y-auto">
                {genes.join(", ")}
              </div>
            )}
          </div>
        ) : analysisStatus === "completed" ? (
          <p className="text-xs text-amber-600 dark:text-amber-400">
            No candidate genes found in results. Check AUC table.
          </p>
        ) : (
          <p className="text-xs text-muted-foreground">
            Run an analysis first to generate candidate genes.
          </p>
        )}
      </div>

      {/* PPI Confidence slider */}
      <div className="mb-4">
        <div className="flex items-center justify-between mb-1">
          <label className="text-xs text-muted-foreground">
            PPI Confidence (STRING DB)
          </label>
          <span className="text-xs font-mono font-medium">
            {ppiConfidence.toFixed(2)}
          </span>
        </div>
        <input
          type="range"
          min={0}
          max={1.0}
          step={0.05}
          value={ppiConfidence}
          onChange={(e) => setPpiConfidence(parseFloat(e.target.value))}
          disabled={isRunning}
          className="w-full h-1.5 bg-muted rounded-lg appearance-none cursor-pointer accent-primary disabled:opacity-50"
        />
        <div className="flex justify-between text-[10px] text-muted-foreground mt-0.5">
          <span>0.00 (all interactions)</span>
          <span>1.00 (high confidence)</span>
        </div>
      </div>

      {/* PPI Evidence Types */}
      <div className="mb-4">
        <label className="text-xs text-muted-foreground mb-1.5 block">
          PPI Evidence Types
        </label>
        <div className="grid grid-cols-4 gap-x-3 gap-y-1">
          {(Object.entries(EVIDENCE_LABELS) as [EvidenceType, string][]).map(
            ([key, label]) => (
              <label
                key={key}
                className="flex items-center gap-1.5 text-xs cursor-pointer"
              >
                <input
                  type="checkbox"
                  checked={ppiEvidenceTypes.includes(key)}
                  onChange={() => toggleEvidenceType(key)}
                  disabled={isRunning}
                  className="rounded border-border accent-primary h-3.5 w-3.5"
                />
                <span className={ppiEvidenceTypes.includes(key) ? "text-foreground" : "text-muted-foreground"}>
                  {label}
                </span>
              </label>
            ),
          )}
        </div>
        {ppiEvidenceTypes.length === 0 && (
          <p className="text-[10px] text-amber-600 dark:text-amber-400 mt-1">
            At least one evidence type required. PPI will be skipped.
          </p>
        )}
      </div>

      {/* Action buttons */}
      <div className="flex gap-2">
        <button
          onClick={handleRun}
          disabled={!canRun}
          className="px-4 py-2 text-sm font-medium rounded-md bg-primary text-primary-foreground hover:bg-primary/90 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {isRunning ? "Running..." : "Run Pathway Analysis"}
        </button>
        {isRunning && (
          <button
            onClick={handleCancel}
            className="px-4 py-2 text-sm font-medium rounded-md border border-destructive text-destructive hover:bg-destructive/10 transition-colors"
          >
            Cancel
          </button>
        )}
      </div>
    </div>
  );
}
