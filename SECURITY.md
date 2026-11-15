# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: open the repository's
**Security** tab and choose **Report a vulnerability**. Do not open a public
issue or pull request for a security problem.

Include the affected version or commit, the platform, how to reproduce it, and
the impact you expect. You should get a first answer within a week.

In scope, for example: memory safety problems in the `opx_asr` C ABI, crashes
caused by crafted WAV or model files, and exported symbols beyond `opx_asr_*`.
Vulnerabilities in whisper.cpp itself should also be reported upstream.

## Supported versions

Only the latest commit on `main` receives fixes.
