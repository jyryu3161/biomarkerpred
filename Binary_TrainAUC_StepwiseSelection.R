library(caret)
library(ROCR)
library(ggplot2)
library(pROC)
library(tiff)
library(reshape2)
# Try to load svglite, but don't fail if not available
if (!requireNamespace("svglite", quietly = TRUE)) {
  cat("STEPWISE_LOG:svglite not available, will use base svg instead\n", file = stderr())
}

# Font setup: prefer Arial, fall back to sans if not available
PLOT_FONT <- tryCatch({
  # Check if Arial is available on this system
  fonts <- systemfonts::system_fonts()
  if (any(grepl("Arial", fonts$family, ignore.case = TRUE))) {
    "Arial"
  } else if (any(grepl("Helvetica", fonts$family, ignore.case = TRUE))) {
    "Helvetica"
  } else {
    "sans"
  }
}, error = function(e) {
  # systemfonts not available, use safe default
  if (.Platform$OS.type == "unix" && !grepl("darwin", R.version$os)) {
    "sans"  # Linux (Docker) - Arial may not exist
  } else {
    "Arial"  # macOS/Windows
  }
})

# Helper function for Nature-style theme
nature_theme <- function(base_size = 10, base_family = PLOT_FONT) {
  theme_classic(base_size = base_size, base_family = base_family) +
    theme(
      plot.title = element_text(size = base_size + 2, face = "bold", hjust = 0.5, 
                                margin = margin(b = 8)),
      axis.title = element_text(size = base_size + 1, face = "bold", color = "black"),
      axis.text = element_text(size = base_size, color = "black"),
      axis.line = element_line(color = "black", linewidth = 0.5),
      axis.ticks = element_line(color = "black", linewidth = 0.5),
      legend.title = element_text(size = base_size, face = "bold", color = "black"),
      legend.text = element_text(size = base_size, color = "black"),
      legend.position = "right",
      legend.key = element_blank(),
      legend.background = element_blank(),
      panel.background = element_rect(fill = "white", color = NA),
      plot.background = element_rect(fill = "white", color = NA),
      strip.background = element_blank(),
      strip.text = element_text(size = base_size, face = "bold")
    )
}

# Nature color palette
nature_colors <- list(
  blue = "#1f77b4",
  red = "#d62728",
  green = "#2ca02c",
  orange = "#ff7f0e",
  purple = "#9467bd",
  brown = "#8c564b",
  pink = "#e377c2",
  gray = "#7f7f7f",
  yellow = "#bcbd22",
  cyan = "#17becf"
)

# Helper: extract variable names from Result[1,1] formula string safely
extract_vars <- function(result_str) {
  # Split by + and trim whitespace
  vars <- trimws(unlist(strsplit(as.character(result_str), "\\+")))
  vars <- vars[nzchar(vars)]
  return(vars)
}

# Helper: build formula string with backticks for special characters (hyphens, etc.)
safe_formula_str <- function(vars) {
  # Backtick variable names that contain non-alphanumeric/underscore/dot characters
  safe <- sapply(vars, function(v) {
    if (grepl("[^a-zA-Z0-9_.]", v)) paste0("`", v, "`") else v
  })
  paste(safe, collapse = " + ")
}

# Helper function to save plots in multiple formats (TIFF 300 DPI and SVG)
save_plot <- function(plot_obj, filename_base, width_inch = 7, height_inch = 5, is_ggplot = TRUE) {
  # Create figures directory if it doesn't exist
  if (!dir.exists("figures")) {
    dir.create("figures", recursive = TRUE)
  }
  
  filename_base <- file.path("figures", filename_base)
  
  if (is_ggplot) {
    # Save as TIFF 300 DPI
    tryCatch({
      tiff(filename = paste0(filename_base, ".tiff"),
           width = width_inch * 300, height = height_inch * 300,
           units = "px", res = 300, compression = "lzw")
      print(plot_obj)
      dev.off()
    }, error = function(e) {
      try(dev.off(), silent = TRUE)
      cat(paste("STEPWISE_LOG:Warning - Failed to save TIFF:", e$message, "\n"), file = stderr())
    })

    # Save as SVG (try svglite first, fallback to base svg)
    tryCatch({
      if (requireNamespace("svglite", quietly = TRUE)) {
        svglite::svglite(file = paste0(filename_base, ".svg"),
                        width = width_inch, height = height_inch)
      } else {
        svg(filename = paste0(filename_base, ".svg"),
            width = width_inch, height = height_inch)
      }
      print(plot_obj)
      dev.off()
    }, error = function(e) {
      try(dev.off(), silent = TRUE)
      cat(paste("STEPWISE_LOG:Warning - Failed to save SVG:", e$message, "\n"), file = stderr())
    })
  } else {
    # For base R plots
    # Save as TIFF 300 DPI
    tryCatch({
      tiff(filename = paste0(filename_base, ".tiff"),
           width = width_inch * 300, height = height_inch * 300,
           units = "px", res = 300, compression = "lzw")
      print(plot_obj)
      dev.off()
    }, error = function(e) {
      try(dev.off(), silent = TRUE)
      cat(paste("STEPWISE_LOG:Warning - Failed to save TIFF:", e$message, "\n"), file = stderr())
    })

    # Save as SVG (try svglite first, fallback to base svg)
    tryCatch({
      if (requireNamespace("svglite", quietly = TRUE)) {
        svglite::svglite(file = paste0(filename_base, ".svg"),
                        width = width_inch, height = height_inch)
      } else {
        svg(filename = paste0(filename_base, ".svg"),
            width = width_inch, height = height_inch)
      }
      print(plot_obj)
      dev.off()
    }, error = function(e) {
      try(dev.off(), silent = TRUE)
      cat(paste("STEPWISE_LOG:Warning - Failed to save SVG:", e$message, "\n"), file = stderr())
    })
  }
}

