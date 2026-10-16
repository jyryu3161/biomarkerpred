# Primary-session numerical oracles; independent of pathway implementation.
source("R/load.R")

near <- function(actual, expected, tolerance = 1e-11) {
  stopifnot(length(actual) == length(expected),
    isTRUE(all.equal(as.numeric(actual), as.numeric(expected), tolerance = tolerance)))
}
universe <- LETTERS[1:10]
# A version option must not partially match the absent annotation provider.
local({
  gmt <- file.path(bmp_repo_root, "tests", "fixtures", "pathways", "synthetic.gmt")
  base <- bmp_pathway_annotation(list(gmt = gmt), universe)
  declared <- bmp_pathway_annotation(list(gmt = gmt, `annotation-version` = "review-2026"), universe)
  stopifnot(identical(base$pathways, declared$pathways),
    identical(declared$provenance$provider, "local"), identical(declared$provenance$version, "review-2026"))
  mapping <- tempfile(fileext = ".csv")
  on.exit(unlink(mapping), add = TRUE)
  bmp_atomic_csv(data.frame(term_id = "T", gene_id = c("A", "B")), mapping)
  mapped <- bmp_pathway_annotation(list(`term-map` = mapping, `annotation-version` = "term-review"), universe)
  stopifnot(identical(mapped$provenance$provider, "local"), identical(mapped$provenance$version, "term-review"))
})
terms <- list(enriched = c("A", "B", "D"), no_overlap = c("G", "H", "I"),
  outside = c("A", "B", "D", "OUTSIDE"))
ora <- bmp_pathway_ora(c("A", "B", "C", "NOT_MEASURED"), terms, universe)
stopifnot(nrow(ora) == 3L)
row <- ora[ora$term_id == "enriched", ]
near(row$p_value, 22/120)
stopifnot(row$query_size == 3L, row$term_size == 3L, row$universe_size == 10L, row$overlap == 2L)
near(ora$p_value[ora$term_id == "outside"], 22/120)
near(ora$p_value[ora$term_id == "no_overlap"], 1)
near(ora$adjusted_p_value, stats::p.adjust(ora$p_value, "BH"))

# Enumerate every possible query subset for a tiny universe. This oracle uses
# the actual combinatorial tail count, independently of phyper or Fisher tests.
for (n in 5:9) {
  population <- paste0("G", seq_len(n))
  for (query_size in 1:3) {
    query <- population[seq_len(query_size)]
    pathways <- list(first = population[seq_len(3)], last = tail(population, 3),
      alternating = population[seq(1, n, 2)])
    value <- bmp_pathway_ora(query, pathways, population)
    all_queries <- combn(population, query_size, simplify = FALSE)
    for (term in names(pathways)) {
      observed <- length(intersect(query, pathways[[term]]))
      exact <- mean(vapply(all_queries, function(candidate) length(intersect(candidate, pathways[[term]])) >= observed, logical(1)))
      near(value$p_value[value$term_id == term], exact)
    }
  }
}

# Independent running-sum definition; include the initial zero in the walk.
es_reference <- function(statistics, members, exponent = 1) {
  hit <- names(statistics) %in% members
  hit_weight <- abs(statistics[hit])^exponent
  if (!sum(hit_weight)) hit_weight[] <- 1
  increment <- rep(-1/sum(!hit), length(statistics))
  increment[hit] <- hit_weight/sum(hit_weight)
  walk <- c(0, cumsum(increment))
  if (abs(max(walk) + min(walk)) < 1e-12) 0 else walk[which.max(abs(walk))]
}
statistics <- stats::setNames(c(5,4,3,2,1,-1,-2,-3,-4,-5), universe)
positive <- bmp_gsea_es(statistics, c("A", "B"))
negative <- bmp_gsea_es(statistics, c("I", "J"))
near(positive$es, 1); near(negative$es, -1)
stopifnot(setequal(unlist(positive$leading_edge), c("A", "B")),
  setequal(unlist(negative$leading_edge), c("I", "J")))
whole <- bmp_gsea_es(statistics, universe)
stopifnot(!length(whole$es) || is.na(whole$es), length(whole$reason) > 0L, nzchar(whole$reason))
symmetry <- bmp_gsea_es(stats::setNames(4:1, LETTERS[1:4]), c("A", "D"), exponent = 0)
near(symmetry$es, 0)
stopifnot(!length(unlist(symmetry$leading_edge)))
zero_hit_weight <- bmp_gsea_es(stats::setNames(c(3,0,-2,-4), LETTERS[1:4]), "B")
near(zero_hit_weight$es, 2/3)

