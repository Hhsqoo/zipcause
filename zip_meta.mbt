///|
/// Errors returned while parsing ZIP archives or enforcing resource limits.
pub suberror ZipCauseError {
  InvalidArchive(String)
  UnsupportedFeature(String)
  ResourceLimit(String)
}

///|
/// Metadata for one member, including byte slices into the original archive.
pub struct EntryMeta {
  name : String
  index : Int32
  flags : Int32
  compression_method : Int32
  modified_time : Int32
  modified_date : Int32
  local_modified_time : Int32
  local_modified_date : Int32
  crc32 : UInt32
  compressed_size : Int32
  uncompressed_size : Int32
  external_attributes : UInt32
  local_extra : BytesView
  central_extra : BytesView
  comment : BytesView
  compressed_data : BytesView
}

///|
/// The central-directory metadata and archive comment for a ZIP file.
pub struct ArchiveMeta {
  entries : Array[EntryMeta]
  comment : BytesView
}

///|
const MAX_ARCHIVE_BYTES : Int32 = 67108864

///|
const MAX_ENTRIES : Int32 = 10000

///|
const MAX_MEMBER_BYTES : Int32 = 33554432

///|
const MAX_TOTAL_BYTES : Int32 = 134217728

///|
fn fail_archive(message : String) -> Unit raise ZipCauseError {
  raise InvalidArchive(message)
}

///|
fn le16(bytes : BytesView, offset : Int32) -> Int32 raise ZipCauseError {
  if offset < 0 || offset > bytes.length() - 2 {
    fail_archive("truncated 16-bit field")
  }
  bytes[offset].to_int() | (bytes[offset + 1].to_int() << 8)
}

///|
fn le32(bytes : BytesView, offset : Int32) -> UInt32 raise ZipCauseError {
  if offset < 0 || offset > bytes.length() - 4 {
    fail_archive("truncated 32-bit field")
  }
  let b0 = bytes[offset].to_int().reinterpret_as_uint()
  let b1 = bytes[offset + 1].to_int().reinterpret_as_uint()
  let b2 = bytes[offset + 2].to_int().reinterpret_as_uint()
  let b3 = bytes[offset + 3].to_int().reinterpret_as_uint()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
fn safe_int(value : UInt32, field : String) -> Int32 raise ZipCauseError {
  if value > 0x7FFFFFFF {
    raise UnsupportedFeature("ZIP64 or oversized \{field} is not supported")
  }
  value.reinterpret_as_int()
}

///|
fn decode_zip_name(
  bytes : BytesView,
  flags : Int32,
) -> String raise ZipCauseError {
  if (flags & 0x0800) == 0 {
    for i = 0; i < bytes.length(); i = i + 1 {
      if bytes[i].to_int() > 0x7F {
        raise UnsupportedFeature(
          "non-ASCII entry names require the ZIP UTF-8 flag",
        )
      }
    }
  }
  @encoding/utf8.decode(bytes) catch {
    _ => raise InvalidArchive("entry name is not valid UTF-8")
  }
}

///|
fn equal_bytes(left : BytesView, right : BytesView) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for i = 0; i < left.length(); i = i + 1 {
    if left[i] != right[i] {
      return false
    }
  }
  true
}

///|
fn find_eocd(bytes : BytesView) -> Int32 raise ZipCauseError {
  if bytes.length() < 22 {
    fail_archive("file is too short to contain an end record")
  }
  let start = if bytes.length() > 65557 { bytes.length() - 65557 } else { 0 }
  let mut pos = bytes.length() - 22
  while pos >= start {
    if le32(bytes, pos) == 0x06054B50 {
      let comment_length = le16(bytes, pos + 20)
      if pos + 22 + comment_length == bytes.length() {
        return pos
      }
    }
    pos = pos - 1
  }
  raise InvalidArchive("end of central directory record not found")
}

