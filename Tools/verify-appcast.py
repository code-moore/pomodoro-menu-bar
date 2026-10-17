#!/usr/bin/env python3
"""Check the generated feed against the exact archive and embedded public key."""
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

feed, archive, public_key, build, version, prefix = sys.argv[1:]
path = Path(archive)
namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = [item for item in ET.parse(feed).findall('./channel/item')
         if item.findtext(namespace + 'version') == build]
if len(items) != 1:
    sys.exit('ERROR: expected exactly one appcast item for this build.')
item = items[0]
enclosure = item.find('enclosure')
if (enclosure is None or enclosure.get('url') != prefix + path.name
        or enclosure.get('length') != str(path.stat().st_size)
        or item.findtext(namespace + 'shortVersionString') != version):
    sys.exit('ERROR: appcast URL, size or version does not match the archive.')
signature = enclosure.get(namespace + 'edSignature', '')
verifier = Path(__file__).with_name('VerifySparkleSignature.swift')
subprocess.run(['swift', str(verifier), public_key, signature, str(path)], check=True)
print('Appcast URL, version, archive length and Ed25519 signature verified.')