set.seed(926)
for (iteration in seq_len(150)) {
  count <- sample(8:35, 1)
  score <- stats::setNames(round(stats::rnorm(count), 1) + .013, paste0("gene_", seq_len(count)))
  score <- score[order(-score, names(score))]
  members <- sample(names(score), sample(1:(count-1L), 1))
  power <- sample(c(0, 1, 2), 1)
  actual <- bmp_gsea_es(score, members, exponent = power)
  near(actual$es, es_reference(score, members, power))
}

ranked_terms <- list(top = c("A", "B"), bottom = c("I", "J"), mixed = c("A", "F", "I"))
gsea <- bmp_pathway_gsea(statistics, ranked_terms, permutations = 99L, seed = 101L)
repeated <- bmp_pathway_gsea(statistics[rev(seq_along(statistics))], ranked_terms, permutations = 99L, seed = 101L)
stopifnot(identical(gsea$results, repeated$results))
result <- gsea$results
near(result$es[result$term_id == "top"], 1)
near(result$es[result$term_id == "bottom"], -1)
stopifnot(result$nes[result$term_id == "top"] > 0, result$nes[result$term_id == "bottom"] < 0,
  all(result$p_value >= 1/100 & result$p_value <= 1),
  all(is.finite(result$nes)))
near(result$adjusted_p_value, stats::p.adjust(result$p_value, "BH"))
constant <- bmp_pathway_gsea(stats::setNames(rep(0, 10), universe), ranked_terms,
  permutations = 19L, seed = 5L)$results
stopifnot(all(is.na(constant$nes)), all(is.na(constant$p_value)),
  all(!is.na(constant$reason) & nzchar(constant$reason)))

# Check the Monte Carlo normalization/tail against an independently enumerated
# competitive null. Unequal positive/negative weights expose accidental use of
# an unconditional or absolute-value denominator. Tolerances cover sampling.
skewed <- stats::setNames(c(10,8,4,3,1,-.2,-1,-2,-3,-4), universe)
all_pairs <- combn(universe, 2, simplify = FALSE)
exact_null <- vapply(all_pairs, function(pair) es_reference(skewed, pair), numeric(1))
simulation <- bmp_pathway_gsea(skewed, list(top = c("A", "B"), bottom = c("I", "J")),
  permutations = 4999L, seed = 2026L)$results
for (term in c("top", "bottom")) {
  observed <- if (term == "top") 1 else -1
  same_sign <- exact_null[if (observed > 0) exact_null >= 0 else exact_null <= 0]
  exact_nes <- observed/mean(abs(same_sign))
  exact_tail <- mean(if (observed > 0) same_sign >= observed-1e-12 else same_sign <= observed+1e-12)
  value <- simulation[simulation$term_id == term, ]
  stopifnot(abs(value$nes-exact_nes) < .09, abs(value$p_value-exact_tail) < .018)
}

mapping <- data.frame(source_id = c("A", "B", "C", "C", "D"),
  target_id = c("X", "X", "Y", "Z", "D"))
mapped <- bmp_pathway_map(c("A", "B", "C", "D", "UNMAPPED"), mapping)
stopifnot(setequal(unlist(mapped$mapped), c("X", "D")), length(mapped$metadata) > 0L)

# Explicit zero expansion must reach STRING as a request parameter. The graph
# response is mocked: no network service or patient identifiers are involved.
calls <- list()
transport <- function(endpoint, parameters) {
  calls[[length(calls)+1L]] <<- list(endpoint = endpoint, parameters = parameters)
  if (grepl("get_string_ids$", endpoint)) {
    return('[{"queryIndex":0,"queryItem":"A","stringId":"9606.A","preferredName":"A","ncbiTaxonId":9606},{"queryIndex":1,"queryItem":"B","stringId":"9606.B","preferredName":"B","ncbiTaxonId":9606}]')
  }
  stopifnot(grepl("network$", endpoint))
  '[{"stringId_A":"9606.A","stringId_B":"9606.B","preferredName_A":"A","preferredName_B":"B","score":0.9,"nscore":0.8}]'
}
network <- bmp_string_network(c("A", "B"), species = 9606L, add_nodes = 0L, score = 400L, transport = transport)
stopifnot(length(calls) >= 2L, grepl("version-", calls[[1]]$endpoint, fixed = TRUE))
network_call <- calls[vapply(calls, function(call) grepl("network$", call$endpoint), logical(1))][[1L]]
stopifnot(as.integer(network_call$parameters$add_nodes) == 0L,
  as.integer(network_call$parameters$species) == 9606L,
  as.integer(network_call$parameters$required_score) == 400L)
stopifnot(length(network$requests) > 0L, length(network$mapping) > 0L)

cat("Independent pathway oracles passed: combinatorial ORA, randomized weighted ES, deterministic GSEA, mapping and explicit STRING expansion.\n")
