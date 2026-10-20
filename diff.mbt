///|
/// One explanation for a difference between two ZIP archives.
pub struct Finding {
  kind : String
  path : String
  detail : String
}

///|
/// The byte-equality result and all classified differences.
pub struct Comparison {
  byte_identical : Bool
  findings : Array[Finding]
}

///|
fn safe_read_zip(bytes : BytesView) -> @zip.Archive raise ZipCauseError {
  @zip.read(
    bytes,
    limits=@zip.ReadLimits::default()
      .with_package_limit(MAX_ARCHIVE_BYTES)
      .with_entries_limit(MAX_ENTRIES)
      .with_entry_limit(MAX_MEMBER_BYTES)
      .with_total_limit(MAX_TOTAL_BYTES)
      .with_preserved_source_limit(MAX_ARCHIVE_BYTES),
  ) catch {
    @zip.ZipError(_, message) => raise InvalidArchive(message)
  }
}

///|
fn decoded_payloads(
  bytes : BytesView,
) -> Map[String, BytesView] raise ZipCauseError {
  let archive = safe_read_zip(bytes)
  let payloads : Map[String, BytesView] = Map(
    [],
    capacity=archive.entries().length(),
  )
  for entry in archive.entries() {
    let data = entry.data()
    if @checksum.crc32(data) != entry.crc32() {
      raise InvalidArchive("CRC-32 mismatch for entry \{entry.name()}")
    }
    payloads.set(entry.name(), data)
  }
  payloads
}

///|
fn add_finding(
  findings : Array[Finding],
  kind : String,
  path : String,
  detail : String,
) -> Unit {
  findings.push({ kind, path, detail, })
}

///|
/// Compares two supported ZIP archives by member name and container metadata.
/// Invalid, unsupported, or over-limit archives raise `ZipCauseError`.
pub fn compare_zip_bytes(
  left_bytes : BytesView,
  right_bytes : BytesView,
) -> Comparison raise ZipCauseError {
  let left = inspect_zip(left_bytes)
  let right = inspect_zip(right_bytes)
  let left_payloads = decoded_payloads(left_bytes)
  let right_payloads = decoded_payloads(right_bytes)
  let right_indices : Map[String, Int] = Map(
    [],
    capacity=right.entries.length(),
  )
  for entry in right.entries {
    right_indices.set(entry.name, entry.index)
  }
  let findings : Array[Finding] = []
  let mut common_order_changed = false
  let common_left : Array[String] = []
  let common_right : Array[String] = []
  for entry in left.entries {
    match right_indices.get(entry.name) {
      None =>
        add_finding(
          findings,
          "member_removed",
          entry.name,
          "entry exists only in the first archive",
        )
      Some(_) => common_left.push(entry.name)
    }
  }
  let left_indices : Map[String, Int] = Map([], capacity=left.entries.length())
  for entry in left.entries {
    left_indices.set(entry.name, entry.index)
  }
  for entry in right.entries {
    match left_indices.get(entry.name) {
      None =>
        add_finding(
          findings,
          "member_added",
          entry.name,
          "entry exists only in the second archive",
        )
      Some(_) => common_right.push(entry.name)
    }
  }
  if common_left.length() == common_right.length() {
    for i = 0; i < common_left.length(); i = i + 1 {
      if common_left[i] != common_right[i] {
        common_order_changed = true
      }
    }
  }
  if common_order_changed {
    add_finding(
      findings, "entry_order_changed", "", "the relative order of shared entries changed",
    )
  }
  for left_entry in left.entries {
    match right_indices.get(left_entry.name) {
      None => ()
      Some(right_index) => {
        let right_entry = right.entries[right_index]
        match
          (
            left_payloads.get(left_entry.name),
            right_payloads.get(left_entry.name),
          ) {
          (Some(left_data), Some(right_data)) => {
            let same_content = equal_bytes(left_data, right_data)
            if !same_content {
              add_finding(
                findings,
                "member_content_changed",
                left_entry.name,
                "uncompressed entry data differs",
              )
            }
            if left_entry.compression_method != right_entry.compression_method {
              add_finding(
                findings,
                "compression_method_changed",
                left_entry.name,
                "ZIP compression method changed",
              )
            }
            if same_content &&
              left_entry.compression_method == right_entry.compression_method &&
              !equal_bytes(
                left_entry.compressed_data,
                right_entry.compressed_data,
              ) {
              add_finding(
                findings,
                "compressed_stream_changed",
                left_entry.name,
                "uncompressed data matches but compressed bytes differ",
              )
            }
          }
          _ =>
            raise InvalidArchive(
              "decoded entry is missing from its central directory",
            )
        }
        if left_entry.modified_time != right_entry.modified_time ||
          left_entry.modified_date != right_entry.modified_date ||
          left_entry.local_modified_time != right_entry.local_modified_time ||
          left_entry.local_modified_date != right_entry.local_modified_date {
          add_finding(
            findings,
            "timestamp_changed",
            left_entry.name,
            "DOS timestamp differs between archive entries",
          )
        }
        if left_entry.external_attributes != right_entry.external_attributes {
          add_finding(
            findings,
            "attributes_changed",
            left_entry.name,
            "external file attributes differ",
          )
        }
        if left_entry.flags != right_entry.flags {
          add_finding(
            findings,
            "flags_changed",
            left_entry.name,
            "general-purpose ZIP flags differ",
          )
        }
        if !equal_bytes(left_entry.local_extra, right_entry.local_extra) ||
          !equal_bytes(left_entry.central_extra, right_entry.central_extra) {
          add_finding(
            findings,
            "extra_fields_changed",
            left_entry.name,
            "local or central extra fields differ",
          )
        }
        if !equal_bytes(left_entry.comment, right_entry.comment) {
          add_finding(
            findings,
            "entry_comment_changed",
            left_entry.name,
            "entry comments differ",
          )
        }
      }
    }
  }
  if !equal_bytes(left.comment, right.comment) {
    add_finding(
      findings, "archive_comment_changed", "", "archive comments differ",
    )
  }
  let byte_identical = equal_bytes(left_bytes, right_bytes)
  if !byte_identical && findings.length() == 0 {
    add_finding(
      findings, "unclassified_container_difference", "", "archive bytes differ in a container field not yet classified",
    )
  }
  { byte_identical, findings, }
}

///|
/// Encodes a comparison as a JSON object with stable field names.
pub fn comparison_to_json(comparison : Comparison) -> String {
  let findings = comparison.findings.map(fn(finding) {
    Json::object({
      "kind": Json(finding.kind),
      "path": Json(finding.path),
      "detail": Json(finding.detail),
    })
  })
  Json::object({
    "byte_identical": Json(comparison.byte_identical),
    "findings": Json::array(findings),
  }).stringify()
}
