///|
fn test_zip(
  name : String,
  body : BytesView,
  compression : @zip.Compression,
) -> Bytes raise @zip.ZipError {
  let archive = @zip.Archive::Archive()
  archive.add(name, body, compression~)
  @zip.write(archive)
}

///|
fn test_deflated_zip(
  name : String,
  body : BytesView,
  level : Int32,
) -> Bytes raise @zip.ZipError {
  let archive = @zip.Archive::Archive()
  archive.add(name, body, compression=@zip.Deflate)
  @zip.write(archive, level~)
}

///|
fn find_signature(bytes : BytesView, signature : UInt32) -> Int32 {
  let mut pos = 0
  while pos <= bytes.length() - 4 {
    let value = bytes[pos].to_int().reinterpret_as_uint() |
      (bytes[pos + 1].to_int().reinterpret_as_uint() << 8) |
      (bytes[pos + 2].to_int().reinterpret_as_uint() << 16) |
      (bytes[pos + 3].to_int().reinterpret_as_uint() << 24)
    if value == signature {
      return pos
    }
    pos = pos + 1
  }
  -1
}

///|
fn set_u16(bytes : Array[Byte], offset : Int32, value : Int32) -> Unit {
  bytes[offset] = (value & 0xFF).to_byte()
  bytes[offset + 1] = ((value >> 8) & 0xFF).to_byte()
}

///|
fn get_u16(bytes : BytesView, offset : Int32) -> Int32 {
  bytes[offset].to_int() | (bytes[offset + 1].to_int() << 8)
}

///|
fn set_u32(bytes : Array[Byte], offset : Int32, value : UInt32) -> Unit {
  bytes[offset] = (value & 0xFF).reinterpret_as_int().to_byte()
  bytes[offset + 1] = ((value >> 8) & 0xFF).reinterpret_as_int().to_byte()
  bytes[offset + 2] = ((value >> 16) & 0xFF).reinterpret_as_int().to_byte()
  bytes[offset + 3] = ((value >> 24) & 0xFF).reinterpret_as_int().to_byte()
}

///|
fn insert_bytes(
  source : BytesView,
  offset : Int32,
  inserted : Array[Byte],
) -> Array[Byte] {
  let output = Array::make(source.length() + inserted.length(), b'\x00')
  for i = 0; i < offset; i = i + 1 {
    output[i] = source[i]
  }
  for i = 0; i < inserted.length(); i = i + 1 {
    output[offset + i] = inserted[i]
  }
  for i = offset; i < source.length(); i = i + 1 {
    output[i + inserted.length()] = source[i]
  }
  output
}

///|
fn is_unsupported_zip(bytes : BytesView) -> Bool {
  try @zipcause.inspect_zip(bytes) catch {
    @zipcause.UnsupportedFeature(_) => true
    _ => false
  } noraise {
    _ => false
  }
}

///|
fn is_invalid_zip(bytes : BytesView) -> Bool {
  try @zipcause.inspect_zip(bytes) catch {
    @zipcause.InvalidArchive(_) => true
    _ => false
  } noraise {
    _ => false
  }
}

///|
fn has_resource_limit(bytes : BytesView) -> Bool {
  try @zipcause.inspect_zip(bytes) catch {
    @zipcause.ResourceLimit(_) => true
    _ => false
  } noraise {
    _ => false
  }
}

///|
fn has_invalid_payload(bytes : BytesView) -> Bool {
  try @zipcause.verify_zip_payloads(bytes) catch {
    @zipcause.InvalidArchive(_) => true
    _ => false
  } noraise {
    _ => false
  }
}

///|
test "identical archives compare byte for byte" {
  let first = test_zip("notes/hello.txt", b"hello world", @zip.Store)
  let second = test_zip("notes/hello.txt", b"hello world", @zip.Store)
  let result = @zipcause.compare_zip_bytes(first, second)
  assert_true(result.byte_identical)
  assert_eq(result.findings.length(), 0)
}

