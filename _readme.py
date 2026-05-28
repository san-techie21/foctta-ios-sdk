import os
TMP = os.environ.get('TEMP') or os.environ.get('TMP') or '/tmp'
p = os.path.join(TMP, "foctta-ios-sdk-mirror", "README.md")
with open(p, "r", encoding="utf-8") as f:
    s = f.read()
old = "# FOCTTA iOS SDK\n"
new = """# FOCTTA iOS SDK

[![DocC reference](https://img.shields.io/badge/docs-DocC-blue)](https://san-techie21.github.io/foctta-ios-sdk/)
[![SPM compatible](https://img.shields.io/badge/SPM-compatible-brightgreen)](https://swift.org/package-manager/)
[![Apache 2.0](https://img.shields.io/badge/license-Apache--2.0-lightgrey)](LICENSE)

"""
if "img.shields.io/badge/docs-DocC" not in s:
    s2 = s.replace(old, new, 1)
    with open(p, "w", encoding="utf-8") as f:
        f.write(s2)
    print("readme patched")
else:
    print("readme already patched")
