# Third-party notices

AG RouteGuard's release workflow builds the Windows network-injection DLL from:

- Project: `yuaotian/antigravity-proxy`
- Pinned commit: `32785d2098c9a07c6b7060f47d04a17ac0e5a431`
- Project-declared license: BSD-2-Clause / repository license file applies to that component.

The upstream source is not copied into this repository; the GitHub Actions workflow checks out the pinned commit and builds it on the Windows runner.


## Eligibility signature references

Windows x64 eligibility-gate signature variants and the narrow IDE `isGoogleInternal`
pattern were cross-checked against the MIT-licensed project:

- Project: `QNIX-Dev/eligibility-antigravity-patcher`
- License: MIT
- Copyright (c) 2026 QNIX-Dev

MIT license notice:

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to inclusion of the copyright and permission
notice. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
