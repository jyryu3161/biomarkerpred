import { useAnalysisStore } from "@/stores/analysisStore";
import { pickDirectory } from "@/lib/tauri/commands";

function SliderField({
  label,
  value,
  min,
  max,
  step,
  onChange,
  suffix = "",
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (v: number) => void;
  suffix?: string;
}) {
  return (
    <div className="flex flex-col gap-1">
      <div className="flex justify-between items-center">
        <label className="text-xs font-medium text-muted-foreground">{label}</label>
        <span className="text-xs font-mono text-foreground">
          {value}
          {suffix}
        </span>
      </div>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
        className="w-full h-2 rounded-full accent-primary cursor-pointer"
      />
    </div>
  );
}

function NumberField({
  label,
  value,
  min,
  max,
  step = 1,
  onChange,
}: {
  label: string;
  value: number;
  min?: number;
  max?: number;
  step?: number;
  onChange: (v: number) => void;
}) {
  return (
    <div className="flex flex-col gap-1">
      <label className="text-xs font-medium text-muted-foreground">{label}</label>
      <input
        type="number"
        value={value}
        min={min}
        max={max}
        step={step}
        onChange={(e) => onChange(Number(e.target.value))}
        className="h-9 px-3 rounded-md border border-border bg-background text-sm font-mono focus:outline-none focus:ring-1 focus:ring-primary"
      />
    </div>
  );
}

export function ParametersSection() {
  const analysisType = useAnalysisStore((s) => s.analysisType);
  const splitProp = useAnalysisStore((s) => s.splitProp);
  const numSeed = useAnalysisStore((s) => s.numSeed);
  const freq = useAnalysisStore((s) => s.freq);
  const horizon = useAnalysisStore((s) => s.horizon);
  const outputDir = useAnalysisStore((s) => s.outputDir);
  const setParam = useAnalysisStore((s) => s.setParam);

  const handlePickOutputDir = async () => {
    try {
      const dir = await pickDirectory();
      if (dir) setParam("outputDir", dir);
    } catch (e) {
      console.error("Directory pick error:", e);
    }
  };

  return (
    <section className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">Parameters</h3>

      <div className="space-y-4">
        <SliderField
          label="Train/Test Split"
          value={splitProp}
          min={0.5}
          max={0.9}
          step={0.05}
          onChange={(v) => setParam("splitProp", v)}
        />

        <div className="grid grid-cols-2 gap-4">
          <NumberField
            label="Number of Seeds"
            value={numSeed}
            min={10}
            max={1000}
            step={10}
            onChange={(v) => setParam("numSeed", v)}
          />

          <NumberField
            label="Frequency Threshold"
            value={freq}
            min={1}
            max={100}
            onChange={(v) => setParam("freq", v)}
          />
        </div>

        {analysisType === "survival" && (
          <NumberField
            label="Survival Horizon (years)"
            value={horizon}
            min={1}
            max={20}
            step={0.5}
            onChange={(v) => setParam("horizon", v)}
          />
        )}

        <div className="flex flex-col gap-1">
          <label className="text-xs font-medium text-muted-foreground">Output Directory</label>
          <div className="flex gap-2">
            <input
              type="text"
              value={outputDir}
              onChange={(e) => setParam("outputDir", e.target.value)}
              placeholder="Select output directory..."
              className="flex-1 h-9 px-3 rounded-md border border-border bg-background text-sm focus:outline-none focus:ring-1 focus:ring-primary"
            />
            <button
              onClick={handlePickOutputDir}
              className="px-3 py-2 bg-secondary text-secondary-foreground rounded-md text-sm hover:bg-secondary/80 transition-colors whitespace-nowrap"
            >
              Browse
            </button>
          </div>
        </div>
      </div>
    </section>
  );
}