Extract_BinCandidGene <- function(dat,numSeed,SplitProp,totvar,outcandir,Freq,top_k=NULL,p_adjust_method="fdr",p_threshold=0.05){
  total_vars <- length(totvar)
  cat(paste("STEPWISE_LOG:Processing", total_vars, "variables across", numSeed, "iterations\n"), file = stderr())
  cat(paste("STEPWISE_LOG:P-value adjustment method:", p_adjust_method, ", threshold:", p_threshold, "\n"), file = stderr())
  if (!is.null(top_k)) {
    cat(paste("STEPWISE_LOG:Top-k selection enabled: selecting top", top_k, "genes per iteration\n"), file = stderr())
  }

  for (s in seq(numSeed)){
    if (s %% 10 == 0 || s == 1) {
      cat(paste("STEPWISE_LOG:Iteration", s, "of", numSeed, "(", round(s/numSeed*100, 1), "%)\n"), file = stderr())
    }
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Outcome, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]

      n_tr_0 <- sum(trdat$Outcome == 0)
      n_tr_1 <- sum(trdat$Outcome == 1)

      if (min(n_tr_0, n_tr_1) >= 2) break
    }
    tmpres <- NULL
    var_count <- 0
    for (j in match(totvar,colnames(dat))){
      var_name <- colnames(trdat)[j]
      var_count <- var_count + 1

      # Print progress every 50 variables
      if (var_count %% 50 == 0) {
        cat(paste("STEPWISE_LOG:Iteration", s, "- Processing variable", var_count, "of", total_vars, "\n"), file = stderr())
      }

      # Skip if variable has NA or constant values
      if (length(unique(trdat[,var_name])) <= 1 || any(is.na(trdat[,var_name]))){
        next
      }
      tryCatch({
        f=as.formula(paste('Outcome ~ ',var_name,collapse = ''))
        Logitres<-glm(f, data = trdat, family = "binomial")
        coef_summary <- summary(Logitres)$coef
        # Check if coefficient exists (row 2 exists and has at least 4 columns)
        if (nrow(coef_summary) >= 2 && ncol(coef_summary) >= 4){
          tmpres <- rbind(tmpres,c(var_name,coef_summary[2,c(1:2,4)]))
        }
      }, error = function(e) {
        # Skip this variable if model fitting fails
        # Suppress warnings to avoid cluttering output
      })
    }
    if(s==1){
      dir.create(outcandir)
    }
    if (!is.null(tmpres) && nrow(tmpres) > 0) {
      # Apply p-value adjustment and filtering
      tmpres_df <- data.frame(tmpres, stringsAsFactors = FALSE)
      colnames(tmpres_df) <- c("X", "Estimate", "Std..Error", "Pr...z..")
      tmpres_df$Pr...z.. <- as.numeric(tmpres_df$Pr...z..)

      # Apply p-value adjustment
      tmpres_df$Adjusted_P <- p.adjust(tmpres_df$Pr...z.., method = p_adjust_method)

      # Filter by adjusted p-value threshold
      tmpres_df <- tmpres_df[!is.na(tmpres_df$Adjusted_P) & tmpres_df$Adjusted_P < p_threshold, ]

      # If top_k is specified, select top k genes by adjusted p-value
      if (!is.null(top_k) && nrow(tmpres_df) > top_k) {
        tmpres_df <- tmpres_df[order(tmpres_df$Adjusted_P), ]
        tmpres_df <- tmpres_df[1:top_k, ]
        cat(paste("STEPWISE_LOG:Iteration", s, "- Selected top", top_k, "genes from", nrow(tmpres_df), "significant genes\n"), file = stderr())
      }

      write.csv(tmpres_df,paste0(outcandir,'/Logistic_seed',s,'.csv'),row.names = F)
      cat(paste("STEPWISE_LOG:Iteration", s, "completed -", nrow(tmpres_df), "significant variables (adjusted p <", p_threshold, ")\n"), file = stderr())
    } else {
      cat(paste("STEPWISE_LOG:Iteration", s, "completed - No valid variables found\n"), file = stderr())
    }
  }
  cat(paste("STEPWISE_LOG:Analyzing significance across iterations...\n"), file = stderr())
  
  # Robust aggregation of significant genes across all iterations
  all_genes <- c()
  gene_lists <- list()
  valid_seeds <- c()
  
  for (s in seq(numSeed)){
    csv_file <- paste0(outcandir,'/Logistic_seed',s,'.csv')
    if (!file.exists(csv_file)) {
      warning(paste("CSV file not found for seed", s, "- skipping"))
      next
    }
    res <- read.csv(csv_file,header = T,stringsAsFactors = F)
    if (nrow(res) == 0) {
      warning(paste("Empty CSV file for seed", s, "- skipping"))
      next
    }
    
    gene_lists[[length(gene_lists) + 1]] <- res$X
    valid_seeds <- c(valid_seeds, s)
    all_genes <- unique(c(all_genes, res$X))
  }

  if (length(all_genes) == 0) {
    stop("No valid variables found in any iteration. Please check your data.")
  }
  
  # Count frequencies
  gene_freqs <- sapply(all_genes, function(g) {
    sum(sapply(gene_lists, function(l) g %in% l))
  })
  
  SignifGene2 <- data.frame(Gene = all_genes, Freq = gene_freqs)
  write.csv(SignifGene2,paste0(outcandir,'/Logistic_UnivariateResults.csv'),row.names = F)
  Candivar<-SignifGene2$Gene[which(SignifGene2$Freq>Freq)]
  cat(paste("STEPWISE_LOG:Candidate extraction complete -", length(Candivar), "genes selected (Freq >", Freq, ")\n"), file = stderr())
  return(Candivar)
}


# Pre-screening function to quickly evaluate candidates and select top N
Binprescreen_candidates <- function(dat, candid, fixvar, prescreen_seeds, SplitProp, max_candidates){
  cat(paste("STEPWISE_LOG:Pre-screening", length(candid), "candidates with", prescreen_seeds, "seeds...\n"), file = stderr())
  prescreen_scores <- NULL
  
  for (s in seq(prescreen_seeds)){
    if (s %% 5 == 0 || s == 1) {
      cat(paste("STEPWISE_LOG:Pre-screening - Iteration", s, "of", prescreen_seeds, "\n"), file = stderr())
    }
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Outcome, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]
      tsdat <- dat[-trIdx, ]
      
      n_tr_0 <- sum(trdat$Outcome == 0)
      n_tr_1 <- sum(trdat$Outcome == 1)
      n_ts_0 <- sum(tsdat$Outcome == 0)
      n_ts_1 <- sum(tsdat$Outcome == 1)
      
      if (min(n_tr_0, n_tr_1, n_ts_0, n_ts_1) >= 2) break
    }
    
    for (g in setdiff(candid, fixvar)){
      tryCatch({
        f=as.formula(paste('Outcome ~ ',paste(fixvar,collapse = ' + '),' + ',g,collapse = ''))
        trdat1 <- trdat[complete.cases(trdat[,c('Outcome',setdiff(c(fixvar,g),''))]),c('Outcome',setdiff(c(fixvar,g),''))]
        tsdat1 <- tsdat[complete.cases(tsdat[,c('Outcome',setdiff(c(fixvar,g),''))]),c('Outcome',setdiff(c(fixvar,g),''))]
        
        if (nrow(trdat1) < 2 || nrow(tsdat1) < 2) {
          next
        }
        
        Logitres<-glm(f, data = trdat1, family = "binomial")
        lptr <- predict(Logitres,trdat1, type="response")
        trauc <- performance(prediction(lptr,trdat1[,'Outcome']),"auc")@y.values[[1]][1]
        lpts <- predict(Logitres,tsdat1, type="response")
        tsauc <- performance(prediction(lpts,tsdat1[,'Outcome']),"auc")@y.values[[1]][1]
        
        trauc <- ifelse(is.na(trauc), 0, as.numeric(trauc))
        tsauc <- ifelse(is.na(tsauc), 0, as.numeric(tsauc))
        
        # Use average of train and test AUC as score
        score <- (trauc + tsauc) / 2
        prescreen_scores <- rbind(prescreen_scores, c(g, score, trauc, tsauc))
      }, error = function(e) {
        # Skip this candidate if model fitting fails
      })
    }
  }
  
  if (is.null(prescreen_scores) || nrow(prescreen_scores) == 0) {
    cat("STEPWISE_LOG:Pre-screening failed - using all candidates\n", file = stderr())
    return(candid)
  }
  
  # Aggregate scores across seeds
  prescreen_df <- data.frame(prescreen_scores, stringsAsFactors = FALSE)
  colnames(prescreen_df) <- c("candidate", "score", "trauc", "tsauc")
  prescreen_df$score <- as.numeric(prescreen_df$score)
  prescreen_df$trauc <- as.numeric(prescreen_df$trauc)
  prescreen_df$tsauc <- as.numeric(prescreen_df$tsauc)
  
  # Calculate mean score for each candidate
  candidate_scores <- aggregate(score ~ candidate, data = prescreen_df, FUN = mean)
  candidate_scores <- candidate_scores[order(candidate_scores$score, decreasing = TRUE), ]
  
  # Select top N candidates
  n_select <- min(max_candidates, nrow(candidate_scores))
  selected_candidates <- candidate_scores$candidate[1:n_select]
  
  cat(paste("STEPWISE_LOG:Pre-screening complete - Selected top", length(selected_candidates), "candidates\n"), file = stderr())
  return(selected_candidates)
}