///|
test "payload change is reported by member name" {
  let first = test_zip("notes/hello.txt", b"hello world", @zip.Store)
  let second = test_zip("notes/hello.txt", b"hello moon", @zip.Store)
  let result = @zipcause.compare_zip_bytes(first, second)
  assert_true(!result.byte_identical)
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "member_content_changed" &&
      finding.path == "notes/hello.txt" &&
      finding.detail ==
      "uncompressed entry data differs (first: 11 bytes; second: 10 bytes)"
    }),
  )
}

///|
test "added and removed members are reported" {
  let first_archive = @zip.Archive::Archive()
  first_archive.add("keep.txt", b"same", compression=@zip.Store)
  first_archive.add("old.txt", b"old", compression=@zip.Store)
  let second_archive = @zip.Archive::Archive()
  second_archive.add("keep.txt", b"same", compression=@zip.Store)
  second_archive.add("new.txt", b"new", compression=@zip.Store)
  let result = @zipcause.compare_zip_bytes(
    @zip.write(first_archive),
    @zip.write(second_archive),
  )
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "member_removed" && finding.path == "old.txt"
    }),
  )
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "member_added" && finding.path == "new.txt"
    }),
  )
}

///|
test "truncated archive is rejected" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  try @zipcause.inspect_zip(archive[:archive.length() - 1]) catch {
    _ => ()
  } noraise {
    _ => fail("expected truncated archive to be rejected")
  }
}

///|
test "local CRC mismatch is rejected when no data descriptor is used" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let changed = archive.to_array()
  set_u32(changed, 14, 0x12345678)
  assert_true(is_invalid_zip(Bytes::from_array(changed)))
}

///|
test "local size mismatch is rejected when no data descriptor is used" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let changed = archive.to_array()
  set_u32(changed, 18, 4)
  assert_true(is_invalid_zip(Bytes::from_array(changed)))
}

///|
test "payload verifier accepts a valid archive" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  @zipcause.verify_zip_payloads(archive)
}

///|
test "relative order of shared entries is reported" {
  let first_archive = @zip.Archive::Archive()
  first_archive.add("a.txt", b"a", compression=@zip.Store)
  first_archive.add("b.txt", b"b", compression=@zip.Store)
  let second_archive = @zip.Archive::Archive()
  second_archive.add("b.txt", b"b", compression=@zip.Store)
  second_archive.add("a.txt", b"a", compression=@zip.Store)
  let result = @zipcause.compare_zip_bytes(
    @zip.write(first_archive),
    @zip.write(second_archive),
  )
  assert_true(
    result.findings.any(fn(finding) { finding.kind == "entry_order_changed" }),
  )
}

///|
test "DOS timestamp change is reported" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let changed = archive.to_array()
  let central = find_signature(archive, 0x02014B50)
  assert_true(central >= 0)
  set_u16(changed, 10, 1)
  set_u16(changed, central + 12, 1)
  let result = @zipcause.compare_zip_bytes(archive, Bytes::from_array(changed))
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "timestamp_changed" && finding.path == "a.txt"
    }),
  )
}

///|
test "compression method change is reported for equal content" {
  let stored = test_zip("a.txt", b"same payload", @zip.Store)
  let deflated = test_zip("a.txt", b"same payload", @zip.Deflate)
  let result = @zipcause.compare_zip_bytes(stored, deflated)
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "compression_method_changed" &&
      finding.path == "a.txt" &&
      finding.detail ==
      "compression method changed from STORE (0) to DEFLATE (8)"
    }),
  )
}

///|
test "different DEFLATE streams with equal content are reported" {
  let body = Bytes::from_array(Array::make(1024, b'a'))
  let first = test_deflated_zip("a.txt", body, 0)
  let second = test_deflated_zip("a.txt", body, 9)
  let result = @zipcause.compare_zip_bytes(first, second)
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "compressed_stream_changed" && finding.path == "a.txt"
    }),
  )
}

