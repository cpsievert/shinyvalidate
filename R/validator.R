# The overall implementation of InputValidator is extremely simple right now, at
# the expense of performance. My assumption is that validation rule functions
# will run extremely quickly and not have meaningful side effects. We have an
# opportunity to optimize so that validation rules only execute when 1) they are
# added, 2) the input value changes, 3) a reactive read that's performed during
# the validation invalidates, or 4) a prior rule around the input that was
# formerly failing now passes.
#
# The way to accomplish this would be to create a reactive expression for each
# rule, plus a reactiveValues object to track the rules for each input. Each
# input would also get a reactive expression for the overall validity of that
# input. It would look something like:
#
#   reactive({
#     for (rule in rv_rules[[id]]) {
#       result <- rule()  # rule is a reactive that has a read to input[[id]]
#       if (!is.null(result)) {
#         return(result)
#       }
#     }
#     return(NULL)
#   })
#
# Then sv$validate() would just be collecting all of these.

#' Shiny validation object
#'
#' @description An R6 class for adding realtime input validation to Shiny apps.
#'
#'   `InputValidator` objects are designed to be created as local variables in
#'   Shiny server functions and Shiny module server functions. The Shiny app
#'   author can register zero, one, or multiple validation rules for each input
#'   field in their UI, using the `InputValidator$add_rule()` method.
#'
#'   Once an `InputValidator` object is created and populated with rules, it can
#'   be used in a few ways:
#'
#'   1. The `InputValidator$enable()` method can be called to display real-time
#'      feedback to users about what inputs are failing validation, and why.
#'   2. The `InputValidator$is_valid()` method returns `TRUE` if and only if all
#'      of the validation rules are passing; this can be checked before
#'      executing actions that depend on the inputs being valid.
#'   3. The `InputValidator$validate()` method is a lower-level feature that
#'      directly returns information about what fields failed validation, and
#'      why.
#'
#'   It's possible to have multiple `InputValidator` objects for each Shiny app.
#'   One scenario where this makes sense is if an app contains multiple forms
#'   that are completely unrelated to each other; each form would have its own
#'   `InputValidator` instance with a distinct set of rules.
#'
#' @export
InputValidator <- R6::R6Class("InputValidator", cloneable = FALSE,
  private = list(
    session = NULL,
    enabled = FALSE,
    observer_handle = NULL,
    priority = numeric(0),
    condition_ = NULL,
    rules = NULL,
    validators = NULL,
    is_child = FALSE
  ),
  public = list(
    #' @description
    #' Create a new validator object.
    #'
    #' @param priority When a validator object is enabled, it creates an
    #'   internal [shiny::observe()] to keep validation feedback in the UI
    #'   up-to-date. This parameter controls the priority of that observer. It's
    #'   highly recommended to keep this value higher than the priorities of any
    #'   observers that do actual work, so users see validation updates quickly.
    #' @param session The Shiny `session` object. (You should probably just use
    #'   the default.)
    initialize = function(priority = 1000, session = shiny::getDefaultReactiveDomain()) {
      if (is.null(session)) {
        stop("InputValidator objects should be created in the context of Shiny server functions or Shiny module server functions")
      }
      private$session <- session
      private$priority <- priority
      private$condition_ <- shiny::reactiveVal(NULL, label = "validator_condition")
      private$rules <- shiny::reactiveVal(list(), label = "validation_rules")
      private$validators <- shiny::reactiveVal(list(), label = "child_validators")
      
      # Inject shinyvalidate dependencies (just once)
      if (!isTRUE(session$userData[["shinyvalidate-initialized"]])) {
        shiny::insertUI("body", "beforeEnd",
          list(htmldep(), htmltools::HTML("")),
          immediate = TRUE, session = session
        )
        session$userData[["shinyvalidate-initialized"]] <- TRUE
      }
    },
    #' @description For internal use only.
    #' @param validator An `InputValidator` object.
    parent = function(validator) {
      self$disable()
      private$is_child <- TRUE
    },
    #' @description Gets or sets a condition that overrides all of the rules in
    #'   this validator. Before performing validation, this validator will
    #'   execute the `cond` function. If `cond` returns `TRUE`, then
    #'   validation continues as normal; if `FALSE`, then the validation rules
    #'   will be skipped and treated as if they are all passing.
    #' @param cond If this argument is missing, then the method returns the
    #'   currently set condition function. If not missing, then `cond` must
    #'   be either a zero-argument function that returns `TRUE` or `FALSE`; a
    #'   single-sided formula that results in `TRUE` or `FALSE`; or `NULL`
    #'   (which is equivalent to `~ TRUE`).
    #' @return If `cond` is missing, then either `NULL` or a zero-argument
    #'   function; if `cond` is provided, then nothing of consequence is
    #'   returned.
    condition = function(cond) {
      if (missing(cond)) {
        private$condition_()
      } else {
        if (inherits(cond, "formula")) {
          cond <- rlang::as_function(cond)
        }
        if (!is.function(cond) && !is.null(cond)) {
          stop("`cond` argument must be NULL, function, or formula")
        }
        private$condition_(cond)
      }
    },
    #' @description Add another `InputValidator` object to this one, as a
    #'   "child". Any time this validator object is asked for its validity, it
    #'   will only return `TRUE` if all of its child validators are also valid;
    #'   and when this validator object is enabled (or disabled), then all of
    #'   its child validators are enabled (or disabled) as well.
    #'
    #'   This is intended to help with validating Shiny modules. Each module can
    #'   create its own `InputValidator` object and populate it with rules, then
    #'   return that object to the caller.
    #'
    #' @param validator An `InputValidator` object.
    add_validator = function(validator) {
      if (!inherits(validator, "InputValidator")) {
        stop("add_validator was called with an invalid `validator` argument; InputValidator object expected")
      }
      
      validator$parent(self)
      private$validators(c(shiny::isolate(private$validators()), list(validator)))
      invisible(self)
    },
    #' @description Add an input validation rule. Each input validation rule
    #'   applies to a single input. You can add multiple validation rules for a
    #'   single input, by calling `add_rules()` multiple times; the first
    #'   validation rule for an input that fails will be used, and will prevent
    #'   subsequent rules for that input from executing.
    #'
    #' @param inputId A single-element character vector indicating the ID of the
    #'   input that this rule applies to. (Note that this name should _not_ be
    #'   qualified by a module namespace; e.g. pass `"x"` and not
    #'   `session$ns("x")`.)
    #' @param rule A function that takes (at least) one argument: the input's
    #'   value. The function should return `NULL` if it passes validation, and
    #'   if not, a single-element character vector containing an error message
    #'   to display to the user near the input. You can alternatively provide a
    #'   single-sided formula instead of a function, using `.` as the variable
    #'   name for the input value being validated.
    #' @param ... Optional: Additional arguments to pass to the `rule` function
    #'   whenever it is invoked.
    #' @param session. The session object to which the input belongs. (There's
    #'   almost never a reason to change this from the default.)
    add_rule = function(inputId, rule, ..., session. = shiny::getDefaultReactiveDomain()) {
      args <- rlang::list2(...)
      if (is.null(rule)) {
        rule <- function(value, ...) NULL
      }
      if (inherits(rule, "formula")) {
        rule <- rlang::as_function(rule)
      }
      applied_rule <- function(value) {
        # Do this instead of purrr::partial because purrr::partial doesn't
        # support leaving a "hole" for the first argument
        do.call(rule, c(list(value), args))
      }
      rule_info <- list(rule = applied_rule, session = session.)
      private$rules(c(shiny::isolate(private$rules()), stats::setNames(list(rule_info), inputId)))
      invisible(self)
    },
    #' @description Begin displaying input validation feedback in the user
    #'   interface. Once enabled, this validator object will automatically keep
    #'   the feedback up-to-date. (It's safe to call the `enable()` method
    #'   on an already-enabled validator.) If this validator object has been
    #'   added to another validator object using `InputValidator$add_validator`,
    #'   calls to `enable()` on this validator will be ignored.
    enable = function() {
      if (private$is_child) {
        return()
      }
      if (!private$enabled) {
        shiny::withReactiveDomain(private$session, {
          private$observer_handle <- shiny::observe({
            results <- self$validate()
            private$session$sendCustomMessage("validation-jcheng5", results)
          }, priority = private$priority)
        })
        
        private$enabled <- TRUE
      }
      invisible(self)
    },
    #' @description Clear existing input validation feedback in the user
    #'   interface for all inputs represented in this validator's ruleset, and
    #'   stop providing feedback going forward. Once disabled, `enable()` can be
    #'   called to resume input validation.
    disable = function() {
      if (private$enabled) {
        private$observer_handle$destroy()
        private$observer_handle <- NULL
        private$enabled <- FALSE
        if (!private$is_child) {
          results <- self$validate()
          results <- lapply(results, function(x) NULL)
          private$session$sendCustomMessage("validation-jcheng5", results)
        }
      }
    },
    #' @description Returns `TRUE` if all input validation rules currently pass,
    #'   `FALSE` if not.
    fields = function() {
      fieldslist <- unlist(lapply(private$validators(), function(validator) {
        validator$fields()
      }))
      
      fullnames <- mapply(names(private$rules()), private$rules(), FUN = function(name, rule) {
        rule$session$ns(name)
      })
      
      unique(c(fieldslist, fullnames))
    },
    #' @description Returns `TRUE` if all input validation rules currently pass,
    #'   `FALSE` if not.
    is_valid = function() {
      results <- self$validate()
      all(vapply(results, is.null, logical(1), USE.NAMES = FALSE))
    },
    #' @description Run validation rules and gather results. For advanced usage
    #'   only; most apps should use the `is_valid()` and `enable()` methods
    #'   instead. The return value of this method is a named list, where the
    #'   names are (fully namespace qualified) input IDs, and the values are
    #'   either `NULL` (if the input value is passing) or a single-element
    #'   character vector describing a validation problem.
    validate = function() {
      condition <- private$condition_()
      skip_all <- is.function(condition) && !isTRUE(condition())
      if (skip_all) {
        fields <- self$fields()
        return(setNames(rep_len(list(), length(fields)), fields))
      }
      
      dependency_results <- list()
      for (validator in private$validators()) {
        child_results <- validator$validate()
        dependency_results <- merge_results(dependency_results, child_results)
      }

      results <- list()
      mapply(names(private$rules()), private$rules(), FUN = function(name, rule) {
        fullname <- rule$session$ns(name)
        # Short-circuit if already errored
        if (!is.null(results[[fullname]])) return()
        
        try({
          result <- rule$rule(rule$session$input[[name]])
          if (!is.null(result) && (!is.character(result) || length(result) != 1)) {
            stop("Result of '", name, "' validation was not a single-character vector")
          }
          # Note that if there's an error in rule(), we won't get to the next
          # line
          if (is.null(result)) {
            if (!fullname %in% names(results)) {
              # Can't do results[[fullname]] <<- NULL, that just removes the element
              results <<- c(results, stats::setNames(list(NULL), fullname))
            }
          } else {
            results[[fullname]] <<- result
          }
        })
      })
      
      merge_results(dependency_results, results)
    }
  )
)

# Combines two results lists (names are input IDs, values are NULL or a string).
# We combine the two results lists by giving resultsA priority over resultsB,
# except in the case where resultsA has a NULL element and resultsB's
# corresponding element is non-NULL.
merge_results <- function(resultsA, resultsB) {
  results <- c(resultsA, resultsB)
  # Reorder to put non-NULLs first; then dedupe
  has_error <- !vapply(results, is.null, logical(1))
  results <- results[c(which(has_error), which(!has_error))]
  results <- results[!duplicated(names(results))]
  results
}