Binforward_step <- function(dat, candid, fixvar, numSeed, SplitProp, max_candidates_per_step = NULL, prescreen_seeds = NULL){
  # Apply pre-screening if candidates exceed threshold
  if (!is.null(max_candidates_per_step) && !is.null(prescreen_seeds) && length(candid) > max_candidates_per_step) {
    candid <- Binprescreen_candidates(dat, candid, fixvar, prescreen_seeds, SplitProp, max_candidates_per_step)
  }
  
  forward_ls <- NULL
  for (s in seq(numSeed)){
    if (s %% 20 == 0 || s == 1) {
      cat(paste("STEPWISE_LOG:Forward step - Iteration", s, "of", numSeed, "\n"), file = stderr())
    }
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Outcome, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]
      tsdat <- dat[-trIdx, ]
      
      n_tr_0 <- sum(trdat$Outcome == 0)
      n_tr_1 <- sum(trdat$Outcome == 1)
      n_ts_0 <- sum(tsdat$Outcome == 0)
      n_ts_1 <- sum(tsdat$Outcome == 1)
      
      if (min(n_tr_0, n_tr_1, n_ts_0, n_ts_1) >= 2) break
    }
    for (g in setdiff(candid,fixvar)){
      f=as.formula(paste('Outcome ~ ',paste(fixvar,collapse = ' + '),' + ',g,collapse = ''))
      trdat1 <- trdat[complete.cases(trdat[,c('Outcome',setdiff(c(fixvar,g),''))]),c('Outcome',setdiff(c(fixvar,g),''))]
      tsdat1 <- tsdat[complete.cases(tsdat[,c('Outcome',setdiff(c(fixvar,g),''))]),c('Outcome',setdiff(c(fixvar,g),''))]
      Logitres<-glm(f, data = trdat1, family = "binomial")
      
      lptr <- predict(Logitres,trdat1, type="response")
      trauc <- performance(prediction(lptr,trdat1[,'Outcome']),"auc")@y.values[[1]][1]
      lpts <- predict(Logitres,tsdat1, type="response")
      tsauc <- performance(prediction(lpts,tsdat1[,'Outcome']),"auc")@y.values[[1]][1]
      # Convert to numeric and handle NA
      trauc <- ifelse(is.na(trauc), 0, as.numeric(trauc))
      tsauc <- ifelse(is.na(tsauc), 0, as.numeric(tsauc))
      forward_ls <- rbind(forward_ls,c(s,paste(c(fixvar,g),collapse = ' + '),trauc,tsauc))
    }
  }
  forward_ls1 <- data.frame(forward_ls)
  forward_ls1$X3 <- as.numeric(forward_ls1$X3)
  forward_ls1$X4 <- as.numeric(forward_ls1$X4)
  AUCsumm <- NULL
  for (g in unique(forward_ls1$X2)){
    AUCsumm <- rbind(AUCsumm,c(g,colMeans(forward_ls1[which(forward_ls1$X2==g),-c(1,2)],na.rm = T)))
  }
  return(AUCsumm)
}

Binbackward_step <- function(dat, backcandid, fixvar, numSeed, SplitProp){
  backward_ls <- NULL
  for (s in seq(numSeed)){
    if (s %% 20 == 0 || s == 1) {
      cat(paste("STEPWISE_LOG:Backward step - Iteration", s, "of", numSeed, "\n"), file = stderr())
    }
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Outcome, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]
      tsdat <- dat[-trIdx, ]
      
      n_tr_0 <- sum(trdat$Outcome == 0)
      n_tr_1 <- sum(trdat$Outcome == 1)
      n_ts_0 <- sum(tsdat$Outcome == 0)
      n_ts_1 <- sum(tsdat$Outcome == 1)
      
      if (min(n_tr_0, n_tr_1, n_ts_0, n_ts_1) >= 2) break
    }
    for (g in backcandid){
      f=as.formula(paste('Outcome ~ ',paste(setdiff(fixvar,g),collapse = ' + '),collapse = ''))
      trdat1 <- trdat[complete.cases(trdat[,c('Outcome',setdiff(fixvar,g))]),]
      tsdat1 <- tsdat[complete.cases(tsdat[,c('Outcome',setdiff(fixvar,g))]),]
      Logitres<-glm(f, data = trdat1, family = "binomial")
      lptr <- predict(Logitres,trdat1, type="response")
      trauc <- performance(prediction(lptr,trdat1[,'Outcome']),"auc")@y.values[[1]][1]
      lpts <- predict(Logitres,tsdat1)
      tsauc <- performance(prediction(lpts,tsdat1[,'Outcome']),"auc")@y.values[[1]][1]
      # Convert to numeric and handle NA
      trauc <- ifelse(is.na(trauc), 0, as.numeric(trauc))
      tsauc <- ifelse(is.na(tsauc), 0, as.numeric(tsauc))
      backward_ls <- rbind(backward_ls,c(s,paste(setdiff(fixvar,g),collapse = ' + '),trauc,tsauc))
    }
  }
  backward_ls1 <- data.frame(backward_ls)
  backward_ls1$X3 <- as.numeric(backward_ls1$X3)
  backward_ls1$X4 <- as.numeric(backward_ls1$X4)
  AUCsumm <- NULL
  for (g in unique(backward_ls1$X2)){
    AUCsumm <- rbind(AUCsumm,c(g,colMeans(backward_ls1[which(backward_ls1$X2==g),-c(1,2)],na.rm = T)))
  }
  return(AUCsumm)
}

