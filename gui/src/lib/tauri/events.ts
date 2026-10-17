import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { ProgressEvent } from "@/types/results";

/** Payload emitted by the `analysis://complete` event */
export interface AnalysisCompletePayload {
  success: boolean;
  code: number | null;
}

/** Payload emitted by the `analysis://error` event */
export interface AnalysisErrorPayload {
  message: string;
}

/** Subscribe to real-time progress updates during analysis.
 *
 * @param handler - Called with each ProgressEvent emitted by the backend
 * @returns Unsubscribe function — call it in a cleanup/useEffect return
 */
export async function onAnalysisProgress(
  handler: (event: ProgressEvent) => void,
): Promise<UnlistenFn> {
  return listen<ProgressEvent>("analysis://progress", (e) => handler(e.payload));
}

/** Subscribe to individual log lines emitted by the running analysis process.
 *
 * The backend emits raw strings (one line per event).
 *
 * @param handler - Called with each log line string
 * @returns Unsubscribe function
 */
export async function onAnalysisLog(handler: (line: string) => void): Promise<UnlistenFn> {
  return listen<string>("analysis://log", (e) => handler(e.payload));
}

/** Subscribe to the analysis completion event.
 *
 * @param handler - Called once when the analysis process exits
 * @returns Unsubscribe function
 */
export async function onAnalysisComplete(
  handler: (payload: AnalysisCompletePayload) => void,
): Promise<UnlistenFn> {
  return listen<AnalysisCompletePayload>("analysis://complete", (e) => handler(e.payload));
}

/** Subscribe to fatal analysis error events.
 *
 * @param handler - Called when the backend emits an unrecoverable error
 * @returns Unsubscribe function
 */
export async function onAnalysisError(
  handler: (payload: AnalysisErrorPayload) => void,
): Promise<UnlistenFn> {
  return listen<AnalysisErrorPayload>("analysis://error", (e) => handler(e.payload));
}
