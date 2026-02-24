import { useState, useEffect } from "react";
import { useAnalysisStore } from "@/stores/analysisStore";
import { useConfigStore } from "@/stores/configStore";
import { listPresets, loadPreset, readCsvHeader } from "@/lib/tauri/commands";
import type { TcgaPreset } from "@/types/analysis";

export function PresetSelector() {
  const [presets, setPresets] = useState<TcgaPreset[]>([]);
  const [selectedPreset, setSelectedPreset] = useState("");
  const [loading, setLoading] = useState(false);
  const setDataFile = useAnalysisStore((s) => s.setDataFile);
  const setDataInfo = useAnalysisStore((s) => s.setDataInfo);
  const setParam = useAnalysisStore((s) => s.setParam);
  const setColumnMapping = useAnalysisStore((s) => s.setColumnMapping);
  const setAnalysisType = useAnalysisStore((s) => s.setAnalysisType);
  const storePresets = useConfigStore((s) => s.setPresets);

  useEffect(() => {
    listPresets()
      .then((p) => {
        setPresets(p);
        storePresets(p);
      })
      .catch((e: unknown) => console.error("Failed to load presets:", e));
  }, [storePresets]);

  const handlePresetChange = async (presetId: string) => {
    setSelectedPreset(presetId);
    if (!presetId) return;

    setLoading(true);
    try {
      const config = await loadPreset(presetId) as Record<string, unknown>;

      // Apply config to store
      if (config.type === "survival") {
        setAnalysisType("survival");
        if (config.event) setColumnMapping("event", config.event as string);
        if (config.horizon) setParam("horizon", config.horizon as number);
      } else {
        setAnalysisType("binary");
        if (config.outcome) setColumnMapping("outcome", config.outcome as string);
      }

      if (config.dataFile) {
        const dataFile = config.dataFile as string;
        setDataFile(dataFile);
        try {
          const info = await readCsvHeader(dataFile);
          setDataInfo(info);
        } catch {
          // Data file may not exist on this machine
        }
      }
      if (config.sampleId) setColumnMapping("sampleId", config.sampleId as string);
      if (config.splitProp) setParam("splitProp", config.splitProp as number);
      if (config.numSeed) setParam("numSeed", config.numSeed as number);
      if (config.freq) setParam("freq", config.freq as number);
      if (config.outputDir) setParam("outputDir", config.outputDir as string);
      if (config.timeVariable) setColumnMapping("timeVariable", config.timeVariable as string);
    } catch (e) {
      console.error("Failed to load preset:", e);
    } finally {
      setLoading(false);
    }
  };

  if (presets.length === 0) return null;

  return (
    <section className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">TCGA Preset</h3>
      <div className="flex items-center gap-3">
        <select
          value={selectedPreset}
          onChange={(e) => handlePresetChange(e.target.value)}
          disabled={loading}
          className="flex-1 h-9 px-3 rounded-md border border-border bg-background text-sm focus:outline-none focus:ring-1 focus:ring-primary disabled:opacity-50"
        >
          <option value="">Select a TCGA preset...</option>
          {presets.map((preset) => (
            <option key={preset.id} value={preset.id}>
              {preset.label}
              {preset.hasEvidence ? " (+ Evidence)" : ""}
            </option>
          ))}
        </select>
        {loading && (
          <span className="text-xs text-muted-foreground animate-pulse">
            Loading...
          </span>
        )}
      </div>
      <p className="mt-2 text-xs text-muted-foreground">
        {presets.length} TCGA presets available. Selecting a preset will auto-fill configuration fields.
      </p>
    </section>
  );
}
