bmp_pathway_evidence <- function(run, model, universes, mapping, ranking, pathways, network, options) {
  genes <- bmp_pathway_clean_ids(c(universes$configured_assay$genes, model$selected_genes, network$assay_mapping$source_id))
  stability <- bmp_read_csv(file.path(run$dir, "stability.csv"))
  stability <- stability[stability$role == "primary", , drop = FALSE]
  if (anyDuplicated(stability$gene)) stop("Primary stability records contain duplicate genes.", call. = FALSE)
  evidence_path <- options$evidence
  recorded <- run$manifest$provenance$evidence
  if (is.null(evidence_path) && !is.null(recorded)) evidence_path <- recorded$gene_file
  external <- NULL; provenance <- list(status = "not_provided", reason = "No supplied Open Targets/evidence CSV. Missing scores are not zero associations.")
  if (!is.null(evidence_path)) {
    if (!file.exists(evidence_path)) stop("Supplied external evidence CSV is unavailable; cannot recreate its gene evidence.", call. = FALSE)
    before <- bmp_sha256(evidence_path)
    if (is.null(options$evidence) && !is.null(recorded$sha256) && !identical(before, recorded$sha256)) stop("Source-run external evidence hash changed; provide the original file or explicitly select a new --evidence CSV for this exploratory analysis.", call. = FALSE)
    external <- bmp_read_csv(evidence_path)
    if (!all(c("gene_symbol", "score") %in% names(external))) stop("External evidence CSV requires gene_symbol,score columns.", call. = FALSE)
    external$score <- suppressWarnings(as.numeric(external$score))
    if (anyNA(external$gene_symbol) || any(!nzchar(trimws(external$gene_symbol))) || any(!is.finite(external$score)) || any(external$score < 0 | external$score > 1)) stop("External evidence requires nonblank gene symbols and finite scores in [0,1].", call. = FALSE)
    if (!identical(before, bmp_sha256(evidence_path))) stop("External evidence changed while being read.", call. = FALSE)
    provenance <- list(status = "provided", path = normalizePath(evidence_path), sha256 = before, source = if (!is.null(recorded$source) && is.null(options$evidence)) recorded$source else "user_supplied_evidence",
      context = if (is.null(options$evidence) && !is.null(recorded)) recorded[setdiff(names(recorded), c("gene_file", "sha256", "bytes"))] else list(status = "unknown", description = "Explicit user-supplied evidence; disease/context was not supplied through run provenance. Inspect retained CSV records for any contextual fields."),
      aggregation = "Maximum supplied score per source gene; all supplied records retained. Score semantics belong to the supplied source; no disease association is inferred from missing rows.")
  }
  numeric_field <- function(frame, row, field) if (is.na(row) || !field %in% names(frame)) NA_real_ else suppressWarnings(as.numeric(frame[[field]][row]))
  rank <- bmp_read_csv(file.path(run$dir, "gene_ranking.csv"))
  records <- lapply(genes, function(gene) {
    si <- match(gene, stability$gene); ri <- match(gene, rank$gene); mi <- match(gene, mapping$table$source_id)
    target <- if (is.na(mi)) NA_character_ else mapping$table$target_id[mi]
    memberships <- if (is.na(target)) character() else names(pathways)[vapply(pathways, function(members) target %in% members, logical(1))]
    design <- Filter(function(term) identical(term$predictor, gene), model$recipe$design)
    coefficients <- lapply(design, function(term) list(column = term$column, coefficient = model$coefficients[[term$column]], coding = term))
    evidence_rows <- if (is.null(external)) data.frame() else {
      matches <- external$gene_symbol == gene
      if ("ensembl_id" %in% names(external)) matches <- matches | (!is.na(external$ensembl_id) & external$ensembl_id == gene)
      external[matches, , drop = FALSE]
    }
    graph_ids <- network$assay_mapping$node_id[network$assay_mapping$source_id == gene]
    raw_genes <- universes$raw_assay$genes
    list(gene = gene, annotation_id = if (is.na(target)) NULL else target,
      mapping_status = if (is.na(mi)) "not_requested" else mapping$table$status[mi],
      original = gene %in% bmp_strings(model$selected_genes), expanded = gene %in% network$assay_mapping$source_id[!network$assay_mapping$original] && !gene %in% bmp_strings(model$selected_genes),
      measured = if (is.null(raw_genes)) gene %in% bmp_strings(universes$configured_assay$genes) else gene %in% bmp_strings(raw_genes),
      configured_assay = gene %in% bmp_strings(universes$configured_assay$genes), configured_eligible = gene %in% bmp_strings(universes$configured_eligible$genes), development_qc_eligible = gene %in% bmp_strings(universes$development_qc$genes),
      selection_frequency = numeric_field(stability, si, "selection_frequency"), selected_folds = numeric_field(stability, si, "selected_folds"), completed_folds = numeric_field(stability, si, "completed_folds"),
      positive_frequency = numeric_field(stability, si, "positive_frequency"), negative_frequency = numeric_field(stability, si, "negative_frequency"), direction_consistency = numeric_field(stability, si, "direction_consistency"),
      mean_standardized_coefficient = numeric_field(stability, si, "mean_standardized_coefficient"), final_coefficients = coefficients,
      rank_statistic = numeric_field(rank, ri, "statistic"), rank_p_value = numeric_field(rank, ri, "p_value"),
      rank_method = if (is.na(ri) || !"statistic_method" %in% names(rank)) NULL else rank$statistic_method[ri],
      evidence_score = if (nrow(evidence_rows)) max(evidence_rows$score) else NA_real_, evidence_status = if (nrow(evidence_rows)) "provided" else "missing",
      evidence_records = if (nrow(evidence_rows)) unname(lapply(seq_len(nrow(evidence_rows)), function(i) as.list(evidence_rows[i, , drop = FALSE]))) else list(),
      pathways = I(sort(memberships)), graph_node_ids = I(graph_ids),
      links = list(ncbi_gene = paste0("https://www.ncbi.nlm.nih.gov/gene/?term=", utils::URLencode(gene, reserved = TRUE)),
        opentargets = if (nrow(evidence_rows) && "ensembl_id" %in% names(evidence_rows) && !is.na(evidence_rows$ensembl_id[1]) && grepl("^ENS[A-Z]*G[0-9]+([.][0-9]+)?$", evidence_rows$ensembl_id[1])) paste0("https://platform.opentargets.org/target/", utils::URLencode(evidence_rows$ensembl_id[1], reserved = TRUE)) else NULL))
  })
  rows <- lapply(records, function(row) data.frame(gene = row$gene, annotation_id = if (is.null(row$annotation_id)) NA_character_ else row$annotation_id,
    original = row$original, expanded = row$expanded, measured = row$measured, development_qc_eligible = row$development_qc_eligible,
    selection_frequency = row$selection_frequency, positive_frequency = row$positive_frequency, negative_frequency = row$negative_frequency, direction_consistency = row$direction_consistency,
    final_coefficients = paste(vapply(row$final_coefficients, function(x) paste0(x$column, "=", x$coefficient), character(1)), collapse = ";"),
    rank_statistic = row$rank_statistic, evidence_score = row$evidence_score, evidence_status = row$evidence_status, pathways = paste(row$pathways, collapse = ";"), stringsAsFactors = FALSE))
  table <- if (length(rows)) do.call(rbind, rows) else data.frame(gene = character(), annotation_id = character(), original = logical(), expanded = logical(), measured = logical(), development_qc_eligible = logical(), selection_frequency = numeric(), positive_frequency = numeric(), negative_frequency = numeric(), direction_consistency = numeric(), final_coefficients = character(), rank_statistic = numeric(), evidence_score = numeric(), evidence_status = character(), pathways = character())
  list(schema_version = 1L, unit = "source gene identifier; annotation mapping units and STRING nodes separately identified", records = records, table = table, external_evidence = provenance,
    interpretation = "Outer-fold selection stability, frozen full-development coefficients, exploratory development ranks and supplied external evidence are distinct evidence types; missing evidence is null.")
}
bmp_pathway_figures <- function(directory, original, expanded, gsea, network, id) {
  plots <- list()
  ora_plot <- function(frame, title) {
    selected <- frame[is.finite(frame$adjusted_p_value), , drop = FALSE]
    selected <- head(selected[order(selected$adjusted_p_value, -selected$overlap), , drop = FALSE], 20)
    function() {
      if (!nrow(selected)) { plot.new(); title(title); text(.5, .5, "No estimable terms; see table reason column."); return(invisible(NULL)) }
      par(mar = c(5, 13, 4, 2)); barplot(rev(-log10(pmax(selected$adjusted_p_value, .Machine$double.xmin))), names.arg = rev(selected$term_id), horiz = TRUE, las = 1, col = "#287c9b", xlab = "-log10(BH adjusted p-value)", main = title, cex.names = .7)
    }
  }
  plots$ora_original <- list(title = "Original final-model genes: exploratory ORA", draw = ora_plot(original, "Original gene enrichment"))
  plots$ora_expanded <- list(title = "Expanded genes within the same assay background: exploratory ORA", draw = ora_plot(expanded, "Expanded gene enrichment"))
  plots$gsea <- list(title = "Full-development ranked GSEA; top 20 by adjusted p-value", draw = local({ frame <- gsea[is.finite(gsea$nes), , drop = FALSE]; frame <- head(frame[order(frame$adjusted_p_value), , drop = FALSE], 20); function() {
    if (!nrow(frame)) { plot.new(); title("Ranked GSEA"); text(.5, .5, "No estimable normalized scores; inspect reasons."); return(invisible(NULL)) }
    par(mar = c(5, 13, 4, 2)); barplot(rev(frame$nes), names.arg = rev(frame$term_id), horiz = TRUE, las = 1, col = ifelse(rev(frame$nes) >= 0, "#b13f62", "#287c9b"), xlab = "Normalized enrichment score (NES)", main = "Full-development ranked GSEA", cex.names = .7); abline(v = 0, col = "#777777")
  }}))
  plots$network <- list(title = paste("STRING functional associations:", network$status), draw = local({ nodes <- network$nodes; edges <- network$edges; function() {
    plot.new(); plot.window(c(-1.3, 1.3), c(-1.3, 1.3), asp = 1); title(paste("Gene network:", network$status))
    if (!nrow(nodes)) { text(0, 0, if (is.null(network$reason)) "No graph nodes." else network$reason, cex = .7); return(invisible(NULL)) }
    angle <- seq(0, 2*pi, length.out = nrow(nodes) + 1L)[seq_len(nrow(nodes))]; x <- cos(angle); y <- sin(angle)
    if (nrow(edges)) { a <- match(edges$source, nodes$id); b <- match(edges$target, nodes$id); segments(x[a], y[a], x[b], y[b], col = "#b7c5d1", lwd = 1 + edges$score) }
    points(x, y, pch = ifelse(nodes$original, 17, 19), col = ifelse(nodes$original, "#b13f62", "#287c9b"), cex = 1.4); text(x*1.13, y*1.13, nodes$gene, cex = max(.4, min(.8, 10/nrow(nodes))))
  }}))
  dir.create(file.path(directory, "figures"), recursive = TRUE, showWarnings = FALSE)
  index <- list()
  for (name in names(plots)) {
    files <- list()
    for (format in c("svg", "pdf", "tiff")) {
      relative <- file.path("figures", paste0(name, ".", format)); path <- file.path(directory, relative)
      if (format == "svg") grDevices::svg(path, width = 10, height = 7, family = "sans") else if (format == "pdf") grDevices::cairo_pdf(path, width = 10, height = 7, family = "sans") else grDevices::tiff(path, width = 10, height = 7, units = "in", res = 150, compression = "lzw", type = "cairo")
      tryCatch({ plots[[name]]$draw(); mtext(id, side = 1, outer = TRUE, line = -1, cex = .55) }, finally = grDevices::dev.off())
      files[[format]] <- relative
    }
    index[[length(index) + 1L]] <- list(kind = name, title = plots[[name]]$title, role = "exploratory_development_annotation", files = files)
  }
  bmp_atomic_json(list(schema_version = 1L, figures = index), file.path(directory, "figures", "index.json"))
  index
}
bmp_pathway_html <- function(path, summary, original, expanded, gsea, evidence, network, figures) {
  table <- function(frame, columns, limit = 50L) {
    frame <- head(frame, limit)
    if (!nrow(frame)) return("<p>No rows.</p>")
    if ("reason" %in% names(frame)) frame$reason[is.na(frame$reason)] <- "Estimable"
    for (column in names(frame)) if (is.numeric(frame[[column]])) frame[[column]] <- vapply(frame[[column]], function(value) if (is.na(value)) "Unavailable" else formatC(value, digits = 5, format = "g"), character(1))
    body <- apply(frame[, columns, drop = FALSE], 1L, function(row) paste0("<tr>", paste0("<td>", bmp_html_escape(row), "</td>", collapse = ""), "</tr>"))
    paste0("<div class='scroll'><table><thead><tr>", paste0("<th>", bmp_html_escape(columns), "</th>", collapse = ""), "</tr></thead><tbody>", paste(body, collapse = ""), "</tbody></table></div>")
  }
  universe_rows <- do.call(rbind, lapply(c("raw_assay", "configured_assay", "configured_eligible", "development_qc", "annotation_mapped"), function(name) { x <- summary$universes[[name]]; data.frame(universe = name, count = if (is.null(x$count)) "Unavailable" else x$count, policy = x$policy, stringsAsFactors = FALSE) }))
  payload <- list(evidence = evidence$records, graph = list(nodes = network$nodes, edges = network$edges, assay_mapping = network$assay_mapping, status = network$status, reason = network$reason))
  json <- bmp_cli_json(payload); json <- gsub("<", "\\u003c", json, fixed = TRUE); json <- gsub(">", "\\u003e", json, fixed = TRUE); json <- gsub("&", "\\u0026", json, fixed = TRUE)
  figures_html <- paste(vapply(figures, function(figure) paste0("<figure><img alt='", bmp_html_escape(figure$title), "' src='data:image/svg+xml;base64,", jsonlite::base64_enc(readBin(file.path(dirname(path), figure$files$svg), "raw", n = file.info(file.path(dirname(path), figure$files$svg))$size)), "'><figcaption>", bmp_html_escape(figure$title), "</figcaption></figure>"), character(1)), collapse = "\n")
  html <- paste0("<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Pathway evidence ", bmp_html_escape(summary$run_id), "</title><style>body{font:15px/1.55 system-ui,sans-serif;color:#1d3045;max-width:1200px;margin:35px auto;padding:0 24px}h1,h2{color:#183e5d}header,.notice{background:#edf5f9;padding:20px;border-radius:12px}table{border-collapse:collapse;width:100%;font-size:13px}td,th{padding:9px;border-bottom:1px solid #dce5eb;text-align:left}th{background:#f4f7fa}.scroll{overflow:auto;max-height:500px}figure{display:inline-block;width:47%;vertical-align:top;margin:1%}img{max-width:100%}input,select{padding:9px;margin:8px;border:1px solid #a9bac7;border-radius:5px}#network{width:100%;height:480px;border:1px solid #dce5eb;touch-action:none}#details{white-space:pre-wrap;background:#f4f7fa;padding:12px;max-height:380px;overflow:auto}button{cursor:pointer}a{color:#176c95}</style></head><body><header><h1>Pathway and gene evidence</h1><p>Pathway run: ", bmp_html_escape(summary$run_id), "<br>Source development run: ", bmp_html_escape(summary$source_run_id), "<br>Status: <strong>", bmp_html_escape(summary$status), "</strong></p><p>Exploratory full-development associations; separate from held-out predictive performance. Source model, thresholds, predictions and completion status are unchanged.</p></header>",
    "<h2>Universe and mapping audit</h2>", table(universe_rows, names(universe_rows)), "<p>Original query genes: ", length(summary$gene_sets$original), "; expanded query genes: ", length(summary$gene_sets$expanded), ". Network expansion never enlarges the assay background. Unmeasured interactors are visible but excluded from assay-background tests.</p>",
    "<p>", bmp_html_escape(paste(summary$warnings, collapse = " | ")), "</p>",
    "<h2>Original genes: over-representation</h2><p>One-sided hypergeometric tests; BH across all size-eligible tested terms, including zero overlap. Top 50 shown; complete tables retain unavailable reasons.</p>",
    table(original[order(original$adjusted_p_value, na.last = TRUE), ], c("term_id", "description", "overlap", "term_size", "query_size", "universe_size", "p_value", "adjusted_p_value", "reason")),
    "<h2>Expanded genes: over-representation</h2>", table(expanded[order(expanded$adjusted_p_value, na.last = TRUE), ], c("term_id", "description", "overlap", "term_size", "query_size", "universe_size", "p_value", "adjusted_p_value", "reason")),
    "<h2>Full-ranked GSEA</h2><p>Weighted preranked ES; competitive gene-label permutations (", summary$options$permutations, ") with seed ", summary$options$seed, ". Sign-specific normalization and finite Monte Carlo resolution are recorded. BH adjusted p-values are not GSEA FDR q-values. Non-estimable ranks, deterministic identifier tie-breaking and collapsed mappings are audited.</p>",
    table(gsea[order(gsea$adjusted_p_value, na.last = TRUE), ], c("term_id", "description", "term_size", "es", "nes", "p_value", "adjusted_p_value", "minimum_p_value", "leading_edge", "reason")),
    "<h2>Gene evidence explorer</h2><label>Search gene or pathway <input id='search' type='search'></label><label>Role <select id='role'><option value='all'>All genes</option><option value='original'>Original model genes</option><option value='expanded'>Expanded genes</option><option value='measured'>Measured genes</option></select></label><div class='scroll'><table><thead><tr><th>Gene</th><th>Role</th><th>Outer selection frequency</th><th>Rank statistic</th><th>Supplied evidence score</th></tr></thead><tbody id='genes'></tbody></table></div><pre id='details'>Select a gene or graph node to inspect coefficients, evidence records, pathways and source roles.</pre>",
    "<h2>Interactive association network</h2><p>", bmp_html_escape(paste(network$status, network$reason)), "</p><p>Functional associations are not necessarily direct physical interactions. Drag nodes; click a node for gene evidence. Confidence filter <input id='confidence' type='range' min='0' max='1' step='.05' value='0'><span id='confidence-value'>0</span></p><svg id='network' viewBox='0 0 1000 480' aria-label='Interactive gene association network'></svg>",
    "<h2>Figures</h2>", figures_html,
    "<h2>Saved artifacts</h2><p><a href='ora_original.csv'>Original ORA CSV</a> · <a href='ora_expanded.csv'>Expanded ORA CSV</a> · <a href='gsea.csv'>GSEA CSV</a> · <a href='gene_evidence.csv'>Gene evidence CSV</a> · <a href='summary.json'>Methods and provenance JSON</a> · <a href='manifest.json'>Artifact manifest</a></p>",
    "<script type='application/json' id='payload'>", json, "</script><script>",
    "const data=JSON.parse(document.getElementById('payload').textContent), search=document.getElementById('search'), role=document.getElementById('role'), details=document.getElementById('details'), svg=document.getElementById('network'), threshold=document.getElementById('confidence');",
    "const fmt=x=>x===null||x===undefined?'Unavailable':typeof x==='number'?String(Number(x.toPrecision(5))):String(x);function show(gene){const row=data.evidence.find(x=>x.gene===gene);details.textContent=row?JSON.stringify(row,null,2):'No supplied gene evidence: '+gene}function visible(row){const q=search.value.toLowerCase();return (!q||row.gene.toLowerCase().includes(q)||(row.pathways||[]).some(x=>x.toLowerCase().includes(q)))&&(role.value==='all'||row[role.value])}",
    "function drawTable(){const body=document.getElementById('genes');body.replaceChildren();const selected=data.evidence.filter(visible);selected.slice(0,500).forEach(row=>{const tr=document.createElement('tr');[row.gene,row.original?'Original':row.expanded?'Expanded':'Assay',fmt(row.selection_frequency),fmt(row.rank_statistic),fmt(row.evidence_score)].forEach((value,i)=>{const td=document.createElement('td');if(i===0){const b=document.createElement('button');b.textContent=value;b.onclick=()=>show(row.gene);td.appendChild(b)}else td.textContent=value;tr.appendChild(td)});body.appendChild(tr)});if(selected.length>500){const tr=document.createElement('tr'),td=document.createElement('td');td.colSpan=5;td.textContent='Showing first 500 matching genes; refine search or download complete evidence CSV.';tr.appendChild(td);body.appendChild(tr)}}",
    "const evidenceByGene=new Map(data.evidence.map(row=>[row.gene,row])), sourcesByNode=new Map();(data.graph.assay_mapping||[]).forEach(relation=>{if(!sourcesByNode.has(relation.node_id))sourcesByNode.set(relation.node_id,[]);sourcesByNode.get(relation.node_id).push(relation.source_id)});function nodeEvidence(node){return [...new Set(sourcesByNode.get(node.id)||[])].map(gene=>evidenceByGene.get(gene)).filter(Boolean)}function showNode(node){const all=nodeEvidence(node),matching=all.filter(visible),rows=matching.length?matching:all;details.textContent=rows.length===1?JSON.stringify(rows[0],null,2):JSON.stringify({node_id:node.id,node_label:node.gene,source_gene_evidence:rows},null,2)}",
    "const positions=new Map(data.graph.nodes.map((n,i)=>[n.id,{x:500+350*Math.cos(2*Math.PI*i/Math.max(1,data.graph.nodes.length)),y:240+175*Math.sin(2*Math.PI*i/Math.max(1,data.graph.nodes.length))}]));const ns='http://www.w3.org/2000/svg';function el(tag,attrs){const e=document.createElementNS(ns,tag);Object.entries(attrs).forEach(([k,v])=>e.setAttribute(k,v));return e}let dragging=null;function pointerPosition(event){const transform=svg.getScreenCTM();if(!transform)return null;const point=svg.createSVGPoint();point.x=event.clientX;point.y=event.clientY;return point.matrixTransform(transform.inverse())}",
    "function drawGraph(){svg.replaceChildren();document.getElementById('confidence-value').textContent=threshold.value;const visibleIds=new Set(data.graph.nodes.filter(node=>{const rows=nodeEvidence(node);return rows.length?rows.some(visible):!search.value&&role.value==='all'}).map(node=>node.id));data.graph.edges.filter(e=>e.score>=Number(threshold.value)&&visibleIds.has(e.source)&&visibleIds.has(e.target)).forEach(e=>{const a=positions.get(e.source),b=positions.get(e.target);if(a&&b)svg.appendChild(el('line',{x1:a.x,y1:a.y,x2:b.x,y2:b.y,stroke:'#b5c6d1','stroke-width':1+e.score*3}))});",
    "data.graph.nodes.filter(node=>visibleIds.has(node.id)).forEach(node=>{const p=positions.get(node.id),g=el('g',{'data-node-id':node.id,tabindex:0,role:'button','aria-label':'Inspect '+node.gene}),circle=el('circle',{cx:p.x,cy:p.y,r:9,fill:node.original?'#b13f62':'#287c9b'}),text=el('text',{x:p.x+12,y:p.y+4,'font-size':12});text.textContent=node.gene;g.append(circle,text);g.onkeydown=event=>{if(event.key==='Enter'||event.key===' '){showNode(node);event.preventDefault()}};g.onpointerdown=event=>{if(event.button!==0)return;const pointer=pointerPosition(event);if(!pointer)return;dragging={id:node.id,pointerId:event.pointerId,offsetX:pointer.x-p.x,offsetY:pointer.y-p.y,startX:event.clientX,startY:event.clientY,moved:false};svg.setPointerCapture(event.pointerId);event.preventDefault()};svg.appendChild(g)})}",
    "svg.onpointermove=event=>{if(!dragging||event.pointerId!==dragging.pointerId)return;const pointer=pointerPosition(event);if(!pointer)return;if(Math.hypot(event.clientX-dragging.startX,event.clientY-dragging.startY)>3)dragging.moved=true;positions.set(dragging.id,{x:pointer.x-dragging.offsetX,y:pointer.y-dragging.offsetY});drawGraph()};function stopDragging(event){if(!dragging||event.pointerId!==dragging.pointerId)return;const gesture=dragging,pointerId=gesture.pointerId;dragging=null;if(svg.hasPointerCapture(pointerId))svg.releasePointerCapture(pointerId);if(event.type==='pointerup'&&!gesture.moved){const node=data.graph.nodes.find(node=>node.id===gesture.id);if(node)showNode(node)}}svg.onpointerup=stopDragging;svg.onpointercancel=stopDragging;svg.onlostpointercapture=event=>{if(dragging&&event.pointerId===dragging.pointerId)dragging=null};search.oninput=role.onchange=()=>{drawTable();drawGraph()};threshold.oninput=drawGraph;drawTable();drawGraph();",
    "</script></body></html>")
  writeLines(html, path, useBytes = TRUE)
}
