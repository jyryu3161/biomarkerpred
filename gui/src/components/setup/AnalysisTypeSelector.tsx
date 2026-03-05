import { cn } from "@/lib/utils";
import type { AnalysisType } from "@/types/analysis";

interface AnalysisTypeSelectorProps {
  value: AnalysisType;
  onChange: (type: AnalysisType) => void;
}

const options: { value: AnalysisType; label: string; description: string }[] = [
  {
    value: "binary",
    label: "Drug Response Prediction",
    description: "Logistic regression with ROC analysis for drug response (responder/non-responder)",
  },
  {
    value: "survival",
    label: "Prognosis Prediction",
    description: "Cox regression with Kaplan-Meier curves for time-to-event data",
  },
];

export function AnalysisTypeSelector({ value, onChange }: AnalysisTypeSelectorProps) {
  return (
    <section className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">Analysis Type</h3>
      <div className="flex gap-3">
        {options.map((opt) => (
          <button
            key={opt.value}
            onClick={() => onChange(opt.value)}
            className={cn(
              "flex-1 border rounded-lg p-3 text-left transition-all",
              value === opt.value
                ? "border-primary bg-primary/5 ring-1 ring-primary"
                : "border-border hover:border-muted-foreground/30",
            )}
          >
            <div className="flex items-center gap-2 mb-1">
              <div
                className={cn(
                  "w-4 h-4 rounded-full border-2 flex items-center justify-center",
                  value === opt.value
                    ? "border-primary"
                    : "border-muted-foreground/40",
                )}
              >
                {value === opt.value && (
                  <div className="w-2 h-2 rounded-full bg-primary" />
                )}
              </div>
              <span className="text-sm font-medium">{opt.label}</span>
            </div>
            <p className="text-xs text-muted-foreground ml-6">
              {opt.description}
            </p>
          </button>
        ))}
      </div>
    </section>
  );
}
