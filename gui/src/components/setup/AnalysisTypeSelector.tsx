import type { AnalysisType } from "@/types/analysis";

interface AnalysisTypeSelectorProps {
  value: AnalysisType;
  onChange: (type: AnalysisType) => void;
}

export function AnalysisTypeSelector({ value, onChange }: AnalysisTypeSelectorProps) {
  // RESPRED: binary-only platform — no survival analysis
  // Auto-set to binary if not already
  if (value !== "binary") {
    onChange("binary");
  }

  return (
    <section className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">Analysis Type</h3>
      <div className="flex gap-3">
        <div className="flex-1 border rounded-lg p-3 text-left border-primary bg-primary/5 ring-1 ring-primary">
          <div className="flex items-center gap-2 mb-1">
            <div className="w-4 h-4 rounded-full border-2 border-primary flex items-center justify-center">
              <div className="w-2 h-2 rounded-full bg-primary" />
            </div>
            <span className="text-sm font-medium">Drug Response Prediction</span>
          </div>
          <p className="text-xs text-muted-foreground ml-6">
            Logistic regression with ROC analysis for drug response (responder/non-responder)
          </p>
        </div>
      </div>
    </section>
  );
}
