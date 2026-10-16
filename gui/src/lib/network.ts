import { records, text } from "./value";
import type { JsonObject } from "./types";
export function assaySourceIndex(value: unknown): Map<string, string[]> {
  const unique = new Map<string, Set<string>>();
  for (const row of records(value)) {
    const node = text(row.node_id, ""),
      source = text(row.source_id, "");
    if (!node || !source) continue;
    if (!unique.has(node)) unique.set(node, new Set());
    unique.get(node)!.add(source);
  }
  return new Map([...unique].map(([node, sources]) => [node, [...sources]]));
}
export function nodeSources(graph: JsonObject, nodeId: string): string[] {
  // query_genes is display text only: identifiers may themselves contain semicolons.
  return assaySourceIndex(graph.assay_mapping).get(nodeId) ?? [];
}
