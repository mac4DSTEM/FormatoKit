#!/bin/zsh
# Build FormatoKit's libhdf5 binary targets: three dynamic-framework XCFrameworks (FormatoLibHDF5, FormatoLibSZ, FormatoLibAEC) from
# the vendored arm64 dylibs in ./vendored (provenance and sha256 in NOTICE), each zipped for a release asset with its SwiftPM checksum.
#
#   tools/xcframework/build.sh [--local] [outdir]   default outdir: dist/xcframeworks (git-ignored)
#
# The zips are not byte-reproducible, so a rebuild changes their checksums. A release build (no --local) writes the new checksums into
# Package.swift; --local (the gates' build when dist/ is missing) leaves Package.swift alone. Release: run without --local, commit
# Package.swift, then upload exactly those zips under the names Package.swift resolves (the owner's commands). A rebuild never
# replaces an asset a tag already pins: it gets a new `xcframeworkRebuild` suffix in Package.swift and is uploaded beside the old ones:
#   cp dist/xcframeworks/FormatoLibHDF5.xcframework.zip <dir>/FormatoLibHDF5-r2.xcframework.zip   (and SZ, AEC)
#   gh release upload 0.4.0 <dir>/FormatoLib{HDF5,SZ,AEC}-r2.xcframework.zip
#   (merge the Package.swift change only after the upload: the xcframework-url job on main resolves them)
#
# Why frameworks: Xcode embeds a dynamic framework from a binary target into an app and signs it with the app's own identity at
# archive time (Developer ID, Hardened Runtime). A resource-bundled bare dylib is copied and stays ad-hoc signed. The binaries are
# the vendored ones with only their install names and load commands rewritten (the code is untouched); each is ad-hoc signed here so
# the local build runs, and Xcode re-signs on embed.
#
# Output: <outdir>/<Name>.xcframework, <Name>.xcframework.zip and checksums.txt ("<Name> <swift package compute-checksum>").
# Each zip is checked as a consumer unpacks it: no AppleDouble ._* entry, and codesign --verify --deep --strict passes on the
# unzipped framework (a ._* file inside a framework fails it with "file added").
set -euo pipefail
local=0; [[ ${1:-} == --local ]] && { local=1; shift }
here=${0:A:h}
root=${here:h:h}
out=${1:-$root/dist/xcframeworks}
out=${out:A}
vend=$here/vendored
work=$(mktemp -d)
trap 'rm -rf $work' EXIT
mkdir -p $out
version=2.1.1   # HDF5; the frameworks' version string

typeset -A src=( FormatoLibHDF5 libhdf5.dylib  FormatoLibSZ libsz.2.dylib  FormatoLibAEC libaec.0.dylib )
typeset -A bid=( FormatoLibHDF5 com.mac4dstem.FormatoLibHDF5  FormatoLibSZ com.mac4dstem.FormatoLibSZ  FormatoLibAEC com.mac4dstem.FormatoLibAEC )
fw() { print "@rpath/$1.framework/Versions/A/$1" }

for name in FormatoLibHDF5 FormatoLibSZ FormatoLibAEC; do
  f=$work/$name.framework
  mkdir -p $f/Versions/A/Resources
  bin=$f/Versions/A/$name
  cp $vend/${src[$name]} $bin
  chmod u+w $bin
  install_name_tool -id "$(fw $name)" $bin
  # the vendored rpaths (@loader_path/../lib) are not needed; delete any
  for rp in $(otool -l $bin | awk '/LC_RPATH/{getline;getline;print $2}'); do install_name_tool -delete_rpath $rp $bin; done
  # sibling frameworks live next to this one (an app's Frameworks/, or SwiftPM's build folder)
  install_name_tool -add_rpath @loader_path/../../.. $bin
  cat > $f/Versions/A/Resources/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>${bid[$name]}</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PL
  ln -s A $f/Versions/Current
  ln -s Versions/Current/$name $f/$name
  ln -s Versions/Current/Resources $f/Resources
done

# load commands between the three (the vendored ones say @loader_path/libsz.2.dylib and so on)
h=$work/FormatoLibHDF5.framework/Versions/A/FormatoLibHDF5
s=$work/FormatoLibSZ.framework/Versions/A/FormatoLibSZ
a=$work/FormatoLibAEC.framework/Versions/A/FormatoLibAEC
install_name_tool -change @loader_path/libsz.2.dylib "$(fw FormatoLibSZ)" $h
install_name_tool -change @loader_path/libaec.0.dylib "$(fw FormatoLibAEC)" $h
# (libsz has no load command on libaec; the absolute-path check below would catch one)

for name in FormatoLibAEC FormatoLibSZ FormatoLibHDF5; do
  codesign --force -s - --timestamp=none $work/$name.framework
  # no absolute path may remain in a load command
  if otool -L $work/$name.framework/Versions/A/$name | tail -n +2 | awk '{print $1}' | grep -vE '^(@rpath/FormatoLib|/usr/lib/|/System/)'; then
    print -u2 "build.sh: $name has a load command outside @rpath/FormatoLib*, /usr/lib, /System"; exit 1
  fi
  rm -rf $out/$name.xcframework $out/$name.xcframework.zip
  xcodebuild -create-xcframework -framework $work/$name.framework -output $out/$name.xcframework >/dev/null
  # --norsrc --noextattr: no AppleDouble ._* entries, which an unzip turns into files inside the signed bundle
  (cd $out && ditto -c -k --norsrc --noextattr --keepParent $name.xcframework $name.xcframework.zip)
  # the zip as a consumer gets it: no ._* entry, and the unzipped framework passes codesign --strict
  if unzip -Z1 $out/$name.xcframework.zip | grep -E '(^|/)\._'; then
    print -u2 "build.sh: $name.xcframework.zip carries AppleDouble ._* entries"; exit 1
  fi
  mkdir $work/unzip-$name
  unzip -q $out/$name.xcframework.zip -d $work/unzip-$name
  if ! codesign --verify --deep --strict $work/unzip-$name/$name.xcframework/macos-arm64/$name.framework; then
    print -u2 "build.sh: $name.framework from the zip fails codesign --verify --deep --strict"; exit 1
  fi
done
: > $out/checksums.txt
for name in FormatoLibHDF5 FormatoLibSZ FormatoLibAEC; do
  print "$name $(cd $root && swift package compute-checksum $out/$name.xcframework.zip)" >> $out/checksums.txt
done
cat $out/checksums.txt
if (( ! local )); then
  while read -r name sum; do
    sed -i '' -E "s|(\"$name\", \")[0-9a-f]{64}|\1$sum|" $root/Package.swift
  done < $out/checksums.txt
  print "Package.swift checksums updated: commit it before uploading these zips"
fi