///|
/// Parses a bounded, single-volume classic ZIP archive without extracting it.
/// ZIP64, encrypted entries, and compression methods other than STORE/DEFLATE
/// are reported as unsupported features.
pub fn inspect_zip(bytes : BytesView) -> ArchiveMeta raise ZipCauseError {
  if bytes.length() > MAX_ARCHIVE_BYTES {
    raise ResourceLimit("archive exceeds 64 MiB input limit")
  }
  let eocd = find_eocd(bytes)
  let disk = le16(bytes, eocd + 4)
  let central_disk = le16(bytes, eocd + 6)
  let disk_entries = le16(bytes, eocd + 8)
  let total_entries = le16(bytes, eocd + 10)
  if disk != 0 || central_disk != 0 || disk_entries != total_entries {
    raise UnsupportedFeature("multi-volume ZIP archives are not supported")
  }
  if total_entries == 0xFFFF {
    raise UnsupportedFeature("ZIP64 archives are not supported")
  }
  if total_entries > MAX_ENTRIES {
    raise ResourceLimit("archive exceeds 10000 entry limit")
  }
  let central_size = safe_int(le32(bytes, eocd + 12), "central directory size")
  let central_offset = safe_int(
    le32(bytes, eocd + 16),
    "central directory offset",
  )
  if central_offset > eocd || central_size > eocd - central_offset {
    fail_archive("central directory extends outside the archive")
  }
  let comment_length = le16(bytes, eocd + 20)
  let archive_comment = bytes[eocd + 22:eocd + 22 + comment_length]
  let mut pos = central_offset
  let entries : Array[EntryMeta] = []
  let seen : Map[String, Bool] = Map([], capacity=total_entries)
  for index = 0; index < total_entries; index = index + 1 {
    if pos > central_offset + central_size - 46 ||
      le32(bytes, pos) != 0x02014B50 {
      fail_archive("invalid central directory entry")
    }
    let flags = le16(bytes, pos + 8)
    let compression_method = le16(bytes, pos + 10)
    if (flags & 1) != 0 {
      raise UnsupportedFeature("encrypted ZIP entries are not supported")
    }
    if (flags & 0xF7F1) != 0 {
      raise UnsupportedFeature(
        "ZIP entry uses unsupported general-purpose flags",
      )
    }
    if compression_method != 0 && compression_method != 8 {
      raise UnsupportedFeature("only STORE and DEFLATE entries are supported")
    }
    if compression_method == 0 && (flags & 0x0006) != 0 {
      raise UnsupportedFeature(
        "compression option flags are invalid for STORE entries",
      )
    }
    let modified_time = le16(bytes, pos + 12)
    let modified_date = le16(bytes, pos + 14)
    let crc32 = le32(bytes, pos + 16)
    let compressed_size = safe_int(le32(bytes, pos + 20), "compressed size")
    let uncompressed_size = safe_int(le32(bytes, pos + 24), "uncompressed size")
    if compression_method == 0 && compressed_size != uncompressed_size {
      fail_archive("STORE entry compressed and uncompressed sizes differ")
    }
    if uncompressed_size > MAX_MEMBER_BYTES {
      raise ResourceLimit("entry exceeds 32 MiB uncompressed limit")
    }
    let name_length = le16(bytes, pos + 28)
    let extra_length = le16(bytes, pos + 30)
    let entry_comment_length = le16(bytes, pos + 32)
    let disk_start = le16(bytes, pos + 34)
    if disk_start != 0 {
      raise UnsupportedFeature("multi-volume entries are not supported")
    }
    let external_attributes = le32(bytes, pos + 38)
    let local_offset = safe_int(le32(bytes, pos + 42), "local header offset")
    if compressed_size == 0xFFFFFFFF ||
      uncompressed_size == 0xFFFFFFFF ||
      local_offset == 0xFFFFFFFF {
      raise UnsupportedFeature("ZIP64 entries are not supported")
    }
    let variable_start = pos + 46
    let variable_length = name_length + extra_length + entry_comment_length
    if variable_start > central_offset + central_size ||
      variable_length > central_offset + central_size - variable_start {
      fail_archive("truncated central directory entry")
    }
    let raw_name = bytes[variable_start:variable_start + name_length]
    let name = decode_zip_name(raw_name, flags)
    if seen.get(name) is Some(_) {
      raise UnsupportedFeature("duplicate entry name: \{name}")
    }
    seen.set(name, true)
    let central_extra_start = variable_start + name_length
    let central_extra = bytes[central_extra_start:central_extra_start +
      extra_length]
    let entry_comment_start = central_extra_start + extra_length
    let entry_comment = bytes[entry_comment_start:entry_comment_start +
      entry_comment_length]
    if local_offset > central_offset - 30 ||
      le32(bytes, local_offset) != 0x04034B50 {
      fail_archive("invalid local header for \{name}")
    }
    let local_flags = le16(bytes, local_offset + 6)
    let local_method = le16(bytes, local_offset + 8)
    let local_modified_time = le16(bytes, local_offset + 10)
    let local_modified_date = le16(bytes, local_offset + 12)
    let local_name_length = le16(bytes, local_offset + 26)
    let local_extra_length = le16(bytes, local_offset + 28)
    if local_flags != flags ||
      local_method != compression_method ||
      local_name_length != name_length {
      fail_archive("local and central headers disagree for \{name}")
    }
    if (flags & 0x0008) == 0 &&
      (
        le32(bytes, local_offset + 14) != crc32 ||
        safe_int(le32(bytes, local_offset + 18), "local compressed size") !=
        compressed_size ||
        safe_int(le32(bytes, local_offset + 22), "local uncompressed size") !=
        uncompressed_size
      ) {
      fail_archive("local and central CRC or sizes disagree for \{name}")
    }
    let local_name_start = local_offset + 30
    let local_extra_start = local_name_start + local_name_length
    let compressed_start = local_extra_start + local_extra_length
    if compressed_start > central_offset ||
      compressed_size > central_offset - compressed_start {
      fail_archive(
        "compressed data extends outside the file data area for \{name}",
      )
    }
    if !equal_bytes(bytes[local_name_start:local_extra_start], raw_name) {
      fail_archive("local and central entry names disagree for \{name}")
    }
    let local_extra = bytes[local_extra_start:compressed_start]
    entries.push({
      name,
      index,
      flags,
      compression_method,
      modified_time,
      modified_date,
      local_modified_time,
      local_modified_date,
      crc32,
      compressed_size,
      uncompressed_size,
      external_attributes,
      local_extra,
      central_extra,
      comment: entry_comment,
      compressed_data: bytes[compressed_start:compressed_start + compressed_size],
    })
    pos = variable_start + variable_length
  }
  if pos != central_offset + central_size {
    fail_archive("central directory size does not match its entries")
  }
  { entries, comment: archive_comment, }
}

///|
/// Decodes every member within configured limits and verifies its CRC-32.
pub fn verify_zip_payloads(bytes : BytesView) -> Unit raise ZipCauseError {
  let archive = @zip.read(
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
  for entry in archive.entries() {
    if @checksum.crc32(entry.data()) != entry.crc32() {
      fail_archive("CRC-32 mismatch for entry \{entry.name()}")
    }
  }
}