BinTrainAUCStepwise <- function(totvar,dat,fixvar,excvar,numSeed,SplitProp,outdir,max_candidates_per_step = NULL,prescreen_seeds = NULL){
  if (is.null(totvar) || length(totvar) == 0) {
    cat("STEPWISE_LOG:No candidate variables provided for stepwise selection.\n", file = stderr())
    return(NULL)
  }
  imtres <- NULL
  step_count <- 0
  cat(paste("STEPWISE_LOG:Starting stepwise selection with", length(totvar), "candidate variables\n"), file = stderr())
  
  while (length(setdiff(fixvar,excvar))<length(totvar)){
    step_count <- step_count + 1
    candid <- setdiff(totvar,c(fixvar,excvar))
    
    cat(paste("STEPWISE_LOG:Step", step_count, "- Forward selection with", length(candid), "candidates,", length(fixvar), "currently selected\n"), file = stderr())
    
    ##### Forward step
    forward_ls <- Binforward_step(dat, candid, fixvar, numSeed, SplitProp, max_candidates_per_step, prescreen_seeds)
    forward.trauc1<-max(as.numeric(forward_ls[,2]), na.rm = TRUE)
    forward.idx <- which.max(as.numeric(forward_ls[,2]))
    forward.var1 <- forward_ls[forward.idx,1]
    forward.tsauc1 <- as.numeric(forward_ls[forward.idx,3])
    # Handle NA values
    if (is.na(forward.tsauc1)) {
      forward.tsauc1 <- 0
    }
    forward.newstep <-matrix(c(forward.var1,forward.trauc1,forward.tsauc1),nrow=1)
    if (length(setdiff(gsub(" ","",strsplit(forward.var1,"\\+")[[1]]),""))==1){
      dir.create(outdir)
      imtres <- rbind(imtres, forward.newstep)
      colnames(forward.newstep)<-c('Variable','trainAUC','testAUC')
      write.csv(forward.newstep, file.path(outdir, paste0("Intermediate_Forward", nrow(imtres), ".csv")), row.names = FALSE)
      fixvar <- gsub(" ","",strsplit(forward.var1,'\\+')[[1]][2])
      forward.old <- forward.newstep
      cat(paste("STEPWISE_LOG:Added first variable - TrainAUC:", round(forward.trauc1, 4), ", TestAUC:", round(forward.tsauc1, 4), "\n"), file = stderr())
    } else{
      forward.old <- imtres[nrow(imtres),]
      if (as.numeric(forward.newstep[2]) > (as.numeric(forward.old[2]) + 0.005)){
        colnames(forward.newstep) <- colnames(imtres)
        imtres <- rbind(imtres, forward.newstep)
        colnames(forward.newstep)<-c('Variable','trainAUC','testAUC')
        write.csv(forward.newstep, file.path(outdir, paste0("Intermediate_Forward", nrow(imtres), ".csv")), row.names = FALSE)
        fixvar <- append(fixvar,gsub(' ','',strsplit(forward.var1,'\\+')[[1]])[length(gsub(' ','',strsplit(forward.var1,'\\+')[[1]]))])
        forward.old <- forward.newstep
        cat(paste("STEPWISE_LOG:Added variable - TrainAUC:", round(forward.trauc1, 4), ", TestAUC:", round(forward.tsauc1, 4), ", Total vars:", length(fixvar), "\n"), file = stderr())
        
        if (nrow(imtres)>2){
          
          ##### Backward step
          cat(paste("STEPWISE_LOG:Backward step - Testing removal of", length(fixvar)-2, "variables\n"), file = stderr())
          backcandid<-fixvar[c(1:(length(fixvar)-2))]
          backward_ls<-Binbackward_step(dat, backcandid, fixvar, numSeed, SplitProp)
          backward.trauc1<-max(as.numeric(backward_ls[,2]), na.rm = TRUE)
          backward.idx <- which.max(as.numeric(backward_ls[,2]))
          backward.var1 <- backward_ls[backward.idx,1]
          backward.tsauc1 <- as.numeric(backward_ls[backward.idx,3])
          # Handle NA values
          if (is.na(backward.tsauc1)) {
            backward.tsauc1 <- 0
          }
          backward.newstep <-matrix(c(backward.var1,backward.trauc1,backward.tsauc1),nrow=1)
          if (backward.trauc1 > (as.numeric(forward.old[2]) + 0.005)){
            imtres <- rbind(imtres, backward.newstep)
            colnames(backward.newstep)<-c('Variable','trainAUC','testAUC')
            write.csv(backward.newstep, file.path(outdir, paste0("Intermediate_Backward", nrow(imtres), ".csv")), row.names = FALSE)
            fixvar <- gsub(' ','',strsplit(backward_ls[which.max(as.numeric(backward_ls[,2])),1],'\\+')[[1]])
            forward.old <- backward.trauc1
            cat(paste("STEPWISE_LOG:Removed variable - TrainAUC:", round(backward.trauc1, 4), ", TestAUC:", round(backward.tsauc1, 4), ", Total vars:", length(fixvar), "\n"), file = stderr())
          }
        }
      } else{
        cat(paste("STEPWISE_LOG:No improvement - stopping stepwise selection\n"), file = stderr())
        mat<-matrix(imtres[nrow(imtres),],nrow=1)
        colnames(mat)<-c('Variable','trainAUC','testAUC')
        colnames(imtres)<-c('Variable','trainAUC','testAUC')
        write.csv(imtres, file.path(outdir, "Intermediate_Stepwise_Total.csv"), row.names = FALSE)
        write.csv(mat, file.path(outdir, "Final_Stepwise_Total.csv"), row.names = FALSE)
        break
      }
    }
  }
  mat<-matrix(imtres[nrow(imtres),],nrow=1)
  colnames(mat)<-c('Variable','trainAUC','testAUC')
  colnames(imtres)<-c('Variable','trainAUC','testAUC')
  write.csv(imtres, file.path(outdir, "Intermediate_Stepwise_Total.csv"), row.names = FALSE)
  write.csv(mat, file.path(outdir, "Final_Stepwise_Total.csv"), row.names = FALSE)
  final_vars <- strsplit(as.character(mat[1,1]), " \\+ ")[[1]]
  final_train_auc <- as.numeric(mat[1,2])
  final_test_auc <- as.numeric(mat[1,3])
  cat(paste("STEPWISE_LOG:Stepwise selection complete - Final model has", length(final_vars), "variables\n"), file = stderr())
  cat(paste("STEPWISE_LOG:Final TrainAUC:", round(final_train_auc, 4), ", TestAUC:", round(final_test_auc, 4), "\n"), file = stderr())
  return (mat)
}

