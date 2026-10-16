# Pathway artifacts are independent, immutable derivatives of a verified
# development run. They never alter source model/predictions/core manifests.
bmp_pathway_options <- function(options) {
  integer <- function(name, default, lower, upper) {
    value <- bmp_cli_integer(options[[name]], default, name)
    if (value < lower || value > upper) stop(sprintf("--%s must be in [%s,%s].", name, lower, upper), call. = FALSE)
    value
  }
  options$species <- integer("species", 9606L, 1L, 2147483646L)
  options[["add-nodes"]] <- integer("add-nodes", 0L, 0L, 1000L)
  options[["string-score"]] <- integer("string-score", 400L, 0L, 1000L)
  options$permutations <- integer("permutations", 1000L, 1L, 1000000L)
  options$seed <- integer("seed", 1L, 0L, 2147483646L)
  options[["min-size"]] <- integer("min-size", 5L, 1L, 1000000L)
  options[["max-size"]] <- integer("max-size", 500L, options[["min-size"]], 1000000L)
  if (is.null(options$network)) options$network <- "none"
  if (!options$network %in% c("none", "string")) stop("--network must be none (offline default) or string (public gene identifier requests).", call. = FALSE)
  if (options$network == "none" && options[["add-nodes"]] != 0L) stop("--add-nodes requires --network string.", call. = FALSE)
  options
}
bmp_pathway_output_root <- function(source, requested = NULL) {
  permitted <- file.path(source, "pathway")
  destination <- if (is.null(requested)) permitted else requested
  if (file.exists(destination) && !dir.exists(destination)) stop("Pathway output must be a directory, not an existing file.", call. = FALSE)
  # Resolve existing ancestors as well as the final component, including symlinks.
  canonical <- function(path) {
    path <- path.expand(path)
    if (!grepl("^(/|[A-Za-z]:[/\\\\])", path)) path <- file.path(getwd(), path)
    if (dir.exists(path)) return(normalizePath(path, winslash = "/", mustWork = TRUE))
    parent <- dirname(path)
    if (identical(parent, path)) stop("Cannot resolve pathway output directory.", call. = FALSE)
    resolved_parent <- canonical(parent)
    if (basename(path) == "..") return(dirname(resolved_parent))
    if (basename(path) == ".") return(resolved_parent)
    file.path(resolved_parent, basename(path))
  }
  destination <- canonical(destination); source <- normalizePath(source, winslash = "/", mustWork = TRUE)
  permitted <- file.path(source, "pathway")
  if (identical(destination, source) || startsWith(source, paste0(destination, "/")) || (startsWith(destination, paste0(source, "/")) && !(identical(destination, permitted) || startsWith(destination, paste0(permitted, "/"))))) stop("Pathway output must not overwrite the source run or its core artifact directories. Use run/pathway or a separate output directory.", call. = FALSE)
  dir.create(destination, recursive = TRUE, showWarnings = FALSE)
  normalizePath(destination, winslash = "/", mustWork = TRUE)
}
bmp_pathway_analysis <- function(run_dir, options = list()) {
  options <- bmp_pathway_options(options)
  run <- bmp_run_open(run_dir)
  lock <- bmp_lock_acquire(run$dir, "ora", options[["recover-lock"]]); on.exit(bmp_lock_release(lock), add = TRUE)
  run <- bmp_run_open(run$dir)
  if (identical(run$manifest$operation, "evaluate")) stop("Pathway ranking requires a source development run. Use --run pointing to the original development run; external outcomes must never generate development ranks.", call. = FALSE)
  if (!identical(run$manifest$status, "completed")) stop("Pathway analysis requires a completed verified development run. Complete/resume the development analysis first.", call. = FALSE)
  bmp_verify_recorded(run)
  needed <- c("manifest.json", "config.json", "qc.json", "model.bmpmodel", "predictions.csv", "stability.csv", "gene_ranking.csv")
  if (any(!file.exists(file.path(run$dir, needed)))) stop("Development run lacks saved gene ranking/stability. Retrain with the shared engine; selected genes alone cannot reconstruct a valid background.", call. = FALSE)
  source_hashes <- stats::setNames(lapply(file.path(run$dir, needed), bmp_sha256), needed)
  model <- bmp_cli_load_model(file.path(run$dir, "model.bmpmodel"))
  output <- bmp_pathway_output_root(run$dir, options$output)
  parent <- file.path(output, "runs"); dir.create(parent, recursive = TRUE, showWarnings = FALSE)
  repeat {
    id <- paste0(format(Sys.time(), "%Y%m%dT%H%M%S", tz = "UTC"), "-pathway-", basename(tempfile(pattern = "")))
    directory <- file.path(parent, id)
    if (dir.create(directory, showWarnings = FALSE)) break
    if (!dir.exists(parent) || file.access(parent, 2L) != 0L) stop("Pathway output directory is not writable.", call. = FALSE)
  }
  module_paths <- c(list.files(file.path(bmp_repo_root, "R"), pattern = "\\.R$", full.names = TRUE),
    file.path(bmp_repo_root, c("BiomarkerCLI.R", "ORA_PPI_Analysis.R")))
  manifest <- list(schema_version = 1L, operation = "ora", run_id = id, run_dir = directory, source_run_id = run$id, source_run_dir = run$dir,
    status = "running", stage = "source_snapshot", created_at = bmp_now(), updated_at = bmp_now(),
    interpretation = "Exploratory full-development annotation analysis; separate from held-out prediction performance.",
    source_sha256 = source_hashes, options = options,
    provenance = list(r_version = R.version.string, platform = R.version$platform,
      packages = stats::setNames(lapply(c("jsonlite", "digest"), function(package) as.character(utils::packageVersion(package))), c("jsonlite", "digest")),
      modules = stats::setNames(lapply(module_paths, bmp_sha256), basename(module_paths))),
    warnings = character(), errors = character(), required_artifacts = character())
  write_manifest <- function() {
    manifest$updated_at <<- bmp_now()
    bmp_atomic_json(manifest, file.path(directory, "manifest.json"))
    bmp_atomic_json(list(run_id = id, run_dir = directory, source_run_id = run$id, status = manifest$status), file.path(output, "latest.json"))
  }
  event <- function(type, message, current = NULL) bmp_engine_event(type, run_id = id, run_dir = directory, source_run_id = run$id, status = manifest$status, current = current, total = 6L, message = message)
  write_manifest(); event("run_start", "Starting isolated exploratory pathway analysis", 0L)
  tryCatch({
    universes <- bmp_pathway_universes(run)
    configured <- bmp_strings(universes$configured_assay$genes); qc_genes <- bmp_strings(universes$development_qc$genes)
    if (!length(qc_genes)) manifest$warnings <- c(manifest$warnings, "The saved development QC universe is empty; no enrichment statistic is estimable.")
    original <- bmp_pathway_clean_ids(model$selected_genes)
    map_input <- NULL; map_provenance <- list(mode = "identity", policy = "Exact identifier matching; no case folding or automatic species/identifier conversion.")
    if (!is.null(options$mapping)) {
      before <- bmp_sha256(options$mapping); map_input <- bmp_read_csv(options$mapping)
      if (!identical(before, bmp_sha256(options$mapping))) stop("Identifier mapping changed while being read.", call. = FALSE)
      map_provenance <- list(mode = "local_mapping_csv", path = normalizePath(options$mapping), sha256 = before)
    }
    manifest$stage <- "annotation"; write_manifest(); event("pathway_annotation", "Loading explicit annotation and identifier units", 1L)
    preliminary <- bmp_pathway_map(unique(c(configured, original)), map_input)
    annotation <- bmp_pathway_annotation(options, preliminary$mapped, options$species)
    # Snapshot local annotations/mappings as reproducibility inputs, not patient data.
    dir.create(file.path(directory, "inputs"), showWarnings = FALSE)
    if (!is.null(annotation$provenance$path)) {
      destination <- file.path(directory, "inputs", if (!is.null(options$gmt)) "annotation.gmt" else "annotation.csv")
      if (!file.copy(annotation$provenance$path, destination) || !identical(bmp_sha256(destination), annotation$provenance$sha256)) stop("Annotation snapshot did not match the read annotation hash.", call. = FALSE)
    }
    if (!is.null(options$mapping)) {
      destination <- file.path(directory, "inputs", "identifier_mapping.csv")
      if (!file.copy(options$mapping, destination) || !identical(bmp_sha256(destination), map_provenance$sha256)) stop("Identifier mapping snapshot did not match its source hash.", call. = FALSE)
    }
    bmp_atomic_json(list(pathways = lapply(annotation$pathways, I), descriptions = as.list(annotation$descriptions), provenance = annotation$provenance), file.path(directory, "annotation.json"))
    network <- list(status = "not_requested", reason = "Offline analysis: no STRING requests or expansion were requested.",
      nodes = data.frame(id = if (length(original)) paste0("gene:", original) else character(), gene = original, original = rep(TRUE, length(original)), query_genes = original, stringsAsFactors = FALSE),
      edges = bmp_string_empty_edges(),
      mapping = data.frame(source_id = character(), target_id = character(), preferred_name = character(), status = character()), requests = list())
    if (options$network == "string") {
      manifest$stage <- "network"; write_manifest(); event("pathway_network", "Mapping public gene identifiers and retrieving explicit STRING expansion", 2L)
      network$source <- "https://version-12-5.string-db.org/api/json"; network$version <- "12.5"; network$species <- options$species
      network$add_nodes <- options[["add-nodes"]]; network$required_score <- options[["string-score"]]; network$network_type <- "functional"
      network <- tryCatch(bmp_string_network(original, options$species, options[["add-nodes"]], options[["string-score"]], transport = getOption("bmp.string.transport", NULL), cache_dir = file.path(directory, "string_responses")), error = function(error) {
        failed <- network; failed$status <- "failed"; failed$reason <- conditionMessage(error); failed
      })
      request_files <- list.files(file.path(directory, "string_responses"), pattern = "-request\\.json$", full.names = TRUE)
      if (length(request_files)) network$requests <- unname(lapply(request_files, bmp_read_json))
      if (network$status %in% c("failed", "partial")) manifest$warnings <- c(manifest$warnings, paste("Requested STRING network is", network$status, ":", network$reason))
    }
    added_labels <- bmp_pathway_clean_ids(network$nodes$gene[!network$nodes$original])
    # Resolve added target-name aliases only through the explicit annotation
    # mapping back to recorded assay genes. No fuzzy or implicit ID conversion.
    qc_map <- preliminary$table[preliminary$table$source_id %in% qc_genes & !is.na(preliminary$table$target_id), , drop = FALSE]
    project_added <- function(label) {
      if (label %in% configured) return(label)
      sources <- if (is.null(map_input)) character() else qc_map$source_id[qc_map$target_id == label]
      if (length(sources)) sources else label
    }
    node_sources <- lapply(seq_len(nrow(network$nodes)), function(i) {
      node <- network$nodes[i, , drop = FALSE]
      if (node$original) {
        sources <- network$mapping$source_id[!is.na(network$mapping$target_id) & network$mapping$target_id == node$id]
        if (!length(sources) && startsWith(node$id, "gene:")) sources <- original[original == node$gene]
        sources
      } else project_added(node$gene)
    })
    expanded <- bmp_pathway_clean_ids(c(original, unlist(node_sources[!network$nodes$original], use.names = FALSE)))
    assay_rows <- lapply(seq_along(node_sources), function(i) data.frame(node_id = rep(network$nodes$id[i], length(node_sources[[i]])), source_id = node_sources[[i]], original = rep(network$nodes$original[i], length(node_sources[[i]])), stringsAsFactors = FALSE))
    network$assay_mapping <- if (length(assay_rows)) do.call(rbind, assay_rows) else data.frame(node_id = character(), source_id = character(), original = logical())
    network$projection_policy <- "Original STRING nodes retain queried source IDs. Added preferred names map to measured source IDs only by exact source match or an explicit unambiguous annotation target mapping; unmeasured labels stay outside the assay background."
    network$nodes$query_genes <- vapply(node_sources, paste, character(1), collapse = ";")
    mapped <- bmp_pathway_map(unique(c(configured, original, expanded)), map_input)
    lookup <- function(genes) bmp_pathway_clean_ids(mapped$table$target_id[match(genes, mapped$table$source_id)])
    annotation_ids <- bmp_pathway_clean_ids(unlist(annotation$pathways, use.names = FALSE))
    background <- intersect(lookup(qc_genes), annotation_ids)
    universes$annotation_mapped <- list(genes = I(background), count = length(background), sha256 = bmp_hash_object(I(background)), policy = "Unique unambiguous mapped identifiers from development_qc that occur in at least one supplied annotation term.",
      unmapped_source_genes = I(qc_genes[is.na(mapped$table$target_id[match(qc_genes, mapped$table$source_id)])]), unannotated_target_ids = I(setdiff(lookup(qc_genes), annotation_ids)))
    if (length(qc_genes) && !length(background)) stop("No development QC genes map to the annotation source. Verify species and identifier units; supply --mapping source_id,target_id if needed.", call. = FALSE)
    mapped_original <- intersect(lookup(intersect(original, qc_genes)), background)
    mapped_expanded <- intersect(lookup(intersect(expanded, qc_genes)), background)
    sets <- list(original = I(original), expanded = I(expanded), network_added = I(added_labels),
      expanded_unit = "Source assay identifiers after explicit mapping projection; unresolved added network labels retained for visibility but excluded from tests.",
      original_tested_ids = I(mapped_original), expanded_tested_ids = I(mapped_expanded), expanded_excluded_from_assay_background = I(setdiff(expanded, qc_genes)))
    bmp_atomic_json(universes, file.path(directory, "universes.json")); bmp_atomic_csv(mapped$table, file.path(directory, "identifier_mapping.csv"))
    manifest$stage <- "enrichment"; write_manifest(); event("pathway_statistics", "Computing original/expanded ORA and full-ranked GSEA", 3L)
    original_ora <- bmp_pathway_ora(mapped_original, annotation$pathways, background, options[["min-size"]], options[["max-size"]])
    expanded_ora <- bmp_pathway_ora(mapped_expanded, annotation$pathways, background, options[["min-size"]], options[["max-size"]])
    ranking <- bmp_pathway_rank(bmp_read_csv(file.path(run$dir, "gene_ranking.csv")), qc_genes, mapped)
    # Include all finite mapped QC ranks, including annotation-unmatched IDs:
    # GSEA's miss denominator must represent the full ranked universe.
    gsea <- bmp_pathway_gsea(ranking$stats, annotation$pathways, options$permutations, options$seed, options[["min-size"]], options[["max-size"]])
    describe <- function(frame) { frame$description <- unname(annotation$descriptions[frame$term_id]); frame$background <- rep("annotation_mapped_development_qc", nrow(frame)); frame }
    original_ora <- describe(original_ora); expanded_ora <- describe(expanded_ora)
    gsea$results$description <- unname(annotation$descriptions[gsea$results$term_id]); gsea$results$background <- rep("full_finite_mapped_development_qc_rank", nrow(gsea$results))
    bmp_atomic_csv(original_ora, file.path(directory, "ora_original.csv")); bmp_atomic_csv(expanded_ora, file.path(directory, "ora_expanded.csv")); bmp_atomic_csv(gsea$results, file.path(directory, "gsea.csv"))
    bmp_atomic_csv(ranking$table, file.path(directory, "ranked_genes.csv")); bmp_atomic_csv(ranking$omitted, file.path(directory, "rank_exclusions.csv")); bmp_atomic_csv(ranking$collapsed, file.path(directory, "rank_collapsed.csv"))
    bmp_atomic_json(list(metadata = gsea$metadata, rank_policy = ranking$policy, results = gsea$results), file.path(directory, "gsea.json"))
    manifest$stage <- "gene_evidence"; write_manifest(); event("pathway_evidence", "Joining saved stability, coefficients, ranks and supplied external evidence", 4L)
    evidence_error <- NULL
    evidence <- tryCatch(bmp_pathway_evidence(run, model, universes, mapped, ranking, annotation$pathways, network, options), error = function(error) { evidence_error <<- conditionMessage(error); NULL })
    if (is.null(evidence)) {
      # Preserve core gene evidence when a separately requested external source
      # fails, and expose the failure as partial rather than missing=zero.
      fallback_run <- run; fallback_run$manifest$provenance$evidence <- NULL; fallback_options <- options; fallback_options$evidence <- NULL
      evidence <- bmp_pathway_evidence(fallback_run, model, universes, mapped, ranking, annotation$pathways, network, fallback_options)
      evidence$external_evidence <- list(status = "failed", reason = evidence_error)
      manifest$warnings <- c(manifest$warnings, paste("Supplied external evidence unavailable:", evidence_error))
    }
    raw_measured <- if (is.null(universes$raw_assay$genes)) configured else bmp_strings(universes$raw_assay$genes)
    network$nodes$measured <- vapply(node_sources, function(genes) any(genes %in% raw_measured), logical(1))
    network$nodes$development_qc_eligible <- vapply(node_sources, function(genes) any(genes %in% qc_genes), logical(1))
    network$nodes$assay_background_eligible <- vapply(node_sources, function(genes) any(lookup(intersect(genes, qc_genes)) %in% background), logical(1))
    if (identical(evidence$external_evidence$status, "provided")) {
      destination <- file.path(directory, "inputs", "external_evidence.csv")
      if (!file.copy(evidence$external_evidence$path, destination) || !identical(bmp_sha256(destination), evidence$external_evidence$sha256)) stop("External evidence snapshot changed after its records were read.", call. = FALSE)
    }
    network$schema_version <- 1L
    bmp_atomic_json(network, file.path(directory, "graph.json")); bmp_atomic_csv(network$nodes, file.path(directory, "network_nodes.csv")); bmp_atomic_csv(network$edges, file.path(directory, "network_edges.csv")); bmp_atomic_csv(network$mapping, file.path(directory, "string_mapping.csv"))
    bmp_atomic_json(evidence[setdiff(names(evidence), "table")], file.path(directory, "gene_evidence.json")); bmp_atomic_csv(evidence$table, file.path(directory, "gene_evidence.csv"))
    partial <- network$status %in% c("failed", "partial") || !is.null(evidence_error)
    status <- if (partial) "partial" else "completed"
    if (!length(original)) manifest$warnings <- c(manifest$warnings, "Final model selected no genes: original/expanded ORA is unavailable with explicit reasons; full-ranked GSEA remains separate.")
    if (!any(is.finite(gsea$results$p_value))) manifest$warnings <- c(manifest$warnings, "No GSEA term was estimable under the declared rank/size/permutation rules; inspect per-term reasons.")
    if (length(mapped$metadata$unmapped) || length(mapped$metadata$ambiguous)) manifest$warnings <- c(manifest$warnings, "Some identifiers were unmapped or ambiguous and excluded; inspect identifier_mapping.csv and mapping metadata.")
    if (length(sets$expanded_excluded_from_assay_background)) manifest$warnings <- c(manifest$warnings, "Network-expanded genes outside the declared assay QC universe were excluded from ORA.")
    summary <- list(schema_version = 1L, operation = "ora", run_id = id, run_dir = directory, source_run_id = run$id, source_run_dir = run$dir, status = status,
      interpretation = manifest$interpretation, options = options, gene_sets = sets, universes = universes,
      mapping = c(map_provenance, mapped$metadata), annotation = annotation$provenance, network = network[intersect(c("status", "reason", "source", "version", "species", "add_nodes", "required_score", "network_type", "interpretation", "requests"), names(network))],
      methods = list(ora_original = attr(original_ora, "family"), ora_expanded = attr(expanded_ora, "family"), gsea = gsea$metadata, rank_policy = ranking$policy),
      evidence = evidence$external_evidence, warnings = I(unique(manifest$warnings)), source_sha256 = source_hashes)
    bmp_atomic_json(summary, file.path(directory, "summary.json"))
    manifest$stage <- "figures"; write_manifest(); event("pathway_reports", "Rendering saved-table figures and interactive evidence summary", 5L)
    figures <- bmp_pathway_figures(directory, original_ora, expanded_ora, gsea$results, network, id)
    bmp_pathway_html(file.path(directory, "report.html"), summary, original_ora, expanded_ora, gsea$results, evidence, network, figures)
    if (!isTRUE(bmp_verify_artifacts(run$dir, needed, source_hashes)$ok)) stop("Source run artifacts changed during pathway analysis; derivative cannot be attributed to an immutable source.", call. = FALSE)
    bmp_verify_recorded(bmp_run_open(run$dir))
    required <- list.files(directory, recursive = TRUE, all.files = FALSE)
    required <- setdiff(required, "manifest.json")
    verified <- bmp_verify_artifacts(directory, required)
    if (!verified$ok) stop("Pathway artifact verification failed.", call. = FALSE)
    manifest$status <- status; manifest$stage <- if (partial) "requested_component_unavailable" else "complete"; manifest$finished_at <- bmp_now()
    manifest$warnings <- unique(manifest$warnings); manifest$required_artifacts <- I(required); manifest$artifact_verification <- verified
    manifest$components <- list(annotation = "completed", ora = "completed", gsea = "completed", network = network$status, evidence = evidence$external_evidence$status, reports = "completed")
    write_manifest(); event(if (partial) "partial" else "completed", if (partial) "Pathway artifacts saved; a requested network/evidence component failed or was incomplete" else "Pathway artifacts verified", 6L)
    list(ok = !partial, operation = "ora", status = status, run_id = id, run_dir = directory, source_run_id = run$id, source_run_dir = run$dir,
      warnings = I(manifest$warnings), components = manifest$components,
      paths = list(manifest = file.path(directory, "manifest.json"), summary = file.path(directory, "summary.json"), report_html = file.path(directory, "report.html"),
        ora_original = file.path(directory, "ora_original.csv"), ora_expanded = file.path(directory, "ora_expanded.csv"), gsea = file.path(directory, "gsea.json"), graph = file.path(directory, "graph.json"), evidence = file.path(directory, "gene_evidence.json"), figures = file.path(directory, "figures", "index.json")))
  }, error = function(error) {
    manifest$status <<- "failed"; manifest$errors <<- conditionMessage(error); manifest$finished_at <<- bmp_now()
    try(write_manifest(), silent = TRUE); event("failed", conditionMessage(error))
    error$run_id <- id; error$run_dir <- directory; stop(error)
  }, interrupt = function(error) { manifest$status <<- "cancelled"; manifest$errors <<- "Interrupted"; manifest$finished_at <<- bmp_now(); try(write_manifest(), silent = TRUE); stop(error) })
}
