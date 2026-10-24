Archive fixtures decoded from the libarchive test suite
(https://github.com/libarchive/libarchive, BSD-2-Clause), same license as the
bundled library in installer/libarchive/. Source .uu files, libarchive 3.8.9:

  plain.zip       test_read_format_zip_msdos.zip.uu     abc, def, def/foo,
                                                      ghi/, jkl, mno/
  zip64.zip       test_read_format_zip_zip64a.zip.uu    "-" (ZIP64 headers)
  lzma2.7z        test_read_format_7zip_bcj_lzma2.7z.uu x86exe
  plain.tar       test_compat_perl_archive_tar.tar.uu   file1
  plain.tgz       test_compat_gzip_1.tgz.uu             f1..f3, d1/f1..f3
  plain.txz       test_compat_xz_1.txz.uu               same
  plain.tar.zst   test_compat_zstd_1.tar.zst.uu         same
  rar4.rar        test_read_format_rar.rar.uu           test.txt, testlink,
                                                      testdir/, testemptydir
  rar5.rar        test_read_format_rar5_stored.rar.uu   helloworld.txt
  rar5_solid.rar  test_read_format_rar5_solid.rar.uu    test.bin, test1..5.bin
  mv4.part1-3.rar test_rar_multivolume_single_file      LibarchiveAddingTest.html
                  .part1-3.rar.uu
  mv5.part01-08.rar test_read_format_rar5_multiarchive  one large binary
                    .part01-08.rar.uu
  encrypted.rar   test_read_format_rar4_encrypted.rar.uu   password "secret"
  encrypted5.rar  test_read_format_rar5_encrypted.rar.uu   password "secret"
  encrypted.zip   test_read_format_zip_encryption_data.zip.uu
  symlink.zip     test_read_format_zip_symlink.zip.uu      file, symlink -> file
  symlink5.rar    test_read_format_rar5_symlink.rar.uu     links + dir