PlotBinROC <- function(dat,numSeed,SplitProp,Result){
  FinalRes <- NULL
  trROCobjList <- tsROCobjList <- NULL
  valid_iterations <- 0
  
  for (s in seq(numSeed)){
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Outcome, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]
      tsdat <- dat[-trIdx, ]
      
      n_tr_0 <- sum(trdat$Outcome == 0)
      n_tr_1 <- sum(trdat$Outcome == 1)
      n_ts_0 <- sum(tsdat$Outcome == 0)
      n_ts_1 <- sum(tsdat$Outcome == 1)
      
      if (min(n_tr_0, n_tr_1, n_ts_0, n_ts_1) >= 2) break
    }
    
    tryCatch({
      f=as.formula(paste0('Outcome ~ ', safe_formula_str(extract_vars(Result[1,1]))))
      trdat1 <- trdat[complete.cases(trdat[,c('Outcome',extract_vars(Result[1,1]))]),c('Outcome',extract_vars(Result[1,1]))]
      tsdat1 <- tsdat[complete.cases(tsdat[,c('Outcome',extract_vars(Result[1,1]))]),c('Outcome',extract_vars(Result[1,1]))]
      
      if (nrow(trdat1) < 2 || nrow(tsdat1) < 2) {
        next
      }
      
      model<-glm(f, data = trdat1, family = "binomial")
      lptr <- predict(model,trdat1,type="response")
      
      # Check if prediction is valid
      if (any(is.na(lptr)) || length(unique(lptr)) < 2) {
        next
      }
      
      trROCobj <- performance(prediction(lptr,trdat1$Outcome),"tpr", "fpr")
      trauc <- performance(prediction(lptr,trdat1$Outcome),"auc")@y.values[[1]][1]
      trauc <- ifelse(is.na(trauc), 0, as.numeric(trauc))
      
      lpts <- predict(model,tsdat1,type="response")
      
      # Check if prediction is valid
      if (any(is.na(lpts)) || length(unique(lpts)) < 2) {
        next
      }
      
      tsROCobj <- performance(prediction(lpts,tsdat1$Outcome),"tpr", "fpr")
      tsauc <- performance(prediction(lpts,tsdat1$Outcome),"auc")@y.values[[1]][1]
      tsauc <- ifelse(is.na(tsauc), 0, as.numeric(tsauc))
      
      valid_iterations <- valid_iterations + 1
      trROCobjList[[valid_iterations]] <- trROCobj
      tsROCobjList[[valid_iterations]] <- tsROCobj
      FinalRes <- rbind(FinalRes,c(s,trauc,tsauc))
    }, error = function(e) {
      # Skip this iteration if there's an error
      warning(paste("Skipping iteration", s, "due to error:", e$message))
    })
  }
  
  if (valid_iterations == 0) {
    stop("No valid iterations for ROC plotting")
  }
  
  # Helper to interpolate ROC curves onto a common grid
  roc_grid <- seq(0, 1, length.out = 101)
  interpolate_roc <- function(roc_list) {
    res <- lapply(roc_list, function(obj) {
      fpr <- as.numeric(obj@x.values[[1]])
      tpr <- as.numeric(obj@y.values[[1]])
      if (length(fpr) < 2 || length(tpr) < 2) {
        return(rep(NA_real_, length(roc_grid)))
      }
      ord <- order(fpr, tpr)
      fpr <- fpr[ord]
      tpr <- tpr[ord]
      dup <- !duplicated(fpr)
      fpr <- fpr[dup]
      tpr <- tpr[dup]
      if (length(fpr) < 2) {
        return(rep(NA_real_, length(roc_grid)))
      }
      approx(x = fpr, y = tpr, xout = roc_grid, yleft = 0, yright = 1)$y
    })
    do.call(cbind, res)
  }
  
  trTPR_interp <- interpolate_roc(trROCobjList)
  tsTPR_interp <- interpolate_roc(tsROCobjList)
  
  MeantrTPR <- rowMeans(trTPR_interp, na.rm = TRUE)
  MeantsTPR <- rowMeans(tsTPR_interp, na.rm = TRUE)
  
  # Create ROC plot function
  plot_roc_func <- function() {
    oldpar <- par(no.readonly = TRUE)
    on.exit(par(oldpar))
    par(mfrow = c(1, 2), family = PLOT_FONT, bg = "white", mar = c(4.5, 4.5, 3, 1))
    diag_col <- adjustcolor("gray60", alpha.f = 0.6)
    iter_col <- adjustcolor("gray75", alpha.f = 0.8)
    
    # Training ROC
    if (valid_iterations > 0) {
      plot(0, 0, type = 'n', xlim = c(0, 1), ylim = c(0, 1),
           xlab = '1-Specificity', ylab = 'Sensitivity',
           main = '[ROC curve] Training set', cex.main = 1.2, cex.lab = 1.1, font.lab = 2)
      abline(0, 1, lty = 3, col = diag_col)
      if (!all(is.na(trTPR_interp))) {
        apply(trTPR_interp, 2, function(col_vals) {
          if (all(is.na(col_vals))) return(NULL)
          lines(roc_grid, col_vals, col = iter_col, lwd = 0.8, lty = 2)
        })
      }
      if (!all(is.na(MeantrTPR))) {
        lines(roc_grid, MeantrTPR, col = nature_colors$blue, lwd = 1)
      }
      FinalRes_df <- data.frame(FinalRes)
      FinalRes_df[,2] <- as.numeric(FinalRes_df[,2])
      FinalRes_df[,3] <- as.numeric(FinalRes_df[,3])
      legend('bottomright', legend = paste0('Mean AUC:\n',
                                            round(mean(FinalRes_df[,2], na.rm = TRUE), 3),
                                            ' ± ',
                                            round(sd(FinalRes_df[,2], na.rm = TRUE), 3)),
             lwd = 1, cex = 1, col = nature_colors$blue, box.lwd = 0.8)
    }
    
    # Test ROC
    if (valid_iterations > 0) {
      plot(0, 0, type = 'n', xlim = c(0, 1), ylim = c(0, 1),
           xlab = '1-Specificity', ylab = 'Sensitivity',
           main = '[ROC curve] Test set', cex.main = 1.2, cex.lab = 1.1, font.lab = 2)
      abline(0, 1, lty = 3, col = diag_col)
      if (!all(is.na(tsTPR_interp))) {
        apply(tsTPR_interp, 2, function(col_vals) {
          if (all(is.na(col_vals))) return(NULL)
          lines(roc_grid, col_vals, col = iter_col, lwd = 0.8, lty = 2)
        })
      }
      if (!all(is.na(MeantsTPR))) {
        lines(roc_grid, MeantsTPR, col = nature_colors$red, lwd = 1)
      }
      FinalRes_df <- data.frame(FinalRes)
      FinalRes_df[,2] <- as.numeric(FinalRes_df[,2])
      FinalRes_df[,3] <- as.numeric(FinalRes_df[,3])
      legend('bottomright', legend = paste0('Mean AUC:\n',
                                            round(mean(FinalRes_df[,3], na.rm = TRUE), 3),
                                            ' ± ',
                                            round(sd(FinalRes_df[,3], na.rm = TRUE), 3)),
             lwd = 1, cex = 1, col = nature_colors$red, box.lwd = 0.8)
    }
  }
  
  # Save as TIFF
  if (!dir.exists("figures")) dir.create("figures", recursive = TRUE)
  tryCatch({
    tiff(filename = 'figures/Binary_ROCcurve.tiff', width = 7*300, height = 3.5*300, units = "px", res = 300, compression = "lzw")
    plot_roc_func()
    dev.off()
  }, error = function(e) {
    try(dev.off(), silent = TRUE)
    cat(paste("STEPWISE_LOG:Warning - Failed to save ROC TIFF:", e$message, "\n"), file = stderr())
  })

  # Save as SVG
  tryCatch({
    if (requireNamespace("svglite", quietly = TRUE)) {
      svglite::svglite(file = 'figures/Binary_ROCcurve.svg', width = 7, height = 3.5)
    } else {
      svg(filename = 'figures/Binary_ROCcurve.svg', width = 7, height = 3.5)
    }
    plot_roc_func()
    dev.off()
  }, error = function(e) {
    try(dev.off(), silent = TRUE)
    cat(paste("STEPWISE_LOG:Warning - Failed to save ROC SVG:", e$message, "\n"), file = stderr())
  })
}

