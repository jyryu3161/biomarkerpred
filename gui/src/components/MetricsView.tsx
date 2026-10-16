import { number, numeric, object, strings, text } from "@/lib/value";
import { Facts, Notice } from "./Common";
export function MetricScope({ value }: { value: unknown }) {
  const scope = object(value);
  const metrics = object(scope.metrics);
  return (
    <div className="stack">
      {scope.interpretation ? <p>{text(scope.interpretation)}</p> : null}
      <Facts value={scope.counts} />
      <Facts value={scope.coverage} />
      {strings(scope.warnings).map((warning, i) => (
        <Notice tone="warning" key={i}>
          {warning}
        </Notice>
      ))}
      {Object.keys(metrics).length ? (
        <div className="table-scroll">
          <table className="metrics-table">
            <thead>
              <tr>
                <th>Metric</th>
                <th>Estimate</th>
                <th>Confidence interval</th>
                <th>Resamples</th>
                <th>Method / unavailable reason</th>
              </tr>
            </thead>
            <tbody>
              {Object.entries(metrics).map(([name, raw]) => {
                const metric = object(raw),
                  estimate = number(metric.estimate),
                  lower = number(metric.lower),
                  upper = number(metric.upper);
                return (
                  <tr key={name}>
                    <th>{name.replaceAll("_", " ")}</th>
                    <td>{numeric(estimate)}</td>
                    <td>
                      {lower !== null && upper !== null
                        ? `${numeric(lower)} – ${numeric(upper)}`
                        : "Unavailable"}
                      {metric.ci_reason ? (
                        <small>{text(metric.ci_reason)}</small>
                      ) : null}
                    </td>
                    <td>
                      {metric.bootstrap_requested === undefined
                        ? "Not recorded"
                        : `${text(metric.bootstrap_successful)} / ${text(metric.bootstrap_requested)} successful; ${text(metric.bootstrap_failed)} failed`}
                    </td>
                    <td>
                      {estimate === null ? (
                        <strong>
                          {text(
                            metric.reason,
                            "Estimate unavailable; inspect saved diagnostics.",
                          )}
                        </strong>
                      ) : metric.reason ? (
                        <p>{text(metric.reason)}</p>
                      ) : null}
                      <small>{text(metric.method, "")}</small>
                      <small>{text(metric.ci_method, "")}</small>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ) : (
        <p className="muted">No saved performance estimates are available.</p>
      )}
      <Facts value={object(scope.bootstrap)} omit={["failed_by_metric"]} />
    </div>
  );
}
export function MetricsView({
  value,
  external = false,
}: {
  value: unknown;
  external?: boolean;
}) {
  const metrics = object(value),
    comparisons = object(metrics.comparisons);
  return (
    <div className="stack">
      <h3>
        {external
          ? "Frozen-model external evaluation"
          : "Primary: nested estimate of the inner-selected procedure"}
      </h3>
      <MetricScope value={metrics.primary} />
      <p className="muted">{text(object(metrics.methods).uncertainty, "")}</p>
      {Object.keys(comparisons).length > 0 && (
        <details>
          <summary>
            Descriptive fixed-arm comparisons ({Object.keys(comparisons).length}
            )
          </summary>
          <Notice tone="info">
            Fixed algorithms / feature sets / panel sizes share outer folds.
            Their outer ranking does not provide an unbiased estimate of
            choosing the best arm after seeing assessment outcomes.
          </Notice>
          {Object.entries(comparisons).map(([arm, scope]) => (
            <details key={arm}>
              <summary>{arm}</summary>
              <MetricScope value={scope} />
            </details>
          ))}
        </details>
      )}
      <details>
        <summary>Metric methods</summary>
        <Facts value={metrics.methods} omit={["references"]} />
        <p>{text(metrics.point_weighting, "")}</p>
      </details>
    </div>
  );
}
