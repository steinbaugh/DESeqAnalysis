#' Prepare `DESeqResults` data for plot
#'
#' @details
#' - `alpha`: P value or S value.
#' - `lfc`: log2 fold change cutoff.
#'
#' @section `isDeg`:
#'
#' Calculate an `integer factor`, used to define the color mappings:
#'
#' - `-1`: downregulated
#' -  `0`: not significant
#' -  `1`: upregulated
#'
#' @note Updated 2021-06-29.
#' @noRd
#'
#' @return `DataFrame`.
.prepareResultsForPlot <- function(
    object,
    direction,
    alphaThreshold,
    baseMeanThreshold,
    lfcThreshold
) {
    assert(is(object, "DESeqResults"))
    df <- as(object, "DataFrame")
    colnames(df) <- camelCase(colnames(df), strict = TRUE)
    alphaCol <- ifelse(
        test = isTRUE(isSubset("svalue", names(object))),
        yes = "svalue",
        no = "padj"
    )
    rankCol <- alphaCol
    assert(isSubset(
        x = c("baseMean", "log2FoldChange", alphaCol, rankCol),
        y = colnames(df)
    ))
    ## Remove genes with very low expression.
    keep <- which(df[["baseMean"]] >= baseMeanThreshold)
    df <- df[keep, , drop = FALSE]
    ## Apply directional filtering, if desired.
    switch(
        EXPR = direction,
        "up" = {
            keep <- which(df[["log2FoldChange"]] > 0L)
            df <- df[keep, , drop = FALSE]
        },
        "down" = {
            keep <- which(df[["log2FoldChange"]] < 0L)
            df <- df[keep, , drop = FALSE]
        }
    )
    ## Check for no genes passing cutoffs and early return.
    if (!hasRows(df)) {
        alertWarning("No genes passed cutoffs.")
        return(NULL)
    }
    df[["isDeg"]] <- as.factor(mapply(
        alpha = df[[alphaCol]],
        lfc = df[["log2FoldChange"]],
        baseMean = df[["baseMean"]],
        MoreArgs = list(
            "alphaThreshold" = alphaThreshold,
            "baseMeanThreshold" = baseMeanThreshold,
            "lfcThreshold" = lfcThreshold
        ),
        FUN = function(
            alpha,
            alphaThreshold,
            baseMean,
            baseMeanThreshold,
            lfc,
            lfcThreshold
        ) {
            if (
                any(is.na(c(alpha, lfc, baseMean))) ||
                alpha >= alphaThreshold ||
                baseMean < baseMeanThreshold
            ) {
                return(0L)
            }
            if (lfc >= lfcThreshold) {
                1L
            } else if (lfc <= -lfcThreshold) {
                -1L
            } else {
                0L
            }
        },
        SIMPLIFY = TRUE,
        USE.NAMES = FALSE
    ))
    df[["rankScore"]] <- df[[rankCol]]
    df[["rankScore"]][df[["isDeg"]] == 0L] <- NA
    df <- df[order(df[["rankScore"]]), , drop = FALSE]
    df[["rank"]] <- seq_len(nrow(df))
    df[["rank"]][df[["isDeg"]] == 0L] <- NA
    metadata(df) <- list(
        "alphaCol" = alphaCol,
        "alphaThreshold" = alphaThreshold,
        "baseMeanCol" = "baseMean",
        "baseMeanThreshold" = baseMeanThreshold,
        "direction" = direction,
        "isDegCol" = "isDeg",
        "lfcCol" = "log2FoldChange",
        "lfcShrinkType" = lfcShrinkType(object),
        "lfcThreshold" = lfcThreshold,
        "rankCol" = rankCol
    )
    df
}



#' Coerce a DESeqResults object to named list
#'
#' @note Updated 2019-07-23.
#' @noRd
#'
#' @details
#' Note that this will automatically assign name.
.coerceResultsToList <- function(from) {
    assert(is(from, "DESeqResults"))
    to <- list(from)
    names(to) <- makeNames(contrastName(from))
    to
}



#' Map contrast vector to coefficient
#'
#' @note Updated 2020-08-13.
#' @noRd
.contrast2coef <- function(contrast, resultsNames) {
    assert(
        isCharacter(contrast),
        hasLength(contrast, n = 3L),
        isCharacter(resultsNames)
    )
    factor <- contrast[[1L]]
    numerator <- contrast[[2L]]
    denominator <- contrast[[3L]]
    coef <- match(
        x = paste(factor, numerator, "vs", denominator, sep = "_"),
        table = resultsNames
    )
    assert(isInt(coef), !is.na(coef))
    dl(c(
        "contrast" = as.character(resultsNames[[coef]]),
        "coef" = as.character(coef)
    ))
    coef
}



## Updated 2020-08-04.
.ddsMsg <- function() {
    alertInfo(sprintf(
        "Generating DESeqDataSet with DESeq2 %s.",
        packageVersion("DESeq2")
    ))
}



## Updated 2019-11-12.
.joinCounts <- function(
    object,  # nolint
    DESeqDataSet   # nolint
) {
    assert(
        is(object, "DataFrame"),
        is(DESeqDataSet, "DESeqDataSet"),
        identical(
            x = rownames(object),
            y = rownames(DESeqDataSet)
        ),
        areDisjointSets(
            x = colnames(object),
            y = colnames(DESeqDataSet)
        )
    )
    validObject(object)
    validObject(DESeqDataSet)
    counts <- counts(DESeqDataSet, normalized = TRUE)
    out <- cbind(object, counts)
    ## Ensure we're not changing the object class on return.
    ## This can happen for DESeqResults, which will coerce to DataFrame.
    if (!identical(x = class(object), y = class(out))) {
        out <- as(out, Class = class(object)[[1L]])
    }
    validObject(out)
    out
}



