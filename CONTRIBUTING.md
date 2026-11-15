# Contributing

Thanks for your interest. Bug reports, fixes and small improvements are welcome.

## Issues

- Search existing issues first.
- For bugs, include the platform and architecture, the Flutter version, the
  model, `engine.info()` output and what you got. Do not attach audio you
  cannot share.
- Security problems: do **not** open a public issue, see [SECURITY.md](SECURITY.md).

## Pull requests

1. Open an issue first for anything larger than a small fix, so we can agree
   on the approach.
2. Keep changes focused; one topic per pull request.
3. Run the tests before pushing:

   ```sh
   tool/build_host_lib.sh
   flutter test          # needs ~/.cache/openplayx-asr-models/ggml-base.bin
   ```

4. `src/opx_asr.h` is a shared contract: the Dart plugin and the Go service
   [openplayx-asr](https://github.com/openplayx/openplayx-asr) both link it and
   must return the same result structure. Keep `src/exports.txt` /
   `src/exports.map` in sync, and say in the pull request whether openplayx-asr
   needs a matching change.
5. Upgrading whisper.cpp means changing `WHISPER_VERSION` and `WHISPER_SHA256`
   in `tool/build_whisper.sh`, rebuilding and running the tests; mention the
   upstream release notes.
6. Turning on an accelerator (Metal, Core ML, CUDA, OpenMP, BLAS) needs
   verification on the build, model and device it targets.
7. Update the README in both languages (`README.md` and `README.zh-CN.md`)
   when behaviour, the API or the build change.

By contributing you agree that your contribution is licensed under this
repository's license.