PlotBinVarImp <- function(dat,Result){
  Scaledat <- data.frame(Outcome=dat[,c('Outcome')],apply(dat[,match(extract_vars(Result[1,1]),colnames(dat))],2,function(v) scale(v)))
  
  mod<-glm(as.formula(paste0('Outcome ~ ', safe_formula_str(extract_vars(Result[1,1])))),data = Scaledat, family = "binomial")
  ce=function(model.obj){
    extract=summary(get(model.obj))$coefficients[-1,c(1,2)]
    return(data.frame(extract,vars=row.names(extract),model=model.obj))
  }
  coefs = ce('mod')
  names(coefs)[1:2]=c('coef','se')
  
  p <- ggplot(coefs, aes(x = vars, y = coef, color = vars)) +
    geom_hline(yintercept = 0, linetype = "dashed", color = "gray50", linewidth = 0.8) +
    geom_errorbar(aes(ymin = coef - se, ymax = coef + se), linewidth = 1, width = 0, color = "black") +
    geom_point(size = 3, color = nature_colors$blue) +
    geom_text(aes(label = sprintf("%.2f", coef)), hjust = 0.4, vjust = -1, size = 3, fontface = "bold", color = "black") +
    coord_flip() +
    guides(color = "none") +
    labs(x = "Predictors", y = "Standardized Coefficient", title = "Variable Importance") +
    nature_theme(base_size = 10)
  
  save_plot(p, 'Binary_Variable_Importance', width_inch = 7, height_inch = 5)
}

# Calibration Plot
PlotBinCalibration <- function(dat, numSeed, SplitProp, Result) {
  cat("STEPWISE_LOG:Calibration plot generation skipped\n", file = stderr())
  invisible(NULL)
}

# Decision Curve Analysis
PlotBinDCA <- function(dat, numSeed, SplitProp, Result) {
  library(pROC)
  all_pred <- NULL
  all_outcome <- NULL
  
  for (s in seq(numSeed)) {
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Outcome, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]
      tsdat <- dat[-trIdx, ]
      
      n_tr_0 <- sum(trdat$Outcome == 0)
      n_tr_1 <- sum(trdat$Outcome == 1)
      n_ts_0 <- sum(tsdat$Outcome == 0)
      n_ts_1 <- sum(tsdat$Outcome == 1)
      
      if (min(n_tr_0, n_tr_1, n_ts_0, n_ts_1) >= 2) break
    }
    
    tryCatch({
      f <- as.formula(paste0('Outcome ~ ', safe_formula_str(extract_vars(Result[1,1]))))
      tsdat1 <- tsdat[complete.cases(tsdat[,c('Outcome',extract_vars(Result[1,1]))]),c('Outcome',extract_vars(Result[1,1]))]
      
      if (nrow(tsdat1) < 2) next
      
      model <- glm(f, data = trdat[complete.cases(trdat[,c('Outcome',extract_vars(Result[1,1]))]),c('Outcome',extract_vars(Result[1,1]))], family = "binomial")
      lpts <- predict(model, tsdat1, type="response")
      
      if (any(is.na(lpts)) || length(unique(lpts)) < 2) next
      
      all_pred <- c(all_pred, lpts)
      all_outcome <- c(all_outcome, tsdat1$Outcome)
    }, error = function(e) {})
  }
  
  if (is.null(all_pred)) return(NULL)
  
  # Calculate DCA manually
  threshold_seq <- seq(0.01, 0.99, by = 0.01)
  net_benefit <- numeric(length(threshold_seq))
  treat_all <- numeric(length(threshold_seq))
  treat_none <- numeric(length(threshold_seq))
  
  prevalence <- mean(all_outcome)
  
  for (i in seq_along(threshold_seq)) {
    threshold <- threshold_seq[i]
    treat <- as.numeric(all_pred >= threshold)
    
    tp <- sum(treat == 1 & all_outcome == 1)
    fp <- sum(treat == 1 & all_outcome == 0)
    n <- length(all_outcome)
    
    net_benefit[i] <- (tp / n) - (fp / n) * (threshold / (1 - threshold))
    treat_all[i] <- prevalence - (1 - prevalence) * (threshold / (1 - threshold))
    treat_none[i] <- 0
  }
  
  dca_data <- data.frame(
    threshold = threshold_seq,
    model = net_benefit,
    treat_all = treat_all,
    treat_none = treat_none
  )
  
  dca_long <- reshape2::melt(dca_data, id.vars = "threshold", variable.name = "strategy", value.name = "net_benefit")
  
  p <- ggplot(dca_long, aes(x = threshold, y = net_benefit, color = strategy)) +
    geom_line(linewidth = 1) +
    labs(x = "Threshold Probability", y = "Net Benefit", 
         title = "Decision Curve Analysis", color = "Strategy") +
    xlim(0, 1) +
    scale_color_manual(values = c("model" = nature_colors$blue, 
                                   "treat_all" = nature_colors$green,
                                   "treat_none" = nature_colors$gray),
                       labels = c("Model", "Treat All", "Treat None")) +
    nature_theme(base_size = 10)
  
  save_plot(p, 'Binary_DCA', width_inch = 7, height_inch = 5)
}

# AUC Boxplot
PlotBinAUCBoxplot <- function(dat, numSeed, SplitProp, Result) {
  FinalRes <- NULL
  
  for (s in seq(numSeed)) {
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Outcome, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]
      tsdat <- dat[-trIdx, ]
      
      n_tr_0 <- sum(trdat$Outcome == 0)
      n_tr_1 <- sum(trdat$Outcome == 1)
      n_ts_0 <- sum(tsdat$Outcome == 0)
      n_ts_1 <- sum(tsdat$Outcome == 1)
      
      if (min(n_tr_0, n_tr_1, n_ts_0, n_ts_1) >= 2) break
    }
    
    tryCatch({
      f <- as.formula(paste0('Outcome ~ ', safe_formula_str(extract_vars(Result[1,1]))))
      trdat1 <- trdat[complete.cases(trdat[,c('Outcome',extract_vars(Result[1,1]))]),c('Outcome',extract_vars(Result[1,1]))]
      tsdat1 <- tsdat[complete.cases(tsdat[,c('Outcome',extract_vars(Result[1,1]))]),c('Outcome',extract_vars(Result[1,1]))]
      
      if (nrow(trdat1) < 2 || nrow(tsdat1) < 2) next
      
      model <- glm(f, data = trdat1, family = "binomial")
      lptr <- predict(model, trdat1, type="response")
      lpts <- predict(model, tsdat1, type="response")
      
      if (any(is.na(lptr)) || length(unique(lptr)) < 2) next
      if (any(is.na(lpts)) || length(unique(lpts)) < 2) next
      
      trauc <- performance(prediction(lptr, trdat1$Outcome),"auc")@y.values[[1]][1]
      tsauc <- performance(prediction(lpts, tsdat1$Outcome),"auc")@y.values[[1]][1]
      
      trauc <- ifelse(is.na(trauc), 0, as.numeric(trauc))
      tsauc <- ifelse(is.na(tsauc), 0, as.numeric(tsauc))
      
      FinalRes <- rbind(FinalRes, c(trauc, tsauc))
    }, error = function(e) {})
  }
  
  if (is.null(FinalRes) || nrow(FinalRes) == 0) return(NULL)
  
  auc_data <- data.frame(
    AUC = c(FinalRes[,1], FinalRes[,2]),
    Dataset = rep(c("Training", "Test"), each = nrow(FinalRes))
  )
  
  p <- ggplot(auc_data, aes(x = Dataset, y = AUC, fill = Dataset)) +
    geom_boxplot(alpha = 0.7, outlier.size = 1.5, linewidth = 0.8) +
    geom_jitter(width = 0.2, alpha = 0.5, size = 1.2) +
    labs(x = "Dataset", y = "AUC", title = "AUC Distribution Across Iterations") +
    ylim(0, 1) +
    scale_fill_manual(values = c("Training" = nature_colors$blue, "Test" = nature_colors$red)) +
    nature_theme(base_size = 10) +
    theme(legend.position = "none")
  
  save_plot(p, 'Binary_AUC_Boxplot', width_inch = 5, height_inch = 5)
}

