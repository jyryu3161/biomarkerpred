import { useMemo, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import { number, object, records, text } from "@/lib/value";
import type { JsonObject } from "@/lib/types";
import { assaySourceIndex } from "@/lib/network";
import { DataTable, Field, Notice } from "./Common";
interface Point {
  x: number;
  y: number;
}
export function NetworkView({
  value,
  onSelect,
}: {
  value: unknown;
  onSelect: (genes: string[]) => void;
}) {
  const graph = object(value);
  const nodes = useMemo(() => records(graph.nodes), [graph.nodes]);
  const edges = records(graph.edges);
  const sourceIndex = useMemo(
    () => assaySourceIndex(graph.assay_mapping),
    [graph.assay_mapping],
  );
  const sourcesFor = (nodeId: string) => sourceIndex.get(nodeId) ?? [];
  const [query, setQuery] = useState("");
  const [confidence, setConfidence] = useState(0);
  const [selected, setSelected] = useState("");
  const [moved, setMoved] = useState<Record<string, Point>>({});
  const svg = useRef<SVGSVGElement>(null);
  const drag = useRef<{ id: string; pointer: number; offset: Point } | null>(
    null,
  );
  const lowerQuery = query.toLocaleLowerCase();
  const positions = useMemo(
    () =>
      Object.fromEntries(
        nodes.map((node, i) => [
          text(node.id),
          {
            x:
              500 +
              380 * Math.cos((2 * Math.PI * i) / Math.max(nodes.length, 1)),
            y:
              270 +
              200 * Math.sin((2 * Math.PI * i) / Math.max(nodes.length, 1)),
          },
        ]),
      ),
    [nodes],
  );
  const matches = (node: JsonObject) =>
    [text(node.gene, ""), text(node.id, ""), ...sourcesFor(text(node.id))].some(
      (value) => value.toLocaleLowerCase().includes(lowerQuery),
    );
  const matchingNodes = nodes.filter(matches);
  const visibleNodes = matchingNodes.slice(0, 500);
  const visibleIds = new Set(visibleNodes.map((node) => text(node.id)));
  const matchingEdges = edges.filter(
    (edge) =>
      (number(edge.score) ?? -1) >= confidence &&
      visibleIds.has(text(edge.source)) &&
      visibleIds.has(text(edge.target)),
  );
  const visibleEdges = matchingEdges.slice(0, 3000);
  const at = (id: string) => moved[id] ?? positions[id] ?? { x: 500, y: 270 };
  const screenToSvg = (clientX: number, clientY: number): Point | null => {
    const element = svg.current,
      transform = element?.getScreenCTM();
    if (!element || !transform) return null;
    const point = element.createSVGPoint();
    point.x = clientX;
    point.y = clientY;
    return point.matrixTransform(transform.inverse());
  };
  const select = (node: JsonObject) => {
    const id = text(node.id),
      sources = sourcesFor(id);
    setSelected(id);
    const filtered = sources.filter((source) =>
      source.toLocaleLowerCase().includes(lowerQuery),
    );
    onSelect(
      lowerQuery && filtered.length
        ? filtered
        : sources.length
          ? sources
          : [text(node.gene)],
    );
  };
  const startDrag = (
    event: ReactPointerEvent<SVGGElement>,
    node: JsonObject,
  ) => {
    if (event.button !== 0) return;
    const point = screenToSvg(event.clientX, event.clientY);
    if (!point) return;
    const id = text(node.id),
      position = at(id);
    drag.current = {
      id,
      pointer: event.pointerId,
      offset: { x: position.x - point.x, y: position.y - point.y },
    };
    event.currentTarget.setPointerCapture(event.pointerId);
    select(node);
    event.preventDefault();
  };
  const moveDrag = (event: ReactPointerEvent<SVGGElement>) => {
    const current = drag.current;
    if (!current || current.pointer !== event.pointerId) return;
    const point = screenToSvg(event.clientX, event.clientY);
    if (!point) return;
    setMoved((previous) => ({
      ...previous,
      [current.id]: {
        x: point.x + current.offset.x,
        y: point.y + current.offset.y,
      },
    }));
  };
  const stopDrag = (event: ReactPointerEvent<SVGGElement>) => {
    if (drag.current?.pointer === event.pointerId) drag.current = null;
    if (event.currentTarget.hasPointerCapture(event.pointerId))
      event.currentTarget.releasePointerCapture(event.pointerId);
  };
  const selectedNode = nodes.find((node) => node.id === selected);
  return (
    <div className="stack">
      <p>
        {text(
          graph.interpretation,
          "STRING functional associations; edges do not establish direct physical binding or causation.",
        )}
      </p>
      <div className="form-grid">
        <Field label="Search network genes">
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Gene, source assay ID or STRING ID"
          />
        </Field>
        <Field
          label={`Minimum displayed confidence (${confidence.toFixed(2)})`}
        >
          <input
            aria-label="Minimum displayed confidence"
            type="range"
            min="0"
            max="1"
            step="0.01"
            value={confidence}
            onChange={(e) => setConfidence(Number(e.target.value))}
          />
        </Field>
      </div>
      <p className="muted">
        {visibleNodes.length} / {nodes.length} nodes · {visibleEdges.length}{" "}
        displayed edges. Blue: original; green: measured expansion; gray:
        outside assay. Drag nodes or press Enter to inspect source genes.
      </p>
      {matchingNodes.length > 500 || matchingEdges.length > 3000 ? (
        <Notice tone="warning">
          For responsive inspection, the view shows the first 500 matching nodes
          and 3,000 matching edges. Narrow the search / confidence filter or
          open the full saved report.
        </Notice>
      ) : null}
      {nodes.length ? (
        <svg
          ref={svg}
          className="network"
          viewBox="0 0 1000 540"
          aria-label="Functional association network"
          role="img"
        >
          <g>
            {visibleEdges.map((edge, i) => {
              const a = at(text(edge.source)),
                b = at(text(edge.target));
              return (
                <line
                  key={i}
                  x1={a.x}
                  y1={a.y}
                  x2={b.x}
                  y2={b.y}
                  stroke="#96a9b3"
                  strokeWidth={1 + (number(edge.score) ?? 0) * 3}
                >
                  <title>
                    {text(edge.source)} — {text(edge.target)}:{" "}
                    {text(edge.score)}
                  </title>
                </line>
              );
            })}
          </g>
          <g>
            {visibleNodes.map((node) => {
              const id = text(node.id),
                point = at(id);
              return (
                <g
                  key={id}
                  transform={`translate(${point.x},${point.y})`}
                  className={`network-node ${selected === id ? "selected" : ""}`}
                  role="button"
                  tabIndex={0}
                  aria-label={`Inspect ${text(node.gene)}; assay sources ${sourcesFor(id).join(" · ") || "none"}`}
                  data-node-id={id}
                  onPointerDown={(event) => startDrag(event, node)}
                  onPointerMove={moveDrag}
                  onPointerUp={stopDrag}
                  onPointerCancel={stopDrag}
                  onLostPointerCapture={() => {
                    drag.current = null;
                  }}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" || e.key === " ") {
                      e.preventDefault();
                      select(node);
                    }
                  }}
                >
                  <circle
                    r="17"
                    fill={
                      node.original === true
                        ? "#176c84"
                        : node.measured === true
                          ? "#287c62"
                          : "#8b949c"
                    }
                  />
                  <text y="-25" textAnchor="middle">
                    {text(node.gene)}
                  </text>
                  <title>{sourcesFor(id).join("\n")}</title>
                </g>
              );
            })}
          </g>
        </svg>
      ) : (
        <Notice>
          {text(
            graph.reason,
            `Network status: ${text(graph.status, "not requested")}`,
          )}
        </Notice>
      )}
      {selectedNode && (
        <div>
          <h3>Selected network node: {text(selectedNode.gene)}</h3>
          <p>
            Assay sources:{" "}
            {sourcesFor(selected).join(" · ") || "No measured source mapping"}.{" "}
            {selectedNode.measured === true
              ? "Measured in the assay."
              : "Outside the measured assay background."}
          </p>
          <DataTable
            data={edges
              .filter(
                (edge) => edge.source === selected || edge.target === selected,
              )
              .map((edge) => ({
                ...edge,
                score: edge.score ?? "Unavailable",
                nscore: edge.nscore ?? "Unavailable",
                fscore: edge.fscore ?? "Unavailable",
                pscore: edge.pscore ?? "Unavailable",
                ascore: edge.ascore ?? "Unavailable",
                escore: edge.escore ?? "Unavailable",
                dscore: edge.dscore ?? "Unavailable",
                tscore: edge.tscore ?? "Unavailable",
              }))}
            title="selected node associations"
          />
          <p className="muted">
            Channel scores: nscore neighborhood; fscore fusion; pscore
            phylogenetic profile; ascore coexpression; escore experimental;
            dscore database; tscore text mining. Missing channels are
            unavailable.
          </p>
        </div>
      )}
    </div>
  );
}
