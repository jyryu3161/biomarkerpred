import { useEffect, useRef } from "react";
import { useOraStore } from "@/stores/oraStore";
import { useAnalysisStore } from "@/stores/analysisStore";
import { OraControlPanel } from "@/components/pathway/OraControlPanel";
import { PpiNetworkViewer } from "@/components/pathway/PpiNetworkViewer";
import { EnrichmentPlotViewer } from "@/components/pathway/EnrichmentPlotViewer";
import { EnrichmentTable } from "@/components/pathway/EnrichmentTable";
import { saveFile } from "@/lib/tauri/commands";

function OraLogPanel() {
  const logs = useOraStore((s) => s.logs);
  const status = useOraStore((s) => s.status);
  const progress = useOraStore((s) => s.progress);
  const logEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    logEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [logs.length]);

  if (status === "idle" && logs.length === 0) return null;

  return (
    <div className="border border-border rounded-lg p-4">
      <div className="flex items-center justify-between mb-2">
        <h3 className="text-sm font-medium">Analysis Log</h3>
        {status === "running" && progress.total > 0 && (
          <div className="flex items-center gap-3">
            <div className="w-32 h-2 bg-muted rounded-full overflow-hidden">
              <div
                className="h-full bg-primary rounded-full transition-all duration-300"
                style={{
                  width: `${Math.round((progress.current / progress.total) * 100)}%`,
                }}
              />
            </div>
            <span className="text-xs text-muted-foreground font-mono">
              {progress.current}/{progress.total} — {progress.message}
            </span>
          </div>
        )}
      </div>
      <div className="bg-muted/30 rounded p-3 h-36 overflow-y-auto font-mono text-xs space-y-0.5">
        {logs.length === 0 ? (
          <p className="text-muted-foreground">No log output yet.</p>
        ) : (
          logs.map((line, i) => (
            <div key={i} className="text-muted-foreground whitespace-pre-wrap">
              {line}
            </div>
          ))
        )}
        <div ref={logEndRef} />
      </div>
    </div>
  );
}

function OraExportPanel() {
  const resultDir = useOraStore((s) => s.resultDir);
  const status = useOraStore((s) => s.status);

  if (status !== "completed" || !resultDir) return null;

  const csvFiles = [
    { name: "GO: Biological Process", file: "ora_go_bp.csv" },
    { name: "GO: Molecular Function", file: "ora_go_mf.csv" },
    { name: "GO: Cellular Component", file: "ora_go_cc.csv" },
    { name: "KEGG Pathways", file: "ora_kegg.csv" },
    { name: "Reactome Pathways", file: "ora_reactome.csv" },
    { name: "PPI Network Edges", file: "ppi_network.csv" },
    { name: "Gene ID Mapping", file: "gene_mapping.csv" },
  ];

  const handleSave = async (file: string) => {
    const sourcePath = `${resultDir}/${file}`;
    try {
      await saveFile(sourcePath, file);
    } catch {
      // Save dialog cancelled
    }
  };

  return (
    <div className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">Export Results</h3>
      <div className="space-y-1">
        {csvFiles.map(({ name, file }) => (
          <div
            key={file}
            className="flex items-center justify-between px-2 py-1.5 rounded hover:bg-muted/30"
          >
            <span className="text-sm">{name}</span>
            <button
              onClick={() => handleSave(file)}
              className="px-2.5 py-1 text-xs font-medium rounded border border-green-300 text-green-700 hover:bg-green-50 dark:border-green-700 dark:text-green-400 dark:hover:bg-green-950"
            >
              CSV
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}

function EnrichmentSummaryCards() {
  const summary = useOraStore((s) => s.summary);
  const status = useOraStore((s) => s.status);

  if (status !== "completed" || !summary) return null;

  const categories = [
    { key: "go_bp", label: "GO:BP", color: "text-blue-600 dark:text-blue-400" },
    { key: "go_mf", label: "GO:MF", color: "text-indigo-600 dark:text-indigo-400" },
    { key: "go_cc", label: "GO:CC", color: "text-violet-600 dark:text-violet-400" },
    { key: "kegg", label: "KEGG", color: "text-emerald-600 dark:text-emerald-400" },
    { key: "reactome", label: "Reactome", color: "text-amber-600 dark:text-amber-400" },
  ] as const;

  return (
    <div className="grid grid-cols-5 gap-2">
      {categories.map(({ key, label, color }) => {
        const r = summary.results[key];
        return (
          <div
            key={key}
            className="border border-border rounded-lg p-3 text-center"
          >
            <div className={`text-lg font-bold ${color}`}>
              {r.significantTerms}
            </div>
            <div className="text-xs text-muted-foreground">{label}</div>
            {r.topTerm && (
              <div className="text-[10px] text-muted-foreground mt-1 truncate" title={r.topTerm}>
                {r.topTerm}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

export function PathwayAnalysisPage() {
  const oraStatus = useOraStore((s) => s.status);
  const analysisStatus = useAnalysisStore((s) => s.status);

  const showResults = oraStatus === "completed";

  return (
    <div className="flex-1 overflow-y-auto p-6 space-y-6">
      <h2 className="text-lg font-semibold">Pathway Analysis</h2>

      <OraControlPanel />

      {(oraStatus === "running" || oraStatus === "failed" || oraStatus === "completed") && (
        <OraLogPanel />
      )}

      {showResults && (
        <>
          <EnrichmentSummaryCards />
          <PpiNetworkViewer />
          <EnrichmentPlotViewer />
          <EnrichmentTable />
          <OraExportPanel />
        </>
      )}

      {oraStatus === "idle" && analysisStatus !== "completed" && (
        <div className="border border-border rounded-lg p-8 text-center">
          <p className="text-muted-foreground">
            Run a drug response analysis first, then use this page to explore
            pathway enrichment of your candidate genes.
          </p>
        </div>
      )}
    </div>
  );
}
