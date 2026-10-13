mv "$archive_path.xcarchive/Products/Applications" Payload
zip -r "$scheme.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"
