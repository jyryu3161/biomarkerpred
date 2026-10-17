import { useState, useEffect } from "react";
import { readImageBase64 } from "@/lib/tauri/commands";
import type { EnrichmentCategory } from "@/types/pathway";
import { ENRICHMENT_SHORT_LABELS } from "@/types/pathway";
import { useOraStore } from "@/stores/oraStore";

export function EnrichmentPlotViewer() {
  const resultDir = useOraStore((s) => s.resultDir);
  const status = useOraStore((s) => s.status);
  const activeCategory = useOraStore((s) => s.activeCategory);
  const setActiveCategory = useOraStore((s) => s.setActiveCategory);
  const activePlotType = useOraStore((s) => s.activePlotType);
  const setActivePlotType = useOraStore((s) => s.setActivePlotType);

  const [imageData, setImageData] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const categories: EnrichmentCategory[] = [
    "go_bp",
    "go_mf",
    "go_cc",
    "kegg",
    "reactome",
  ];

  // Combined plot options
  const [showCombined, setShowCombined] = useState<
    "none" | "cnetplot" | "emapplot"
  >("none");

  useEffect(() => {
    if (!resultDir || status !== "completed") {
      setImageData(null);
      return;
    }

    let plotPath: string;
    if (showCombined !== "none") {
      plotPath = `${resultDir}/figures/${showCombined}.svg`;
    } else {
      plotPath = `${resultDir}/figures/${activeCategory}_${activePlotType}.svg`;
    }

    setError(null);
    readImageBase64(plotPath)
      .then((data: string) => {
        setImageData(`data:image/svg+xml;base64,${data}`);
      })
      .catch(() => {
        // Try PNG fallback
        const pngPath = plotPath.replace(".svg", ".png");
        readImageBase64(pngPath)
          .then((data: string) => {
            setImageData(`data:image/png;base64,${data}`);
          })
          .catch(() => {
            setError("No plot available for this category");
            setImageData(null);
          });
      });
  }, [resultDir, status, activeCategory, activePlotType, showCombined]);

  if (status !== "completed") return null;

  return (
    <div className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">Enrichment Plots</h3>

      {/* Category tabs */}
      <div className="flex gap-1 flex-wrap mb-2">
        {categories.map((cat) => (
          <button
            key={cat}
            onClick={() => {
              setActiveCategory(cat);
              setShowCombined("none");
            }}
            className={`px-3 py-1.5 text-xs rounded-md transition-colors ${
              activeCategory === cat && showCombined === "none"
                ? "bg-primary/10 text-primary border border-primary/40 font-medium"
                : "text-muted-foreground hover:text-foreground hover:bg-muted/50 border border-transparent"
            }`}
          >
            {ENRICHMENT_SHORT_LABELS[cat]}
          </button>
        ))}
        <div className="w-px bg-border mx-1" />
        <button
          onClick={() => setShowCombined("cnetplot")}
          className={`px-3 py-1.5 text-xs rounded-md transition-colors ${
            showCombined === "cnetplot"
              ? "bg-primary/10 text-primary border border-primary/40 font-medium"
              : "text-muted-foreground hover:text-foreground hover:bg-muted/50 border border-transparent"
          }`}
        >
          Gene-Pathway
        </button>
        <button
          onClick={() => setShowCombined("emapplot")}
          className={`px-3 py-1.5 text-xs rounded-md transition-colors ${
            showCombined === "emapplot"
              ? "bg-primary/10 text-primary border border-primary/40 font-medium"
              : "text-muted-foreground hover:text-foreground hover:bg-muted/50 border border-transparent"
          }`}
        >
          Pathway Similarity
        </button>
      </div>

      {/* Plot type toggle (only for per-category) */}
      {showCombined === "none" && (
        <div className="flex gap-1 mb-3">
          {(["dotplot", "barplot"] as const).map((pt) => (
            <button
              key={pt}
              onClick={() => setActivePlotType(pt)}
              className={`px-2.5 py-1 text-[11px] rounded transition-colors ${
                activePlotType === pt
                  ? "bg-muted text-foreground font-medium"
                  : "text-muted-foreground hover:bg-muted/50"
              }`}
            >
              {pt === "dotplot" ? "Dot Plot" : "Bar Plot"}
            </button>
          ))}
        </div>
      )}

      {/* Plot display */}
      {error && <p className="text-xs text-muted-foreground mb-2">{error}</p>}
      <div className="bg-muted/20 rounded min-h-[300px] flex items-center justify-center">
        {imageData ? (
          <img
            src={imageData}
            alt="Enrichment plot"
            className="max-w-full max-h-[500px] object-contain"
          />
        ) : (
          <p className="text-sm text-muted-foreground">
            {error || "Loading plot..."}
          </p>
        )}
      </div>
    </div>
  );
}