///|
test "supported UTF-8 flag difference is reported" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let changed = archive.to_array()
  let central = find_signature(archive, 0x02014B50)
  assert_true(central >= 0)
  let flags = get_u16(archive, 6)
  let changed_flags = if (flags & 0x0800) == 0 {
    flags + 0x0800
  } else {
    flags - 0x0800
  }
  set_u16(changed, 6, changed_flags)
  set_u16(changed, central + 8, changed_flags)
  let result = @zipcause.compare_zip_bytes(archive, Bytes::from_array(changed))
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "flags_changed" && finding.path == "a.txt"
    }),
  )
}

///|
test "UTF-8 entry names require the UTF-8 flag" {
  let archive = test_zip("资料/config.json", b"{}", @zip.Store)
  let metadata = @zipcause.inspect_zip(archive)
  assert_eq(metadata.entries[0].name, "资料/config.json")

  let changed = archive.to_array()
  let central = find_signature(archive, 0x02014B50)
  assert_true(central >= 0)
  set_u16(changed, 6, get_u16(archive, 6) & 0xF7FF)
  set_u16(changed, central + 8, get_u16(archive, central + 8) & 0xF7FF)
  assert_true(is_unsupported_zip(Bytes::from_array(changed)))
}

///|
test "external attributes change is reported" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let changed = archive.to_array()
  let central = find_signature(archive, 0x02014B50)
  assert_true(central >= 0)
  set_u32(changed, central + 38, 0x12345678)
  let result = @zipcause.compare_zip_bytes(archive, Bytes::from_array(changed))
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "attributes_changed" && finding.path == "a.txt"
    }),
  )
}

///|
test "ZIP creator version change is reported" {
  let first = test_zip("a.txt", b"hello", @zip.Store)
  let changed = first.to_array()
  let central = find_signature(first, 0x02014B50)
  assert_true(central >= 0)
  set_u16(changed, central + 4, get_u16(first, central + 4) + 1)
  let result = @zipcause.compare_zip_bytes(first, Bytes::from_array(changed))
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "creator_version_changed"
    }),
  )
}

///|
test "ZIP required version change is reported" {
  let first = test_zip("a.txt", b"hello", @zip.Store)
  let changed = first.to_array()
  let central = find_signature(first, 0x02014B50)
  assert_true(central >= 0)
  set_u16(changed, central + 6, get_u16(first, central + 6) + 1)
  let result = @zipcause.compare_zip_bytes(first, Bytes::from_array(changed))
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "required_version_changed"
    }),
  )
}

///|
test "ZIP internal attributes change is reported" {
  let first = test_zip("a.txt", b"hello", @zip.Store)
  let changed = first.to_array()
  let central = find_signature(first, 0x02014B50)
  assert_true(central >= 0)
  set_u16(changed, central + 36, get_u16(first, central + 36) + 1)
  let result = @zipcause.compare_zip_bytes(first, Bytes::from_array(changed))
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "internal_attributes_changed"
    }),
  )
}

///|
test "archive comment change is reported" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let eocd = find_signature(archive, 0x06054B50)
  assert_true(eocd >= 0)
  let changed = Array::make(archive.length() + 1, b'\x00')
  for i = 0; i < archive.length(); i = i + 1 {
    changed[i] = archive[i]
  }
  changed[archive.length()] = b'!'
  set_u16(changed, eocd + 20, 1)
  let result = @zipcause.compare_zip_bytes(archive, Bytes::from_array(changed))
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "archive_comment_changed"
    }),
  )
}

///|
test "entry comment change is reported" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let central = find_signature(archive, 0x02014B50)
  let eocd = find_signature(archive, 0x06054B50)
  assert_true(central >= 0 && eocd >= 0)
  let comment_start = central + 46 + 5
  let changed = insert_bytes(archive, comment_start, [b'!'])
  set_u16(changed, central + 32, 1)
  set_u32(changed, eocd + 1 + 12, (eocd - central + 1).reinterpret_as_uint())
  let result = @zipcause.compare_zip_bytes(archive, Bytes::from_array(changed))
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "entry_comment_changed" && finding.path == "a.txt"
    }),
  )
}

