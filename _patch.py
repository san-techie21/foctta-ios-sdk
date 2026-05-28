import os
TMP = os.environ.get('TEMP') or os.environ.get('TMP') or '/tmp'
p = os.path.join(TMP, "foctta-ios-sdk-mirror", "Package.swift")
with open(p, "r", encoding="utf-8") as f:
    s = f.read()
old = '        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),\n    ],'
new = '''        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),

        // Apple Swift-DocC plugin — generates the static API reference
        // site that gets published to GitHub Pages on each release tag.
        // See .github/workflows/publish-docc.yml.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
    ],'''
assert old in s, "Marker not found"
s2 = s.replace(old, new)
with open(p, "w", encoding="utf-8") as f:
    f.write(s2)
print("patched")
