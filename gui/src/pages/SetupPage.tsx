import { useAnalysisStore } from "@/stores/analysisStore";
import { AnalysisTypeSelector } from "@/components/setup/AnalysisTypeSelector";
import { PresetSelector } from "@/components/setup/PresetSelector";
import { DataFileSection } from "@/components/setup/DataFileSection";
import { ColumnMappingSection } from "@/components/setup/ColumnMappingSection";
import { ParametersSection } from "@/components/setup/ParametersSection";
import { FeatureSelectionAccordion } from "@/components/setup/FeatureSelectionAccordion";
import { AdvancedOptionsSection } from "@/components/setup/AdvancedOptionsSection";
import { RunActionBar } from "@/components/setup/RunActionBar";

export function SetupPage() {
  const analysisType = useAnalysisStore((s) => s.analysisType);
  const setAnalysisType = useAnalysisStore((s) => s.setAnalysisType);

  return (
    <div className="flex-1 overflow-y-auto p-6 space-y-6">
      <h2 className="text-lg font-semibold">Analysis Setup</h2>

      <AnalysisTypeSelector value={analysisType} onChange={setAnalysisType} />
      <PresetSelector />
      <DataFileSection />
      <ColumnMappingSection />
      <ParametersSection />
      <FeatureSelectionAccordion />
      <AdvancedOptionsSection />
      <RunActionBar />
    </div>
  );
}
