import {
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { api } from "@/lib/api";
import type { LoadedModel } from "@/lib/types";
import { number } from "@/lib/value";
import { nodeSources } from "@/lib/network";
import { ColumnMultiSelect, DataTable, Field } from "@/components/Common";
import { ModelDetails } from "@/components/Artifacts";
import { MetricScope } from "@/components/MetricsView";
import { GeneEvidence } from "@/components/GeneEvidence";
import { NetworkView } from "@/components/NetworkView";
import { JobPanel } from "@/components/JobPanel";
import { useJob } from "@/stores/job";
import { useWorkspace } from "@/stores/workspace";
import { EvidencePicker } from "@/components/EvidencePicker";
describe("saved scientific artifacts", () => {
  it("renders valid null binary and Cox models without inventing model performance", () => {
    const loaded: LoadedModel = {
      path: "/null.bmpmodel",
      sha256: "same-bytes",
      metrics: null,
      metrics_reason: "Performance belongs to a verified run.",
      model: {
        model_version: 1,
        analysis_type: "binary",
        features: [],
        selected_genes: [],
        coefficients: {},
        sample_id: "sample",
        group_column: "patient",
        threshold: 0.7,
        threshold_method: "Frozen inner OOF",
        outcome: {
          positive_class: "01",
          negative_class: "00",
          positive_label: "반응",
          negative_label: "비반응",
        },
      },
    };
    const view = render(<ModelDetails loaded={loaded} />);
    expect(screen.getByText(/Valid null model/)).toBeInTheDocument();
    expect(screen.getByText("01")).toBeInTheDocument();
    expect(screen.getByText("반응")).toBeInTheDocument();
    expect(
      screen.getByText("Performance belongs to a verified run."),
    ).toBeInTheDocument();
    view.rerender(
      <ModelDetails
        loaded={{
          ...loaded,
          model: {
            ...loaded.model,
            analysis_type: "survival",
            horizon: 3,
            time_unit: "years",
            baseline: { time: [1, 2], reference_lp: 0, ties: "breslow" },
            training: {
              time_range: [0.1, 6],
              events: 20,
              censor_curve: { time: [1], convention: "event-first reverse KM" },
            },
          },
        }}
      />,
    );
    expect(screen.getByText("years")).toBeInTheDocument();
    expect(screen.getByText("event-first reverse KM")).toBeInTheDocument();
    expect(screen.getByText("0.1 · 6")).toBeInTheDocument();
  });
  it("keeps long and leading-zero identifiers and missing cells as strings", () => {
    render(
      <DataTable
        data={{
          headers: ["sample", "score"],
          rows: [
            { sample: "00001", score: "" },
            { sample: "9007199254740993123", score: "0" },
          ],
          count: 2,
        }}
      />,
    );
    expect(screen.getByText("00001")).toBeInTheDocument();
    expect(screen.getByText("9007199254740993123")).toBeInTheDocument();
    expect(screen.getByText("—")).toBeInTheDocument();
    expect(screen.getByText("0")).toBeInTheDocument();
    expect(number("")).toBeNull();
    expect(number(null)).toBeNull();
    expect(number("0")).toBe(0);
  });
  it("shows unavailable point estimates, CIs and resample counts with their reasons", () => {
    render(
      <MetricScope
        value={{
          metrics: {
            roc_auc: {
              estimate: null,
              lower: null,
              upper: null,
              reason: "One observed class",
              ci_reason: "No estimable resamples",
              bootstrap_requested: 20,
              bootstrap_successful: null,
              bootstrap_failed: null,
            },
            brier: {
              estimate: 0,
              lower: 0,
              upper: 0,
              method: "Mean squared error",
            },
          },
        }}
      />,
    );
    expect(screen.getByText("One observed class")).toBeInTheDocument();
    expect(screen.getByText("No estimable resamples")).toBeInTheDocument();
    expect(
      screen.getByText("Unavailable / 20 successful; Unavailable failed"),
    ).toBeInTheDocument();
    expect(screen.getByText("0 – 0")).toBeInTheDocument();
  });
  it("bounds large gene selection lists and preserves delimiter-containing exact names", () => {
    const onChange = vi.fn();
    const columns = [
      "gene,quoted",
      "gene\nnewline",
      ...Array.from({ length: 20000 }, (_, i) => `ENSG_${i}`),
    ];
    render(
      <ColumnMultiSelect
        label="Candidate genes"
        columns={columns}
        value={[]}
        onChange={onChange}
      />,
    );
    fireEvent.click(screen.getByText(/Candidate genes/));
    expect(screen.getAllByRole("checkbox")).toHaveLength(60);
    fireEvent.change(screen.getByLabelText("Search Candidate genes"), {
      target: { value: "gene" },
    });
    fireEvent.click(screen.getByRole("checkbox", { name: "gene,quoted" }));
    expect(onChange).toHaveBeenLastCalledWith(["gene,quoted"]);
    fireEvent.click(screen.getByRole("checkbox", { name: "gene\nnewline" }));
    expect(onChange).toHaveBeenLastCalledWith(["gene\nnewline"]);
  });
});
describe("exact mapped gene evidence", () => {
  const graph = {
    nodes: [
      { id: "shared", gene: "Shared alias", original: true, measured: true },
    ],
    edges: [],
    assay_mapping: [
      { node_id: "shared", source_id: "source;A" },
      { node_id: "shared", source_id: "B,exact" },
    ],
    mapping: [],
    status: "completed",
  };
  it("uses structured assay mapping for both shared sources, never splitting query text", () => {
    expect(nodeSources(graph, "shared")).toEqual(["source;A", "B,exact"]);
    const onSelect = vi.fn();
    render(<NetworkView value={graph} onSelect={onSelect} />);
    fireEvent.keyDown(
      screen.getByRole("button", { name: /Inspect Shared alias/ }),
      { key: "Enter" },
    );
    expect(onSelect).toHaveBeenLastCalledWith(["source;A", "B,exact"]);
    fireEvent.change(screen.getByLabelText("Search network genes"), {
      target: { value: "B,exact" },
    });
    fireEvent.keyDown(
      screen.getByRole("button", { name: /Inspect Shared alias/ }),
      { key: "Enter" },
    );
    expect(onSelect).toHaveBeenLastCalledWith(["B,exact"]);
  });
  it("displays each shared source separately and keeps missing evidence unavailable", () => {
    const evidence = {
      records: [
        {
          gene: "source;A",
          evidence_score: 0.8,
          selection_frequency: 1,
          pathways: ["Signal"],
        },
        {
          gene: "B,exact",
          evidence_score: null,
          evidence_status: "missing",
          pathways: ["Signal"],
        },
      ],
      external_evidence: {
        source: "Source",
        context: { disease_name: "Declared disease" },
      },
    };
    render(
      <GeneEvidence
        value={evidence}
        selected={["source;A", "B,exact"]}
        onSelect={vi.fn()}
      />,
    );
    expect(
      screen.getByRole("heading", { name: "source;A" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { name: "B,exact" }),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/No supplied matching evidence score/),
    ).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Search gene evidence"), {
      target: { value: "B,exact" },
    });
    const geneTable = screen.getAllByRole("table")[0];
    expect(within(geneTable).getAllByRole("row")).toHaveLength(2);
  });
});
it("shows the actual unverified container diagnostic and keeps retry cancellation available", () => {
  useJob.setState({
    jobId: "owned",
    operation: "ora",
    phase: "cancellation_unverified",
    busy: true,
    progress: {},
    error: "Cannot verify container bmp-owned stopped",
    logs: [],
    response: {
      success: false,
      cancelled: false,
      exitCode: null,
      verificationError: null,
      stderrTail: [],
      result: { error: "Cannot verify container bmp-owned stopped" },
    },
  });
  render(<JobPanel />);
  expect(
    screen.getByText("Cannot verify container bmp-owned stopped"),
  ).toBeInTheDocument();
  expect(
    screen.getByRole("button", { name: "Retry cancellation" }),
  ).toBeEnabled();
  expect(
    screen.queryByText(/Cancellation acknowledged/),
  ).not.toBeInTheDocument();
});
it("reuses immutable Open Targets context and prevents cache deletion during any active job", async () => {
  useJob.setState({ busy: true });
  useWorkspace.setState({ config: {} });
  const cached = {
    cache_key: "snapshot-1",
    file_path: "/immutable/genes.csv",
    gene_count: 2,
    disease_name: "Breast carcinoma",
    efo_id: "MONDO_0004989",
    fetched_at: "2026-10-16",
    provenance: {
      source: "Open Targets Platform",
      release: null,
      fetched_at: "2026-10-16",
    },
  };
  vi.spyOn(api, "cachedEvidence").mockResolvedValue([cached]);
  const change = vi.fn();
  render(<EvidencePicker value={null} onChange={change} />);
  fireEvent.click(screen.getByText("Open Targets disease evidence"));
  fireEvent.click(
    screen.getByRole("button", { name: "Refresh evidence cache" }),
  );
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "Use snapshot" })).toBeEnabled(),
  );
  expect(
    screen.getByRole("button", { name: "Delete snapshot" }),
  ).toBeDisabled();
  fireEvent.click(screen.getByRole("button", { name: "Use snapshot" }));
  expect(change).toHaveBeenCalledWith({
    gene_file: "/immutable/genes.csv",
    score_threshold: 0,
    source: "Open Targets Platform",
    disease_name: "Breast carcinoma",
    efo_id: "MONDO_0004989",
    retrieved_at: "2026-10-16",
  });
});

it("uses exact field labels independently of select option and hint text", () => {
  render(
    <Field label="Scoring operation" hint="Choose the recorded workflow.">
      <select defaultValue="predict">
        <option value="predict">Prediction only</option>
        <option value="evaluate">External evaluation</option>
      </select>
    </Field>,
  );
  const select = screen.getByRole("combobox", { name: "Scoring operation" });
  expect(select).toHaveAccessibleDescription("Choose the recorded workflow.");
  expect(screen.getByLabelText("Scoring operation", { exact: true })).toBe(
    select,
  );
});
