#' A reticulate Engine for Knitr
#' 
#' This provides a `reticulate` engine for `knitr`, suitable for usage when
#' attempting to render Python chunks. Using this engine allows for shared state
#' between Python chunks in a document -- that is, variables defined by one
#' Python chunk can be used by later Python chunks.
#' 
#' The engine can be activated by setting (for example)
#' 
#' ```
#' knitr::knit_engines$set(python = reticulate::eng_python)
#' ```
#' 
#' Typically, this will be set within a document's setup chunk, or by the
#' environment requesting that Python chunks be processed by this engine.
#' 
#' @param options
#'   Chunk options, as provided by `knitr` during chunk execution.
#'   
#' @export
eng_python <- function(options) {
  
  engine.path <- if (is.list(options[["engine.path"]]))
    options[["engine.path"]][["python"]]
  else
    options[["engine.path"]]
    
  # if the user has requested a custom Python, attempt
  # to honor that request (warn if Python already initialized
  # to a different version)
  if (is.character(engine.path)) {
    
    # if Python has not yet been loaded, then try
    # to load it with the requested version of Python
    if (!py_available())
      use_python(engine.path, required = TRUE)
      
    # double-check that we've loaded the requested Python
    conf <- py_config()
    requestedPython <- normalizePath(engine.path)
    actualPython <- normalizePath(conf$python)
    if (requestedPython != actualPython) {
      fmt <- "cannot honor request to use Python %s [%s already loaded]"
      msg <- sprintf(fmt, requestedPython, actualPython)
      warning(msg, immediate. = TRUE, call. = FALSE)
    }
  }
  
  context <- new.env(parent = emptyenv())
  eng_python_initialize(
    options,
    context = context,
    envir = environment()
  )
  
  ast <- import("ast", convert = TRUE)
  
  # helper function for extracting range of code, dropping blank lines
  extract <- function(code, range) {
    snippet <- code[range[1]:range[2]]
    paste(snippet[nzchar(snippet)], collapse = "\n")
  }
  
  # extract the code to be run -- we'll attempt to run the code line by line
  # and detect changes so that we can interleave code and output (similar to
  # what one sees when executing an R chunk in knitr). to wit, we'll do our
  # best to emulate the return format of 'evaluate::evaluate()'
  code <- options$code
  n <- length(code)
  if (n == 0)
    return(list())
  
  # use 'ast.parse()' to parse Python code and collect line numbers, so we
  # can split source code into statements
  pasted <- paste(code, collapse = "\n")
  parsed <- ast$parse(pasted, "<string>")
  
  # iterate over top-level nodes and extract line numbers
  lines <- vapply(parsed$body, function(node) {
    node$lineno
  }, integer(1))
  
  # convert from lines to ranges
  starts <- lines
  ends <- c(lines[-1] - 1, length(code))
  ranges <- mapply(c, starts, ends, SIMPLIFY = FALSE)
  
  # line index from which source should be emitted
  pending_source_index <- 1
  
  # actual outputs to be returned to knitr
  outputs <- list()
  
  # synchronize state R -> Python
  eng_python_synchronize_before()
  
  for (range in ranges) {
    
    # evaluate current chunk of code
    snippet <- extract(code, range)
    captured <- py_capture_output(
      py_run_string(snippet, convert = FALSE)
    )
    
    if (nzchar(captured) || length(context$pending_plots)) {
      
      # append pending source to outputs
      outputs[[length(outputs) + 1]] <- structure(
        list(src = extract(code, c(pending_source_index, range[2]))),
        class = "source"
      )
      
      # append captured outputs
      if (nzchar(captured))
        outputs[[length(outputs) + 1]] <- captured
      
      # append captured images / figures
      if (length(context$pending_plots)) {
        for (plot in context$pending_plots)
          outputs[[length(outputs) + 1]] <- plot
        context$pending_plots <- list()
      }
      
      # update pending source range
      pending_source_index <- range[2] + 1
    }
  }
  
  # if we have leftover input, add that now
  if (pending_source_index <= n) {
    leftover <- extract(code, c(pending_source_index, n))
    outputs[[length(outputs) + 1]] <- structure(
      list(src = leftover),
      class = "source"
    )
  }
  
  eng_python_synchronize_after()
  
  # TODO: development version of knitr supplies new 'engine_output()'
  # interface -- use that when it's on CRAN
  # https://github.com/yihui/knitr/commit/71bfd8796d485ed7bb9db0920acdf02464b3df9a
  wrap <- yoink("knitr", "wrap")
  wrap(outputs, options)
  
}

eng_python_initialize <- function(options, context, envir) {
  
  if (is.character(options$engine.path))
    use_python(options$engine.path[[1]])
  
  eng_python_initialize_matplotlib(options, context, envir)
}

eng_python_initialize_matplotlib <- function(options,
                                             context,
                                             envir)
{
  if (!py_module_available("matplotlib"))
    return()
  
  # initialize pending_plots list
  context$pending_plots <- list()
  
  matplotlib <- import("matplotlib", convert = FALSE)
  plt <- matplotlib$pyplot
  
  # rudely steal 'plot_counter' (used below), and reset
  # it when we're done
  plot_counter <- yoink("knitr", "plot_counter")
  defer(plot_counter(reset = TRUE), envir = envir)
  
  # save + restore old show hook
  show <- plt$show
  defer(plt$show <- show, envir = envir)
  plt$show <- function(...) {
    
    # write plot to file
    path <- knitr::fig_path(options$dev, number = plot_counter())
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    plt$savefig(path, dpi = options$dpi)
    
    # return as a knitr image path
    context$pending_plots[[length(context$pending_plots) + 1]] <<-
      knitr::include_graphics(path)
  }
  
  # set up figure dimensions
  plt$rc("figure", figsize = tuple(options$fig.width, options$fig.height))
  
}

# synchronize objects R -> Python
eng_python_synchronize_before <- function() {
  
  # define our 'R' class
  py_run_string("class R(object): pass")
  
  # extract it from the main module
  main <- import_main(convert = FALSE)
  R <- main$R
  
  # extract active knit environment
  .knitEnv <- yoink("knitr", ".knitEnv")
  envir <- .knitEnv$knit_global
  
  # define the getters, setters we'll attach to the Python class
  getter <- function(self, code) {
    r_to_py(eval(parse(text = as_r_value(code)), envir = envir))
  }
  
  setter <- function(self, name, value) {
    envir[[as_r_value(name)]] <<- as_r_value(value)
  }
  
  py_set_attr(R, "__getattr__", getter)
  py_set_attr(R, "__setattr__", setter)
  py_set_attr(R, "__getitem__", getter)
  py_set_attr(R, "__setitem__", setter)
  
  # now define the R object
  py_run_string("r = R()")
}

# synchronize objects Python -> R
eng_python_synchronize_after <- function() {
}