# Prediction Probability Distribution
PlotBinProbDist <- function(dat, numSeed, SplitProp, Result) {
  cat("STEPWISE_LOG:Probability distribution plot generation skipped\n", file = stderr())
  invisible(NULL)
}

# Confusion Matrix
PlotBinConfusionMatrix <- function(dat, numSeed, SplitProp, Result) {
  library(pheatmap)
  library(pROC)
  
  all_pred <- NULL
  all_outcome <- NULL
  
  for (s in seq(numSeed)) {
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Outcome, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]
      tsdat <- dat[-trIdx, ]
      
      n_tr_0 <- sum(trdat$Outcome == 0)
      n_tr_1 <- sum(trdat$Outcome == 1)
      n_ts_0 <- sum(tsdat$Outcome == 0)
      n_ts_1 <- sum(tsdat$Outcome == 1)
      
      if (min(n_tr_0, n_tr_1, n_ts_0, n_ts_1) >= 2) break
    }
    
    tryCatch({
      f <- as.formula(paste0('Outcome ~ ', safe_formula_str(extract_vars(Result[1,1]))))
      tsdat1 <- tsdat[complete.cases(tsdat[,c('Outcome',extract_vars(Result[1,1]))]),c('Outcome',extract_vars(Result[1,1]))]
      
      if (nrow(tsdat1) < 2) next
      
      model <- glm(f, data = trdat[complete.cases(trdat[,c('Outcome',extract_vars(Result[1,1]))]),c('Outcome',extract_vars(Result[1,1]))], family = "binomial")
      lpts <- predict(model, tsdat1, type="response")
      
      if (any(is.na(lpts)) || length(unique(lpts)) < 2) next
      
      all_pred <- c(all_pred, lpts)
      all_outcome <- c(all_outcome, tsdat1$Outcome)
    }, error = function(e) {})
  }
  
  if (is.null(all_pred)) return(NULL)
  
  # Find optimal threshold using Youden's index
  roc_obj <- pROC::roc(all_outcome, all_pred, quiet = TRUE)
  optimal_threshold <- pROC::coords(roc_obj, "best", ret = "threshold", transpose = FALSE)$threshold
  
  # Create confusion matrix
  pred_class <- ifelse(all_pred >= optimal_threshold, 1, 0)
  cm <- table(Actual = all_outcome, Predicted = pred_class)
  
  # Calculate percentages
  cm_percent <- prop.table(cm) * 100
  
  # Create annotation data
  annotation_text <- paste0(format(cm, scientific = FALSE), "\n(", 
                            sprintf("%.1f", cm_percent), "%)")
  
  # Create heatmap data
  cm_df <- as.data.frame(cm)
  cm_matrix <- matrix(cm, nrow = 2, ncol = 2, 
                      dimnames = list(Actual = c("Negative", "Positive"),
                                     Predicted = c("Negative", "Positive")))
  
  # Create confusion matrix plot using ggplot2 (more reliable than pheatmap for saving)
  cm_long <- data.frame(
    Actual = rep(c("Non-responder", "Responder"), each = 2),
    Predicted = rep(c("Non-responder", "Responder"), 2),
    Count = as.vector(cm_matrix),
    Percent = as.vector(prop.table(cm_matrix) * 100)
  )
  cm_long$Actual <- factor(cm_long$Actual, levels = c("Responder", "Non-responder"))
  cm_long$Predicted <- factor(cm_long$Predicted, levels = c("Non-responder", "Responder"))
  cm_long$Label <- paste0(cm_long$Count, "\n(", sprintf("%.1f%%", cm_long$Percent), ")")

  p <- ggplot(cm_long, aes(x = Predicted, y = Actual, fill = Count)) +
    geom_tile(color = "white", linewidth = 2) +
    geom_text(aes(label = Label), size = 5, fontface = "bold", color = "black") +
    scale_fill_gradient(low = "white", high = nature_colors$blue, guide = "none") +
    labs(x = "Predicted", y = "Actual",
         title = paste0("Confusion Matrix (Threshold = ", round(optimal_threshold, 3), ")")) +
    nature_theme(base_size = 11) +
    theme(axis.text = element_text(size = 11, face = "bold"),
          panel.grid = element_blank(),
          axis.line = element_blank())

  save_plot(p, 'Binary_Confusion_Matrix', width_inch = 5, height_inch = 5)
}

# Stepwise Selection Process Visualization
PlotBinStepwiseProcess <- function(outdir) {
  # Read intermediate stepwise results
  stepwise_file <- paste0(outdir, '/Intermediate_Stepwise_Total.csv')
  if (!file.exists(stepwise_file)) return(NULL)
  
  stepwise_data <- read.csv(stepwise_file, stringsAsFactors = FALSE)
  
  # Extract step number and variable count
  stepwise_data$step <- seq_len(nrow(stepwise_data))
  stepwise_data$n_vars <- sapply(strsplit(stepwise_data$Variable, " \\+ "), length)
  stepwise_data$trainAUC <- as.numeric(stepwise_data$trainAUC)
  stepwise_data$testAUC <- as.numeric(stepwise_data$testAUC)
  
  # Reshape for plotting
  auc_long <- reshape2::melt(stepwise_data[, c("step", "trainAUC", "testAUC")], 
                              id.vars = "step", variable.name = "type", value.name = "AUC")
  
  p <- ggplot(auc_long, aes(x = step, y = AUC, color = type, group = type)) +
    geom_line(linewidth = 1) +
    geom_point(size = 2.5, alpha = 0.8) +
    geom_text(aes(label = sprintf("%.3f", AUC)), vjust = -0.5, size = 2.8, fontface = "bold") +
    labs(x = "Step", y = "AUC", title = "Stepwise Selection Process", color = "Dataset") +
    scale_color_manual(values = c("trainAUC" = nature_colors$blue, "testAUC" = nature_colors$red),
                       labels = c("Training", "Test")) +
    nature_theme(base_size = 10)
  
  save_plot(p, 'Binary_Stepwise_Process', width_inch = 7, height_inch = 5)
}

