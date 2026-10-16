# Exploratory annotation statistics. These functions never fit a predictive model.
bmp_pathway_ids <- function(x) sort(unique(as.character(unlist(x, use.names = FALSE))), method = "radix")
bmp_pathway_clean_ids <- function(x) {
  x <- as.character(unlist(x, use.names = FALSE))
  sort(unique(x[!is.na(x) & nzchar(trimws(x))]), method = "radix")
}
bmp_pathway_map <- function(genes, mapping = NULL) {
  raw <- as.character(genes); genes <- bmp_pathway_clean_ids(genes)
  if (is.null(mapping)) mapping <- data.frame(source_id = genes, target_id = genes, stringsAsFactors = FALSE)
  if (!is.data.frame(mapping) || !all(c("source_id", "target_id") %in% names(mapping))) stop("Identifier mapping CSV requires source_id,target_id columns.", call. = FALSE)
  mapping <- mapping[c("source_id", "target_id")]
  mapping[] <- lapply(mapping, as.character)
  if (anyNA(mapping) || any(!nzchar(trimws(mapping$source_id))) || any(!nzchar(trimws(mapping$target_id)))) stop("Mapping identifiers must be non-missing and non-blank.", call. = FALSE)
  duplicates <- sum(duplicated(mapping)); mapping <- unique(mapping)
  candidates <- split(mapping$target_id, mapping$source_id)
  table <- data.frame(source_id = genes, target_id = rep(NA_character_, length(genes)), status = rep("unmapped", length(genes)), target_candidates = rep("", length(genes)), stringsAsFactors = FALSE)
  for (i in seq_along(genes)) {
    targets <- bmp_pathway_clean_ids(candidates[[genes[i]]]); table$target_candidates[i] <- paste(targets, collapse = ";")
    if (length(targets) == 1L) { table$target_id[i] <- targets; table$status[i] <- "mapped" }
    if (length(targets) > 1L) table$status[i] <- "ambiguous_excluded"
  }
  targets <- table$target_id[table$status == "mapped"]
  collapsed <- bmp_pathway_clean_ids(names(which(table(targets) > 1L)))
  table$status[!is.na(table$target_id) & table$target_id %in% collapsed] <- "mapped_collapsed"
  list(table = table, mapped = bmp_pathway_clean_ids(targets), metadata = list(
    input_count = length(raw), unique_source_count = length(genes), duplicate_input_count = length(raw) - length(genes), duplicate_mapping_rows_removed = duplicates,
    mapped_source_count = sum(!is.na(table$target_id)), mapped_target_count = length(unique(targets)),
    unmapped = I(table$source_id[table$status == "unmapped"]), ambiguous = I(table$source_id[table$status == "ambiguous_excluded"]), collapsed_targets = I(collapsed),
    policy = "Exclude one-to-many ambiguous mappings; collapse many source IDs to one unique target statistical unit; no identifier is duplicated."))
}
bmp_pathway_ora <- function(query, pathways, universe, min_size = 1L, max_size = 5000L) {
  query_count_before_background <- length(bmp_pathway_clean_ids(query))
  universe <- bmp_pathway_clean_ids(universe); query <- intersect(bmp_pathway_clean_ids(query), universe)
  if (is.null(names(pathways)) || anyDuplicated(names(pathways)) || any(!nzchar(names(pathways)))) stop("Pathways must be a uniquely named list of identifier sets.", call. = FALSE)
  rows <- lapply(sort(names(pathways), method = "radix"), function(term) {
    members <- intersect(bmp_pathway_clean_ids(pathways[[term]]), universe)
    overlap <- intersect(query, members); m <- length(members); n <- length(query); N <- length(universe)
    reason <- if (!N) "Empty annotation-mapped background." else if (m < min_size || m > max_size) "Term size outside declared background-intersected size limits." else if (!n) "No query genes in the annotation-mapped background." else NA_character_
    p <- if (is.na(reason)) stats::phyper(length(overlap) - 1L, m, N - m, n, lower.tail = FALSE) else NA_real_
    data.frame(term_id = term, term_size = m, query_size = n, universe_size = N, overlap = length(overlap), p_value = p, adjusted_p_value = NA_real_, overlap_genes = paste(overlap, collapse = ";"), reason = reason, stringsAsFactors = FALSE)
  })
  empty <- data.frame(term_id = character(), term_size = integer(), query_size = integer(), universe_size = integer(), overlap = integer(), p_value = numeric(), adjusted_p_value = numeric(), overlap_genes = character(), reason = character())
  result <- if (length(rows)) do.call(rbind, rows) else empty
  good <- which(is.finite(result$p_value)); result$adjusted_p_value[good] <- stats::p.adjust(result$p_value[good], method = "BH")
  attr(result, "family") <- list(method = "BH", eligible_tested_terms = length(good), includes_zero_overlap = TRUE, unit = "unique mapped target identifier", test = "one-sided hypergeometric over-representation", query_count_before_background = query_count_before_background)
  result
}
bmp_gsea_es <- function(stats, genes, exponent = 1) {
  if (!is.numeric(stats) || is.null(names(stats)) || anyDuplicated(names(stats)) || anyNA(names(stats)) || any(!nzchar(names(stats))) || any(!is.finite(stats))) stop("ES requires finite statistics with unique non-blank identifier names in ranked order.", call. = FALSE)
  if (length(exponent) != 1L || !is.finite(exponent) || exponent < 0) stop("GSEA exponent must be a finite nonnegative number.", call. = FALSE)
  hits <- which(names(stats) %in% unique(genes)); n <- length(stats); k <- length(hits)
  reason <- if (!n) "Empty ranked universe." else if (!k) "No term members in the ranked universe." else if (k == n) "Term covers the whole ranked universe; miss denominator is zero." else NA_character_
  if (!is.na(reason)) return(list(es = NA_real_, leading_edge = character(), reason = reason, running_score = numeric()))
  weights <- abs(stats[hits])^exponent
  if (!is.finite(sum(weights))) return(list(es = NA_real_, leading_edge = character(), reason = "Term hit weights are non-finite.", running_score = numeric()))
  if (sum(weights) <= 0) weights <- rep(1, k)
  increments <- rep(-1/(n-k), n); increments[hits] <- weights/sum(weights)
  running <- cumsum(increments); maximum <- max(running); minimum <- min(running)
  if (abs(maximum - abs(minimum)) <= 1e-12) return(list(es = 0, leading_edge = character(), reason = NA_character_, running_score = running))
  positive <- maximum > abs(minimum)
  at <- if (positive) which.max(running) else which.min(running)
  lead <- if (positive) hits[hits <= at] else hits[hits > at]
  list(es = if (positive) maximum else minimum, leading_edge = names(stats)[lead], reason = NA_character_, running_score = running)
}
bmp_gsea_null_es <- function(stats, size, exponent) {
  n <- length(stats); positions <- sort(sample.int(n, size, replace = FALSE))
  weights <- abs(stats[positions])^exponent; total <- sum(weights)
  if (!is.finite(total)) return(NA_real_)
  if (total <= 0) { weights <- rep(1, size); total <- size }
  accumulated <- cumsum(weights/total)
  after <- accumulated - (positions - seq_len(size))/(n-size)
  before <- c(0, head(accumulated, -1L)) - (positions - seq_len(size))/(n-size)
  high <- max(c(0, after)); low <- min(c(0, before))
  if (abs(high - abs(low)) <= 1e-12) return(0)
  if (high > abs(low)) high else low
}
bmp_pathway_gsea <- function(stats, pathways, permutations = 1000L, seed = 1L, min_size = 1L, max_size = 5000L, exponent = 1) {
  if (!is.numeric(stats) || is.null(names(stats)) || anyDuplicated(names(stats)) || anyNA(names(stats)) || any(!nzchar(names(stats)))) stop("GSEA requires uniquely named statistics; resolve duplicate identifiers explicitly before testing.", call. = FALSE)
  if (length(permutations) != 1L || !is.finite(permutations) || permutations < 1 || permutations != floor(permutations)) stop("GSEA permutations must be a positive integer.", call. = FALSE)
  if (is.null(names(pathways)) || anyDuplicated(names(pathways))) stop("Pathway IDs must be unique.", call. = FALSE)
  omitted <- names(stats)[!is.finite(stats)]; stats <- stats[is.finite(stats)]
  stats <- stats[order(-stats, names(stats), method = "radix")]
  old_kind <- RNGkind(); had_seed <- exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)
  if (had_seed) old_seed <- get(".Random.seed", envir = .GlobalEnv)
  on.exit({ do.call(RNGkind, as.list(old_kind)); if (had_seed) assign(".Random.seed", old_seed, envir = .GlobalEnv) else if (exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)) rm(".Random.seed", envir = .GlobalEnv) }, add = TRUE)
  RNGkind("Mersenne-Twister", "Inversion", "Rejection"); set.seed(seed)
  null_by_size <- list(); rows <- list()
  # Under the competitive gene-label null, a uniformly sampled same-size set is
  # equivalent to permuting all rank labels. Reuse it by size, never by outcome.
  for (term in sort(names(pathways), method = "radix")) {
    members <- intersect(bmp_pathway_clean_ids(pathways[[term]]), names(stats)); size <- length(members)
    observed <- bmp_gsea_es(stats, members, exponent)
    if (length(stats) > 1L && length(unique(stats)) == 1L) { observed$es <- NA_real_; observed$leading_edge <- character(); observed$reason <- "All ranked statistics are identical; no meaningful enrichment ordering is available." }
    reason <- if (size < min_size || size > max_size) "Term size outside declared ranked-universe size limits." else observed$reason
    nes <- p <- resolution <- NA_real_; same_count <- valid_count <- 0L
    if (is.na(reason)) {
      key <- as.character(size)
      if (is.null(null_by_size[[key]])) null_by_size[[key]] <- vapply(seq_len(permutations), function(i) bmp_gsea_null_es(stats, size, exponent), numeric(1))
      null <- null_by_size[[key]]; valid_count <- sum(is.finite(null))
      same <- null[is.finite(null) & if (observed$es >= 0) null >= 0 else null <= 0]; same_count <- length(same)
      if (!length(same) || mean(abs(same)) <= 0) reason <- "No finite same-sign null scores with positive normalization denominator."
      else { nes <- observed$es / mean(abs(same)); p <- (1 + sum(abs(same) >= abs(observed$es) - 1e-12))/(1 + length(same)); resolution <- 1/(1 + length(same)) }
    }
    rows[[length(rows) + 1L]] <- data.frame(term_id = term, term_size = size, es = observed$es, nes = nes, p_value = p, adjusted_p_value = NA_real_, leading_edge = paste(observed$leading_edge, collapse = ";"), reason = reason, permutations = permutations, finite_permutations = valid_count, same_sign_permutations = same_count, minimum_p_value = resolution, stringsAsFactors = FALSE)
  }
  result <- if (length(rows)) do.call(rbind, rows) else data.frame(term_id = character(), term_size = integer(), es = numeric(), nes = numeric(), p_value = numeric(), adjusted_p_value = numeric(), leading_edge = character(), reason = character(), permutations = integer(), finite_permutations = integer(), same_sign_permutations = integer(), minimum_p_value = numeric())
  good <- which(is.finite(result$p_value)); result$adjusted_p_value[good] <- stats::p.adjust(result$p_value[good], "BH")
  list(results = result, metadata = list(method = "weighted preranked GSEA", null = "competitive gene-label permutation; uniformly sampled same-size gene sets; not phenotype permutations", permutations = permutations, seed = seed, rng = "Mersenne-Twister/Inversion/Rejection", exponent = exponent,
    excursion_tie_policy = "Equal positive and negative excursion magnitudes within 1e-12 yield ES=0 and empty leading edge; all-zero hit weights use uniform weights.", normalization = "ES divided by mean absolute null ES of the observed sign, including neutral ES=0 in both sign pools", p_value = "(1 + same-sign null scores at least as extreme)/(1 + finite same-sign null count)", adjustment = "BH across estimable terms; adjusted p-values are not GSEA FDR q-values", tested_terms = length(good),
    ranked_gene_count = length(stats), non_estimable_genes_excluded = I(omitted), tied_statistics = sum(duplicated(stats)), tie_policy = "Descending statistic, then ascending identifier byte order (radix); tie order is deterministic but may affect ES.", interpretation = "Exploratory full-development association; does not estimate held-out predictive performance."))
}