## Join the row annotations.
##
## DESeq2 includes additional columns in `rowData()` that aren't informative for
## a user, and doesn't need to be included in the tables. Instead, only keep
## informative columns that are character or factor. Be sure to drop complex,
## non-atomic columns (e.g. list, S4) that are allowed in GRanges/DataFrame but
## will fail to write to disk as CSV. Note that we're using `decode()` here to
## handle S4 Rle columns from the Genomic Ranges.
##
## Updated 2019-11-12.
.joinRowData <- function(
    object,  # nolint
    DESeqDataSet   # nolint
) {
    assert(
        is(object, "DataFrame"),
        is(DESeqDataSet, "DESeqDataSet"),
        identical(
            x = rownames(object),
            y = rownames(DESeqDataSet)
        ),
        areDisjointSets(
            x = colnames(object),
            y = colnames(DESeqDataSet)
        )
    )
    validObject(object)
    validObject(DESeqDataSet)
    ## SummarizedExperiment inconsistently handles rownames on rowData.
    ## Ensure they are set here before continuing.
    rownames <- rownames(DESeqDataSet)
    rowData <- rowData(DESeqDataSet)
    rownames(rowData) <- rownames
    rowData <- decode(rowData)
    keep <- vapply(
        X = rowData,
        FUN = function(x) {
            is.character(x) || is.factor(x)
        },
        FUN.VALUE = logical(1L)
    )
    if (!any(keep)) {
        stop(
            "No suitable row annotations detected.\n",
            "Check 'rowData()' of DESeqDataSet."
        )
    }
    rowData <- rowData[, keep, drop = FALSE]
    ## Drop any remaining blacklisted columns. These columsn aren't useful in
    ## the downstream export to CSV format.
    blacklist <- "seqCoordSystem"
    keep <- !colnames(rowData) %in% blacklist
    rowData <- rowData[, keep, drop = FALSE]
    assert(
        all(vapply(
            X = rowData,
            FUN = is.atomic,
            FUN.VALUE = logical(1L)
        )),
        hasLength(rowData),
        identical(rownames(object), rownames(rowData)),
        areDisjointSets(colnames(object), colnames(rowData))
    )
    out <- cbind(object, rowData)
    ## Ensure we're not changing the object class on return.
    ## This can happen for DESeqResults, which will coerce to DataFrame.
    if (!identical(x = class(object), y = class(out))) {
        out <- as(out, Class = class(object)[[1L]])
    }
    validObject(out)
    out
}



#' Threshold label that goes in subtitle for plot on DESeqResults
#'
#' @note Updated 2021-06-29.
#' @noRd
.thresholdLabel <- function(
    object,
    direction,
    alphaThreshold,
    baseMeanThreshold,
    lfcShrinkType,
    lfcThreshold
) {
    assert(isAny(object, c("DESeqAnalysis", "DESeqResults")))
    x <- character()
    sep <- "; "
    if (is(object, "DESeqResults")) {
        n <- vapply(
            X = switch(
                EXPR = direction,
                "both" = c("up", "down"),
                direction
            ),
            FUN = function(direction) {
                length(deg(
                    object = object,
                    direction = direction,
                    alphaThreshold = alphaThreshold,
                    baseMeanThreshold = baseMeanThreshold,
                    lfcThreshold = lfcThreshold,
                    quiet = TRUE
                ))
            },
            FUN.VALUE = integer(1L),
            USE.NAMES = TRUE
        )
        x <- paste0(x, paste("n", "=", sum(n)))
        if (direction == "both" && sum(n) > 0L) {
            x <- paste0(x, sep, paste(names(n), n, sep = ": ", collapse = sep))
        } else {
            x <- paste0(x, " (", direction, ")")
        }
        x <- paste0(x, sep)
    }
    x <- paste0(x, "alpha < ", alphaThreshold)
    if (lfcThreshold > 0L) {
        x <- paste0(x, sep, "lfc >= ", lfcThreshold)
    }
    if (lfcShrinkType != "unshrunken") {
        x <- paste0(x, sep, "lfcShrink: ", lfcShrinkType)
    }
    if (baseMeanThreshold > 1L) {
        x <- paste0(x, sep, "baseMean >= ", baseMeanThreshold)
    }
    x
}



## Updated 2019-07-23.
.transformCountsAxisLabel <- function(object) {
    paste(transformType(object), "counts (log2)")
}



#' Determine which results slot to use
#'
#' @note Updated 2019-10-24.
#' @noRd
#'
#' @param object `DESeqAnalysis` or `DESeqAnalysisList`.
#' @param value `character(1)`.
#'   `DESeqResults` column name.
#'
#' @return `character(1)`.
#'   `DESeqResults` slot name. Either "results" or "lfcShrink"
#'
#' @examples
#' .whichResults(object, value = "log2FoldChange")
.whichResults <- function(object, value) {
    if (is(object, "DESeqAnalysisList")) {
        object <- object[[1L]]
    }
    assert(
        is(object, "DESeqAnalysis"),
        isCharacter(value)
    )
    if (
        identical(value, "log2FoldChange") &&
        hasLength(slot(object, "lfcShrink"))
    ) {
        slot <- "lfcShrink"
    } else {
        slot <- "results"
    }
    slot
}
