bmp_pathway_annotation <- function(options, universe, species = 9606L) {
  supplied <- c(!is.null(options$gmt), !is.null(options[["term-map"]]))
  provider <- if (is.null(options[["annotation"]])) "local" else tolower(options[["annotation"]])
  if (sum(supplied) > 1L || (provider != "local" && any(supplied))) stop("Choose one annotation source: --gmt, --term-map, or --annotation go-bp|go-mf|go-cc.", call. = FALSE)
  descriptions <- character(); provenance <- list(provider = provider, species = species)
  if (provider == "local") {
    if (!any(supplied)) stop("Offline pathway analysis requires --gmt PATH or --term-map CSV (term_id,gene_id[,description]). Optional --annotation go-bp|go-mf|go-cc requires installed annotation packages.", call. = FALSE)
    path <- normalizePath(if (supplied[1]) options$gmt else options[["term-map"]], mustWork = TRUE)
    before <- bmp_sha256(path)
    if (supplied[1]) {
      lines <- readLines(path, warn = FALSE, encoding = "UTF-8"); lines <- lines[nzchar(trimws(lines))]
      fields <- strsplit(lines, "\t", fixed = TRUE)
      if (!length(fields) || any(lengths(fields) < 3L)) stop("GMT rows require term ID, description and at least one gene separated by tabs.", call. = FALSE)
      ids <- vapply(fields, "[[", character(1), 1L)
      if (any(!nzchar(ids)) || anyDuplicated(ids)) stop("GMT term IDs must be non-blank and unique; combine duplicate terms explicitly.", call. = FALSE)
      pathways <- stats::setNames(lapply(fields, function(row) bmp_pathway_clean_ids(row[-c(1, 2)])), ids)
      descriptions <- stats::setNames(vapply(fields, "[[", character(1), 2L), ids)
      provenance$format <- "GMT"; provenance$duplicate_rows_removed <- 0L
    } else {
      frame <- bmp_read_csv(path)
      if (!all(c("term_id", "gene_id") %in% names(frame))) stop("Term mapping CSV requires term_id,gene_id columns; description is optional.", call. = FALSE)
      if (anyNA(frame[c("term_id", "gene_id")]) || any(!nzchar(trimws(frame$term_id))) || any(!nzchar(trimws(frame$gene_id)))) stop("Term and gene IDs cannot be missing or blank.", call. = FALSE)
      if (!"description" %in% names(frame)) frame$description <- frame$term_id
      frame$description[is.na(frame$description)] <- frame$term_id[is.na(frame$description)]
      desc <- split(frame$description, frame$term_id)
      if (any(vapply(desc, function(x) length(unique(x)) > 1L, logical(1)))) stop("Each term_id must have one consistent description.", call. = FALSE)
      pathways <- lapply(split(frame$gene_id, frame$term_id), bmp_pathway_clean_ids)
      descriptions <- vapply(desc, function(x) x[1L], character(1))
      provenance$format <- "term_mapping_csv"; provenance$duplicate_rows_removed <- sum(duplicated(frame[c("term_id", "gene_id")]))
    }
    if (!identical(before, bmp_sha256(path))) stop("Annotation file changed while being read.", call. = FALSE)
    provenance$path <- path; provenance$sha256 <- before
    provenance$version <- if (is.null(options[["annotation-version"]])) paste0("local-sha256:", before) else options[["annotation-version"]]
  } else if (provider %in% c("go-bp", "go-mf", "go-cc")) {
    organism <- switch(as.character(species), "9606" = "org.Hs.eg.db", "10090" = "org.Mm.eg.db", NULL)
    if (is.null(organism)) stop("Optional GO annotation supports species 9606 or 10090. For other species provide a versioned local GMT/term mapping.", call. = FALSE)
    for (package in c("AnnotationDbi", "GO.db", organism)) if (!requireNamespace(package, quietly = TRUE)) stop(paste("Optional GO annotation requires package", package, "; install it explicitly or provide --gmt / --term-map."), call. = FALSE)
    db <- get(organism, envir = asNamespace(organism)); ontology <- toupper(sub("go-", "", provider))
    keys <- intersect(universe, AnnotationDbi::keys(db, keytype = "SYMBOL"))
    frame <- if (length(keys)) suppressMessages(AnnotationDbi::select(db, keys = keys, keytype = "SYMBOL", columns = c("GOALL", "ONTOLOGYALL"))) else data.frame(SYMBOL = character(), GOALL = character(), ONTOLOGYALL = character())
    frame <- frame[!is.na(frame$GOALL) & !is.na(frame$ONTOLOGYALL) & frame$ONTOLOGYALL == ontology, , drop = FALSE]
    pathways <- lapply(split(frame$SYMBOL, frame$GOALL), bmp_pathway_clean_ids)
    if (length(pathways)) {
      details <- suppressMessages(AnnotationDbi::select(GO.db::GO.db, keys = names(pathways), keytype = "GOID", columns = "TERM"))
      descriptions <- stats::setNames(details$TERM, details$GOID)
    }
    provenance$identifier_type <- "SYMBOL"
    provenance$packages <- stats::setNames(lapply(c("AnnotationDbi", "GO.db", organism), function(x) as.character(utils::packageVersion(x))), c("AnnotationDbi", "GO.db", organism))
    provenance$organism_metadata <- AnnotationDbi::metadata(db)
    provenance$version <- paste(organism, provenance$packages[[organism]], "GO.db", provenance$packages[["GO.db"]])
    provenance$scope <- "GOALL terms (including ancestors) for mapped development QC symbols; annotation-snapshot package versions recorded."
  } else stop("Unsupported annotation provider. Use local GMT/term mapping (including exported KEGG/Reactome annotations), or optional go-bp/go-mf/go-cc.", call. = FALSE)
  if (!length(pathways)) stop("The requested annotation source contains no usable terms for this species/universe.", call. = FALSE)
  provenance$term_count <- length(pathways); provenance$annotation_gene_count <- length(unique(unlist(pathways)))
  provenance$set_sha256 <- bmp_hash_object(pathways)
  list(pathways = pathways, descriptions = descriptions, provenance = provenance)
}
bmp_pathway_universes <- function(run) {
  qc <- bmp_read_json(file.path(run$dir, "qc.json")); config <- run$config
  configured <- bmp_pathway_clean_ids(qc$measured_genes); eligible <- bmp_pathway_clean_ids(qc$eligible_genes)
  excluded_constant <- intersect(eligible, bmp_strings(qc$constant_columns))
  excluded_missing <- intersect(eligible, bmp_strings(qc$high_missing_columns))
  qc_eligible <- setdiff(eligible, union(excluded_constant, excluded_missing))
  raw <- NULL; raw_reason <- "Original input is unavailable; saved QC records the configured assay universe."
  input <- run$manifest$provenance$input
  if (!is.null(input$path) && file.exists(input$path)) {
    if (identical(bmp_sha256(input$path), input$sha256)) {
      header <- names(utils::read.csv(input$path, nrows = 0L, check.names = FALSE, fileEncoding = "UTF-8-BOM"))
      roles <- unique(c(config$sample_id, config$group_column, config$clinical_columns, config$outcome, config$time_variable, config$event))
      raw <- bmp_pathway_clean_ids(setdiff(header, roles)); raw_reason <- NULL
      if (!identical(bmp_sha256(input$path), input$sha256)) stop("Source input changed during assay-header recovery.", call. = FALSE)
    } else raw_reason <- "Original input hash changed; raw assay header was not used. Saved configured/QC background remains authoritative."
  }
  describe <- function(genes, policy, reason = NULL) list(genes = if (is.null(genes)) NULL else I(genes), count = if (is.null(genes)) NULL else length(genes), sha256 = if (is.null(genes)) NULL else bmp_hash_object(I(genes)), policy = policy, unavailable_reason = reason)
  list(raw_assay = describe(raw, "All non-identifier/outcome/clinical source CSV columns, recovered only from a hash-matching source header.", raw_reason),
    configured_assay = describe(configured, "Saved qc.measured_genes: configured feature/include/exclude restriction, before external evidence restriction."),
    configured_eligible = describe(eligible, "Saved qc.eligible_genes: configured assay after any declared external evidence restriction."),
    development_qc = describe(qc_eligible, "Configured eligible genes excluding saved full-development constant/all-missing and high-missing diagnostics. Exploratory annotation background only; never changes model fitting."),
    exclusions = list(configuration = if (is.null(raw)) NULL else I(setdiff(raw, configured)), external_prior = I(setdiff(configured, eligible)), constant_or_all_missing = I(excluded_constant), excessive_missingness = I(excluded_missing)),
    selected_background = "annotation_mapped_development_qc")
}
bmp_pathway_rank <- function(frame, universe, mapping) {
  if (!all(c("gene", "statistic") %in% names(frame))) stop("Saved gene_ranking.csv requires gene,statistic columns.", call. = FALSE)
  if (anyNA(frame$gene) || anyDuplicated(frame$gene)) stop("Saved rank source has missing or duplicate gene identifiers; do not silently duplicate statistical units.", call. = FALSE)
  frame$statistic <- suppressWarnings(as.numeric(frame$statistic))
  frame$target_id <- mapping$table$target_id[match(frame$gene, mapping$table$source_id)]
  good <- frame$gene %in% universe & !is.na(frame$target_id) & is.finite(frame$statistic)
  omitted <- frame[!good, c("gene", "statistic", "target_id"), drop = FALSE]
  omitted$reason <- ifelse(!omitted$gene %in% universe, "Outside development QC background", ifelse(is.na(omitted$target_id), "Unmapped or ambiguous identifier", "Non-estimable statistic"))
  kept <- frame[good, , drop = FALSE]
  # A many-to-one mapping represents one tested unit. Preserve the strongest
  # absolute statistic, breaking exact ties by source ID, and expose the choice.
  kept <- kept[order(-abs(kept$statistic), kept$gene, method = "radix"), , drop = FALSE]
  collapsed <- kept[duplicated(kept$target_id), , drop = FALSE]; kept <- kept[!duplicated(kept$target_id), , drop = FALSE]
  kept <- kept[order(-kept$statistic, kept$target_id, method = "radix"), , drop = FALSE]
  list(stats = stats::setNames(kept$statistic, kept$target_id), table = kept, omitted = omitted, collapsed = collapsed,
    policy = "Only finite full-development statistics within the declared QC universe; many-to-one target IDs retain greatest absolute statistic then ascending source ID. All choices are exported; no selected-panel restriction.")
}
