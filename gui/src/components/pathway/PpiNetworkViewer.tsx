import { useState, useEffect } from "react";
import { readImageBase64, readTextFile } from "@/lib/tauri/commands";
import { useOraStore } from "@/stores/oraStore";
import type { OraSummary } from "@/types/pathway";

export function PpiNetworkViewer() {
  const resultDir = useOraStore((s) => s.resultDir);
  const status = useOraStore((s) => s.status);
  const summary = useOraStore((s) => s.summary);
  const setSummary = useOraStore((s) => s.setSummary);

  const [imageData, setImageData] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Load summary.json
  useEffect(() => {
    if (!resultDir || status !== "completed") {
      setSummary(null);
      return;
    }
    readTextFile(`${resultDir}/summary.json`)
      .then((content) => {
        const data = JSON.parse(content) as OraSummary;
        setSummary(data);
      })
      .catch(() => setSummary(null));
  }, [resultDir, status, setSummary]);

  // Load PPI network plot
  useEffect(() => {
    if (!resultDir || status !== "completed") {
      setImageData(null);
      return;
    }
    setError(null);
    readImageBase64(`${resultDir}/figures/ppi_network.svg`)
      .then((data: string) => {
        setImageData(`data:image/svg+xml;base64,${data}`);
      })
      .catch(() => {
        readImageBase64(`${resultDir}/figures/ppi_network.png`)
          .then((data: string) => {
            setImageData(`data:image/png;base64,${data}`);
          })
          .catch(() => {
            setError("PPI network plot not available");
            setImageData(null);
          });
      });
  }, [resultDir, status]);

  if (status !== "completed") return null;

  return (
    <div className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">
        Protein-Protein Interaction Network
      </h3>

      {/* Summary stats */}
      {summary && (
        <div className="flex gap-4 mb-3 text-xs">
          <div className="px-3 py-1.5 rounded bg-red-500/10 text-red-700 dark:text-red-400 font-medium">
            {summary.candidateGeneCount} candidate genes
          </div>
          <div className="flex items-center text-muted-foreground">→</div>
          <div className="px-3 py-1.5 rounded bg-blue-500/10 text-blue-700 dark:text-blue-400 font-medium">
            {summary.ppiInteractorCount} PPI interactors
          </div>
          <div className="flex items-center text-muted-foreground">→</div>
          <div className="px-3 py-1.5 rounded bg-muted text-foreground font-medium">
            {summary.totalGenesAnalyzed} total genes analyzed
          </div>
        </div>
      )}

      {/* PPI network plot */}
      {error && <p className="text-xs text-muted-foreground mb-2">{error}</p>}
      <div className="bg-muted/20 rounded min-h-[250px] flex items-center justify-center">
        {imageData ? (
          <img
            src={imageData}
            alt="PPI Network"
            className="max-w-full max-h-[450px] object-contain"
          />
        ) : (
          <p className="text-sm text-muted-foreground">
            {error || "Loading PPI network..."}
          </p>
        )}
      </div>
    </div>
  );
}