# Waterfall Plot - Per-patient prediction scores
PlotBinWaterfall <- function(dat, numSeed, SplitProp, Result) {
  library(pROC)

  f <- as.formula(paste0('Outcome ~ ', safe_formula_str(extract_vars(Result[1,1]))))
  vars <- extract_vars(Result[1,1])
  model_data <- dat[complete.cases(dat[, c('Outcome', vars)]), c('Outcome', vars)]

  if (nrow(model_data) < 4) return(NULL)

  model <- glm(f, data = model_data, family = "binomial")
  pred_prob <- predict(model, model_data, type = "response")

  roc_obj <- pROC::roc(model_data$Outcome, pred_prob, quiet = TRUE)
  optimal_threshold <- pROC::coords(roc_obj, "best", ret = "threshold", transpose = FALSE)$threshold

  wf_data <- data.frame(
    probability = pred_prob,
    response = factor(model_data$Outcome, levels = c(0, 1),
                      labels = c("Non-responder", "Responder"))
  )
  wf_data <- wf_data[order(wf_data$probability), ]
  wf_data$rank <- seq_len(nrow(wf_data))

  p <- ggplot(wf_data, aes(x = rank, y = probability, fill = response)) +
    geom_bar(stat = "identity", width = 0.8) +
    geom_hline(yintercept = optimal_threshold, linetype = "dashed",
               color = "black", linewidth = 0.8) +
    annotate("text", x = nrow(wf_data) * 0.95, y = optimal_threshold + 0.03,
             label = paste0("Threshold = ", round(optimal_threshold, 3)),
             hjust = 1, size = 3.5, fontface = "bold") +
    scale_fill_manual(values = c("Non-responder" = nature_colors$red,
                                  "Responder" = nature_colors$blue)) +
    labs(x = "Patients (ranked by prediction score)",
         y = "Prediction Probability",
         title = "Drug Response Prediction Waterfall Plot",
         fill = "Response") +
    ylim(0, 1) +
    nature_theme(base_size = 10) +
    theme(axis.text.x = element_blank(), axis.ticks.x = element_blank())

  save_plot(p, 'Binary_Waterfall', width_inch = 8, height_inch = 5)
}

# Volcano Plot - Differential expression between responders and non-responders
PlotBinVolcano <- function(dat, totvar) {
  results <- data.frame(gene = character(), log2FC = numeric(),
                        pvalue = numeric(), stringsAsFactors = FALSE)

  for (var in totvar) {
    vals <- dat[, var]
    if (length(unique(vals)) <= 1 || any(is.na(vals))) next
    tryCatch({
      mean_resp <- mean(dat[dat$Outcome == 1, var], na.rm = TRUE)
      mean_nonresp <- mean(dat[dat$Outcome == 0, var], na.rm = TRUE)
      log2fc <- log2((mean_resp + 1) / (mean_nonresp + 1))

      wt <- wilcox.test(dat[dat$Outcome == 1, var],
                        dat[dat$Outcome == 0, var])

      results <- rbind(results, data.frame(
        gene = var, log2FC = log2fc, pvalue = wt$p.value,
        stringsAsFactors = FALSE
      ))
    }, error = function(e) {})
  }

  if (nrow(results) == 0) return(NULL)

  results$padj <- p.adjust(results$pvalue, method = "fdr")
  results$neg_log10p <- -log10(pmax(results$padj, 1e-300))

  fc_threshold <- 0.5
  p_thresh <- 0.05
  results$significance <- "Not significant"
  results$significance[results$padj < p_thresh & results$log2FC > fc_threshold] <- "Up in Responder"
  results$significance[results$padj < p_thresh & results$log2FC < -fc_threshold] <- "Down in Responder"

  top_genes <- results[order(results$padj), ]
  top_genes <- head(top_genes[top_genes$significance != "Not significant", ], 10)
  results$label <- ifelse(results$gene %in% top_genes$gene, results$gene, "")

  p <- ggplot(results, aes(x = log2FC, y = neg_log10p, color = significance)) +
    geom_point(alpha = 0.6, size = 1.5) +
    geom_hline(yintercept = -log10(p_thresh), linetype = "dashed", color = "gray50") +
    geom_vline(xintercept = c(-fc_threshold, fc_threshold), linetype = "dashed", color = "gray50") +
    geom_text(aes(label = label), size = 3, vjust = -0.5, hjust = 0.5,
              fontface = "bold", color = "black", check_overlap = TRUE) +
    scale_color_manual(values = c(
      "Up in Responder" = nature_colors$red,
      "Down in Responder" = nature_colors$blue,
      "Not significant" = "gray70"
    )) +
    labs(x = expression(log[2]~"Fold Change (Responder / Non-responder)"),
         y = expression(-log[10]~"(adjusted p-value)"),
         title = "Differential Expression: Responder vs Non-responder",
         color = "Category") +
    nature_theme(base_size = 10)

  save_plot(p, 'Binary_Volcano', width_inch = 8, height_inch = 6)
}

# Biomarker Heatmap - Expression patterns of selected genes
PlotBinHeatmap <- function(dat, Result) {
  library(pheatmap)

  vars <- extract_vars(Result[1,1])
  if (length(vars) < 2) return(NULL)

  expr_data <- dat[, vars, drop = FALSE]
  expr_scaled <- apply(expr_data, 2, function(x) {
    s <- sd(x, na.rm = TRUE)
    if (s == 0) return(rep(0, length(x)))
    (x - mean(x, na.rm = TRUE)) / s
  })
  rownames(expr_scaled) <- seq_len(nrow(expr_scaled))

  annotation_row <- data.frame(
    Response = factor(dat$Outcome, levels = c(0, 1),
                      labels = c("Non-responder", "Responder"))
  )
  rownames(annotation_row) <- rownames(expr_scaled)

  ord <- order(dat$Outcome)
  expr_sorted <- expr_scaled[ord, , drop = FALSE]
  annotation_sorted <- data.frame(Response = annotation_row$Response[ord])
  rownames(annotation_sorted) <- rownames(expr_sorted)

  annotation_colors <- list(
    Response = c("Non-responder" = nature_colors$red,
                 "Responder" = nature_colors$blue)
  )

  hm <- pheatmap(t(expr_sorted),
                  annotation_col = annotation_sorted,
                  annotation_colors = annotation_colors,
                  cluster_rows = TRUE,
                  cluster_cols = FALSE,
                  show_colnames = FALSE,
                  color = colorRampPalette(c(nature_colors$blue, "white", nature_colors$red))(100),
                  main = "Biomarker Expression Heatmap",
                  fontsize = 9,
                  fontsize_row = 8,
                  fontfamily = PLOT_FONT,
                  border_color = NA,
                  silent = TRUE)

  if (!dir.exists("figures")) dir.create("figures", recursive = TRUE)

  tryCatch({
    tiff(filename = 'figures/Binary_Heatmap.tiff',
         width = 8 * 300, height = 6 * 300, units = "px", res = 300, compression = "lzw")
    print(hm)
    dev.off()
  }, error = function(e) {
    try(dev.off(), silent = TRUE)
    cat(paste("STEPWISE_LOG:Warning - Failed to save Heatmap TIFF:", e$message, "\n"), file = stderr())
  })

  tryCatch({
    if (requireNamespace("svglite", quietly = TRUE)) {
      svglite::svglite(file = 'figures/Binary_Heatmap.svg', width = 8, height = 6)
    } else {
      svg(filename = 'figures/Binary_Heatmap.svg', width = 8, height = 6)
    }
    print(hm)
    dev.off()
  }, error = function(e) {
    try(dev.off(), silent = TRUE)
    cat(paste("STEPWISE_LOG:Warning - Failed to save Heatmap SVG:", e$message, "\n"), file = stderr())
  })
}