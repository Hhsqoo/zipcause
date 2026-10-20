///|
const USAGE : String = "Usage: zipcause compare <first.zip> <second.zip> [--format text|json]"

///|
const VERSION : String = "0.1.0"

///|
pub suberror CliError {
  CliError(String)
}

///|
fn read_input(path : String) -> Bytes raise CliError {
  @fs.read_file_to_bytes(path) catch {
    @fs.IOError(message) => raise CliError("cannot read \{path}: \{message}")
  }
}

///|
fn run_compare(
  first_path : String,
  second_path : String,
  format : String,
) -> Int32 raise CliError {
  let first = read_input(first_path)
  let second = read_input(second_path)
  let comparison = @zipcause.compare_zip_bytes(first, second) catch {
    @zipcause.InvalidArchive(message) =>
      raise CliError("invalid archive: \{message}")
    @zipcause.UnsupportedFeature(message) =>
      raise CliError("unsupported archive: \{message}")
    @zipcause.ResourceLimit(message) =>
      raise CliError("resource limit: \{message}")
  }
  if format == "json" {
    println(@zipcause.comparison_to_json(comparison))
  } else if comparison.byte_identical {
    println("Archives are byte-identical.")
  } else {
    println("Archives differ:")
    for finding in comparison.findings {
      let location = if finding.path == "" {
        "archive"
      } else {
        Json(finding.path).stringify()
      }
      println("- \{finding.kind}: \{location} — \{finding.detail}")
    }
  }
  if comparison.byte_identical {
    0
  } else {
    1
  }
}

///|
fn execute(args : Array[String]) -> Int32 {
  match args {
    [_program, "--version"] | [_program, "-V"] => {
      println("zipcause \{VERSION}")
      0
    }
    [_program, "--help"] | [_program, "-h"] => {
      println(USAGE)
      0
    }
    [_program, "compare", first, second] =>
      run_compare(first, second, "text") catch {
        CliError(message) => {
          eprintln("error: \{message}")
          2
        }
      }
    [_program, "compare", first, second, "--format", format] if format == "json" ||
      format == "text" =>
      run_compare(first, second, format) catch {
        CliError(message) => {
          eprintln("error: \{message}")
          2
        }
      }
    _ => {
      eprintln(USAGE)
      2
    }
  }
}

///|
fn main {
  @sys.exit(execute(@env.args()))
}
