# Versioned screening stays entirely within the current fitting partition.
# Policy 2 caps a full-training prescreened pool before stability bootstrapping;
# bootstrap p adjustment still accounts for every eligible training gene.
bmp_with_seed <- function(seed, code) {
  existed <- exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)
  if (existed) old <- get(".Random.seed", envir = .GlobalEnv)
  on.exit(if (existed) assign(".Random.seed", old, envir = .GlobalEnv) else if (exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)) rm(".Random.seed", envir = .GlobalEnv))
  set.seed(as.integer(seed %% 2147483646))
  force(code)
}
bmp_seed <- function(seed, offset = 0) as.integer((as.double(seed) + as.double(offset) * 104729) %% 2147483646)
bmp_groups <- function(data, config) as.character(data[[if (is.null(config$group_column)) config$sample_id else config$group_column]])
bmp_numeric <- function(x, name) {
  if (is.numeric(x)) {
    if (any(!is.na(x) & !is.finite(x))) stop(sprintf("Predictor '%s' must be numeric according to the frozen training encoder.", name), call. = FALSE)
    return(as.numeric(x))
  }
  original <- as.character(x)
  value <- suppressWarnings(as.numeric(original))
  if (any(!is.na(original) & !is.finite(value))) stop(sprintf("Predictor '%s' must be numeric according to the frozen training encoder.", name), call. = FALSE)
  value
}
bmp_binary_screen_statistics <- function(data, config, genes) {
  # Matrix aggregation gives every patient equal weight, including repeated
  # observations and gene-specific missingness. Variance uses centered values
  # (not sum(x^2)-sum(x)^2/n, which is unstable for large offsets).
  x <- do.call(cbind, lapply(genes, function(gene) bmp_numeric(data[[gene]], gene)))
  groups <- bmp_groups(data, config)
  observed <- !is.na(x)
  constant <- vapply(seq_along(genes), function(j) length(unique(x[observed[, j], j])) < 2L, logical(1))
  x[!observed] <- 0
  counts <- rowsum(observed * 1, groups, reorder = TRUE)
  means <- rowsum(x, groups, reorder = TRUE)/counts
  means[counts == 0] <- NA_real_
  y <- as.character(data[[config$outcome]][match(rownames(means), groups)]) == config$positive_class
  moments <- function(z) {
    n <- colSums(!is.na(z)); mean <- colMeans(z, na.rm = TRUE)
    variance <- colSums(sweep(z, 2L, mean, "-")^2, na.rm = TRUE)/(n - 1)
    list(n = n, mean = mean, variance = variance)
  }
  a <- moments(means[y, , drop = FALSE]); b <- moments(means[!y, , drop = FALSE])
  vx <- a$variance/a$n; vy <- b$variance/b$n; se <- sqrt(vx + vy)
  df <- (vx + vy)^2/(vx^2/(a$n - 1) + vy^2/(b$n - 1))
  statistic <- (a$mean - b$mean)/se
  p <- suppressWarnings(2 * stats::pt(-abs(statistic), df))
  reason <- rep("", length(genes))
  reason[!is.finite(statistic) | !is.finite(p)] <- "Univariate statistic unavailable."
  near_constant <- is.finite(se) & se < 10 * .Machine$double.eps * pmax(abs(a$mean), abs(b$mean))
  reason[near_constant] <- "data are essentially constant"
  reason[b$n < 2] <- "not enough 'y' observations"
  reason[a$n < 2] <- "not enough 'x' observations"
  reason[colSums(observed) < 3 | constant] <- "Constant or insufficient observed training values."
  statistic[nzchar(reason)] <- p[nzchar(reason)] <- NA_real_
  # rowsum uses double accumulation. Rare large-offset/low-variance predictors
  # need R's compensated mean/variance path to match t.test (e.g. values near
  # 1e12 with unit variance and unequal numbers of samples per patient).
  unstable <- which(a$n >= 2 & b$n >= 2 & !constant &
    pmax(abs(a$mean), abs(b$mean)) > 1e6 * se)
  for (j in unstable) {
    value <- x[, j]; value[!observed[, j]] <- NA_real_
    reference <- tryCatch({
      grouped <- tapply(value, groups, function(v) if (all(is.na(v))) NA_real_ else mean(v, na.rm = TRUE))
      outcome <- as.character(data[[config$outcome]][match(names(grouped), groups)]) == config$positive_class
      fit <- stats::t.test(grouped[outcome], grouped[!outcome])
      if (!is.finite(fit$statistic) || !is.finite(fit$p.value)) stop("Univariate statistic unavailable.")
      list(statistic = unname(fit$statistic), p_value = fit$p.value, reason = "")
    }, error = function(error) list(statistic = NA_real_, p_value = NA_real_, reason = conditionMessage(error)))
    statistic[j] <- reference$statistic; p[j] <- reference$p_value; reason[j] <- reference$reason
  }
  data.frame(gene = genes, statistic = statistic, p_value = p, reason = reason, stringsAsFactors = FALSE)
}
bmp_screen_statistics <- function(data, config, genes, test_count = length(genes)) {
  if (!length(genes)) return(data.frame(gene = character(), statistic = numeric(), p_value = numeric(), adjusted_p = numeric(), reason = character()))
  if (length(test_count) != 1L || !is.finite(test_count) || test_count < length(genes)) stop("Invalid screening multiplicity count.", call. = FALSE)
  if (config$analysis_type == "binary") result <- bmp_binary_screen_statistics(data, config, genes)
  else {
    groups <- bmp_groups(data, config)
    values <- lapply(genes, function(gene) {
      x <- bmp_numeric(data[[gene]], gene)
      observed <- !is.na(x)
      result <- tryCatch({
        if (sum(observed) < 3 || length(unique(x[observed])) < 2) stop("Constant or insufficient observed training values.")
        fit <- suppressWarnings(survival::coxph(survival::Surv(data[[config$time_variable]], data[[config$event]]) ~ x, cluster = groups, ties = "breslow"))
        coefficients <- summary(fit)$coefficients
        statistic <- unname(coefficients[1, "z"]); p <- unname(coefficients[1, "Pr(>|z|)"])
        if (!is.finite(statistic) || !is.finite(p)) stop("Univariate statistic unavailable.")
        list(statistic = statistic, p_value = p, reason = "")
      }, error = function(e) list(statistic = NA_real_, p_value = NA_real_, reason = conditionMessage(e)))
      data.frame(gene = gene, statistic = result$statistic, p_value = result$p_value, reason = result$reason, stringsAsFactors = FALSE)
    })
    result <- do.call(rbind, values)
  }
  result$adjusted_p <- stats::p.adjust(result$p_value, method = config$p_adjust_method, n = test_count)
  result[order(result$adjusted_p, -abs(result$statistic), result$gene, na.last = TRUE), , drop = FALSE]
}
bmp_screen_pass <- function(statistics, config) {
  chosen <- statistics$gene[is.finite(statistics$adjusted_p) & statistics$adjusted_p <= config$p_threshold]
  if (!is.null(config$top_k)) chosen <- head(chosen, config$top_k)
  chosen
}
bmp_bootstrap_rows <- function(data, config, seed) {
  groups <- bmp_groups(data, config)
  unique_groups <- unique(groups)
  stratum <- if (config$analysis_type == "binary") vapply(unique_groups, function(g) as.character(data[[config$outcome]][match(g, groups)]), character(1)) else vapply(unique_groups, function(g) as.character(any(data[[config$event]][groups == g] == 1)), character(1))
  sampled <- bmp_with_seed(seed, unlist(lapply(split(unique_groups, stratum), function(values) values[sample.int(length(values), length(values), replace = TRUE)]), use.names = FALSE))
  unlist(lapply(sampled, function(g) which(groups == g)), use.names = FALSE)
}
bmp_bootstrap_training <- function(data, config, seed) {
  groups <- bmp_groups(data, config); unique_groups <- unique(groups)
  strata <- if (config$analysis_type == "binary") vapply(unique_groups, function(g) as.character(data[[config$outcome]][match(g, groups)]), character(1)) else vapply(unique_groups, function(g) as.character(any(data[[config$event]][groups == g] == 1)), character(1))
  sampled <- bmp_with_seed(seed, unlist(lapply(split(unique_groups, strata), function(values) values[sample.int(length(values), length(values), replace = TRUE)]), use.names = FALSE))
  pieces <- lapply(seq_along(sampled), function(i) {
    result <- data[groups == sampled[i], , drop = FALSE]
    # Duplicated bootstrap draws represent separate resampled patient clusters.
    result[[if (is.null(config$group_column)) config$sample_id else config$group_column]] <- sprintf("bootstrap_%06d", i)
    result
  })
  do.call(rbind, pieces)
}
bmp_fit_recipe <- function(data, config, feature_set = "genes", seed = config$seed, gene_recipe = NULL) {
  genes <- if (feature_set == "clinical") character() else config$gene_columns
  clinical <- if (feature_set == "genes") character() else config$clinical_columns
  if (is.null(genes)) stop("Validate data before fitting: gene_columns is missing.", call. = FALSE)
  specs <- list(); dropped <- list(); distribution <- list(); design <- list(); index <- 0L
  if (!is.null(gene_recipe)) {
    if (feature_set != "combined" || gene_recipe$feature_set != "genes") stop("Shared gene recipe requires a matching combined fitting partition.", call. = FALSE)
    specs <- gene_recipe$predictors; dropped <- gene_recipe$dropped
    distribution <- gene_recipe$distribution; design <- gene_recipe$design; index <- length(design)
  }
  for (name in unique(c(if (is.null(gene_recipe)) genes else character(), clinical))) {
    raw <- as.character(data[[name]])
    missing <- is.na(raw)
    # Infer only on this partition. Global QC clinical_types is deliberately ignored.
    parsed <- suppressWarnings(as.numeric(raw))
    numeric <- name %in% genes || (any(!missing) && all(missing | is.finite(parsed)))
    if (numeric) {
      x <- bmp_numeric(data[[name]], name)
      distribution[[name]] <- list(type = "numeric", missing_fraction = mean(missing), n = sum(!missing), mean = if (all(missing)) NULL else mean(x, na.rm = TRUE), sd = if (sum(!missing) < 2) NULL else stats::sd(x, na.rm = TRUE), quantiles = I(if (all(missing)) rep(NA_real_, 5) else as.numeric(stats::quantile(x, c(0,.25,.5,.75,1), na.rm = TRUE))))
    } else distribution[[name]] <- list(type = "categorical", missing_fraction = mean(missing), counts = as.list(table(raw, useNA = "no")))
    reason <- if (mean(missing) > config$missing_threshold) "missingness" else if (length(unique(raw[!missing])) < 2L) "constant_or_all_missing" else NULL
    if (!is.null(reason)) {
      if (name %in% config$include) stop(sprintf("Forced gene '%s' fails training-partition %s QC; remove it from include or revise the declared policy.", name, reason), call. = FALSE)
      dropped[[name]] <- reason
      next
    }
    if (numeric) {
      median <- stats::median(x, na.rm = TRUE); x[missing] <- median
      center <- mean(x); scale <- stats::sd(x)
      if (!is.finite(scale) || scale <= 0) stop("Invalid training scale.", call. = FALSE)
      index <- index + 1L; column <- sprintf("x%05d", index)
      specs[[name]] <- list(name = name, type = "numeric", role = if (name %in% genes) "gene" else "clinical", median = median, center = center, scale = scale, columns = I(column))
      design[[length(design) + 1L]] <- list(column = column, predictor = name, role = specs[[name]]$role, level = NULL)
    } else {
      levels <- sort(unique(raw[!missing])); counts <- table(factor(raw, levels = levels)); mode <- levels[which.max(counts)]
      columns <- sprintf("x%05d", index + seq_len(length(levels) - 1L)); index <- index + length(columns)
      specs[[name]] <- list(name = name, type = "categorical", role = "clinical", mode = mode, levels = I(levels), reference = levels[1], columns = I(columns))
      for (j in seq_along(columns)) design[[length(design) + 1L]] <- list(column = columns[j], predictor = name, role = "clinical", level = levels[j + 1L])
    }
  }
  eligible <- intersect(genes, names(specs))
  forced <- intersect(config$include, genes)
  if (length(forced) > config$max_candidates_per_step) stop("Forced genes exceed max_candidates_per_step.", call. = FALSE)
  if (is.null(gene_recipe)) {
    statistics <- bmp_screen_statistics(data, config, eligible)
    full_pass <- bmp_screen_pass(statistics, config)
    pool <- unique(c(forced, head(setdiff(full_pass, forced), max(0L, config$max_candidates_per_step - length(forced)))))
    frequency <- stats::setNames(rep(NA_real_, length(eligible)), eligible)
    frequency[pool] <- 0
    if (length(pool)) {
      # Never copy thousands of unused columns into every patient bootstrap.
      columns <- intersect(unique(c(pool, config$sample_id, config$group_column, config$outcome, config$event, config$time_variable)), names(data))
      screening_data <- data[, columns, drop = FALSE]
      for (b in seq_len(20L)) {
        sampled <- bmp_bootstrap_training(screening_data, config, bmp_seed(seed, b))
        passed <- bmp_screen_pass(bmp_screen_statistics(sampled, config, pool, test_count = length(eligible)), config)
        frequency[passed] <- frequency[passed] + 1/20
      }
    }
    statistics$bootstrap_evaluated <- statistics$gene %in% pool
    statistics$selection_frequency <- unname(frequency[statistics$gene])
    stable <- names(frequency)[is.finite(frequency) & frequency + 1e-12 >= config$selection_frequency]
    selected <- unique(c(forced, intersect(full_pass, stable)))
    policy <- list(version = 2L, bootstrap_resamples = 20L, sampling_unit = "patient_group",
      statistic = if (config$analysis_type == "binary") "Welch t on patient-mean predictors" else "Cluster-robust univariate Cox Wald z",
      pool_rule = "Full fitting-partition QC and adjusted-p/top_k prescreen, then forced genes plus ranked candidates up to max_candidates; bootstrap only this fixed pool",
      bootstrap_multiplicity = "p.adjust n equals all QC-eligible genes in this fitting partition; untested genes are conservatively accounted for by p.adjust",
      bootstrap_frequency_interpretation = "Conditional on the full-training prescreened pool; untested genes have unavailable frequency, not zero",
      eligible_test_count = length(eligible), bootstrap_pool_count = length(pool), bootstrap_pool_sha256 = bmp_hash_object(pool),
      p_threshold = config$p_threshold, p_adjust_method = config$p_adjust_method, top_k = config$top_k,
      selection_frequency = config$selection_frequency, max_candidates = config$max_candidates_per_step)
    audit <- list(screening_sha256 = bmp_hash_object(statistics), eligible_genes_sha256 = bmp_hash_object(eligible),
      measured_gene_count = length(genes), eligible_gene_count = length(eligible), screened_gene_count = nrow(statistics),
      candidate_count = length(selected), bootstrap_pool = I(pool), candidate_genes = I(selected))
  } else {
    statistics <- gene_recipe$screening; selected <- as.character(unlist(gene_recipe$selected_genes))
    policy <- gene_recipe$screening_policy; audit <- gene_recipe$screening_audit
  }
  warnings <- if (length(genes) && !length(selected)) "No gene passed training-only prescreen and stability; fitting a null or clinical-only baseline." else character()
  list(recipe_version = 1L, feature_set = feature_set, predictors = specs, design = design, selected_genes = I(selected), clinical_columns = I(as.character(intersect(clinical, names(specs)))), forced_genes = I(forced), dropped = dropped, screening = statistics, distribution = distribution, screening_policy = policy, screening_audit = audit, warnings = warnings)
}
bmp_fit_recipes <- function(data, config, seed) {
  # This cache lives only for one explicit training partition and seed. It is
  # never reused across inner/outer folds or an external evaluation cohort.
  gene <- if (any(config$feature_sets %in% c("genes", "combined"))) tryCatch(bmp_fit_recipe(data, config, "genes", seed), error = identity) else NULL
  stats::setNames(lapply(config$feature_sets, function(feature_set) {
    if (feature_set == "genes") return(gene)
    if (feature_set == "combined" && inherits(gene, "error")) return(gene)
    tryCatch(bmp_fit_recipe(data, config, feature_set, seed, if (feature_set == "combined") gene else NULL), error = identity)
  }), config$feature_sets)
}
bmp_recipe_audit <- function(recipes) {
  available <- Filter(function(recipe) !inherits(recipe, "error"), recipes)
  gene <- Filter(function(recipe) recipe$feature_set != "clinical", available)
  first <- if (length(gene)) gene[[1L]] else if (length(available)) available[[1L]] else NULL
  list(schema_version = 1L, screening_policy = first$screening_policy, audit = first$screening_audit,
    screening = first$screening, dropped = first$dropped,
    feature_sets = lapply(available, function(recipe) list(selected_genes = recipe$selected_genes, clinical_columns = recipe$clinical_columns, dropped = recipe$dropped)))
}
bmp_apply_recipe <- function(recipe, data, features = NULL) {
  if (anyDuplicated(names(data))) stop("Prediction columns must be unique.", call. = FALSE)
  if (is.null(features)) features <- unique(c(unlist(recipe$selected_genes), unlist(recipe$clinical_columns)))
  absent <- setdiff(features, names(data))
  if (length(absent)) stop(paste("Prediction predictors not found:", paste(absent, collapse = ", ")), call. = FALSE)
  values <- list()
  for (name in features) {
    spec <- recipe$predictors[[name]]
    if (is.null(spec)) stop(paste("Predictor absent from frozen recipe:", name), call. = FALSE)
    columns <- as.character(unlist(spec$columns, use.names = FALSE))
    if (spec$type == "numeric") {
      x <- bmp_numeric(data[[name]], name); x[is.na(x)] <- spec$median
      values[[columns]] <- (x - spec$center)/spec$scale
    } else {
      x <- as.character(data[[name]]); x[is.na(x)] <- spec$mode
      levels <- as.character(unlist(spec$levels, use.names = FALSE))
      unknown <- setdiff(unique(x), levels)
      if (length(unknown)) stop(sprintf("Unseen category in '%s': %s. The frozen model uses an error-on-unknown policy.", name, paste(unknown, collapse = ", ")), call. = FALSE)
      for (j in seq_along(columns)) values[[columns[j]]] <- as.numeric(x == levels[j + 1L])
    }
  }
  if (!length(values)) return(matrix(numeric(), nrow = nrow(data), ncol = 0L, dimnames = list(NULL, character())))
  result <- do.call(cbind, values); storage.mode(result) <- "double"
  result
}