///|
test "local extra field change is reported" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let central = find_signature(archive, 0x02014B50)
  let eocd = find_signature(archive, 0x06054B50)
  assert_true(central >= 0 && eocd >= 0)
  let local_extra_start = 30 + 5
  let changed = insert_bytes(archive, local_extra_start, [
    b'\xFE', b'\xCA', b'\x00', b'\x00',
  ])
  set_u16(changed, 28, 4)
  set_u32(changed, eocd + 4 + 16, (central + 4).reinterpret_as_uint())
  let result = @zipcause.compare_zip_bytes(archive, Bytes::from_array(changed))
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "extra_fields_changed" && finding.path == "a.txt"
    }),
  )
}

///|
test "central extra field change is reported" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let central = find_signature(archive, 0x02014B50)
  let eocd = find_signature(archive, 0x06054B50)
  assert_true(central >= 0 && eocd >= 0)
  let extra_start = central + 46 + 5
  let changed = insert_bytes(archive, extra_start, [
    b'\xFE', b'\xCA', b'\x00', b'\x00',
  ])
  set_u16(changed, central + 30, 4)
  set_u32(changed, eocd + 4 + 12, (eocd - central + 4).reinterpret_as_uint())
  let result = @zipcause.compare_zip_bytes(archive, Bytes::from_array(changed))
  assert_true(
    result.findings.any(fn(finding) {
      finding.kind == "extra_fields_changed" && finding.path == "a.txt"
    }),
  )
}

///|
test "duplicate entry names are rejected" {
  let archive = @zip.Archive::Archive()
  archive.add("same.txt", b"one", compression=@zip.Store)
  archive.add("same.txt", b"two", compression=@zip.Store)
  assert_true(is_unsupported_zip(@zip.write(archive)))
}

///|
test "entry count above configured limit is rejected" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let changed = archive.to_array()
  let eocd = find_signature(archive, 0x06054B50)
  assert_true(eocd >= 0)
  set_u16(changed, eocd + 8, 10001)
  set_u16(changed, eocd + 10, 10001)
  assert_true(has_resource_limit(Bytes::from_array(changed)))
}

///|
test "member size above configured limit is rejected" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let changed = archive.to_array()
  let central = find_signature(archive, 0x02014B50)
  assert_true(central >= 0)
  set_u32(changed, central + 20, 33554433)
  set_u32(changed, central + 24, 33554433)
  assert_true(has_resource_limit(Bytes::from_array(changed)))
}

///|
test "ZIP64 entry count marker is rejected" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let changed = archive.to_array()
  let eocd = find_signature(archive, 0x06054B50)
  assert_true(eocd >= 0)
  set_u16(changed, eocd + 8, 0xFFFF)
  set_u16(changed, eocd + 10, 0xFFFF)
  assert_true(is_unsupported_zip(Bytes::from_array(changed)))
}

///|
test "encrypted entry flags are rejected" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let changed = archive.to_array()
  let central = find_signature(archive, 0x02014B50)
  assert_true(central >= 0)
  set_u16(changed, 6, 1)
  set_u16(changed, central + 8, 1)
  assert_true(is_unsupported_zip(Bytes::from_array(changed)))
}

///|
test "central directory offset beyond the end record is rejected" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let changed = archive.to_array()
  let eocd = find_signature(archive, 0x06054B50)
  assert_true(eocd >= 0)
  set_u32(changed, eocd + 16, (eocd + 100).reinterpret_as_uint())
  assert_true(is_invalid_zip(Bytes::from_array(changed)))
}

///|
test "corrupted stored payload fails CRC verification" {
  let archive = test_zip("a.txt", b"hello", @zip.Store)
  let changed = archive.to_array()
  changed[35] = b'j'
  assert_true(has_invalid_payload(Bytes::from_array(changed)))
}
