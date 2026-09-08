#!/usr/bin/env python3
"""Reject malformed, simulator-only or accidentally signed IPA packages."""
import json,plistlib,struct,sys,zipfile
from pathlib import PurePosixPath
with zipfile.ZipFile(sys.argv[1]) as z:
    names=z.namelist()
    assert not any(PurePosixPath(n).is_absolute() or '..' in PurePosixPath(n).parts for n in names),'Unsafe archive path'
    base='Payload/HorizonCamera.app/'
    for name in ['Info.plist','HorizonCamera','PrivacyInfo.xcprivacy']:
        assert base+name in names,'Missing '+name
    assert not any('_CodeSignature/' in n or n.endswith('embedded.mobileprovision') for n in names),'Signing material remains'
    info=plistlib.loads(z.read(base+'Info.plist'))
    assert info['CFBundleIdentifier']=='app.eyad.HorizonCamera',info
    assert info['CFBundleExecutable']=='HorizonCamera',info
    assert info['CFBundleSupportedPlatforms']==['iPhoneOS'],info
    binary=z.read(base+'HorizonCamera')
    magic,cpu,subtype,filetype,ncmds,sizeofcmds,flags,reserved=struct.unpack_from('<8I',binary)
    assert magic==0xfeedfacf and cpu==0x0100000c,'Not a thin ARM64 Mach-O executable'
    offset=32
    for _ in range(ncmds):
        cmd,length=struct.unpack_from('<2I',binary,offset)
        assert length>=8 and offset+length<=len(binary),'Malformed Mach-O command'
        assert cmd!=0x1d,'Executable retains LC_CODE_SIGNATURE'
        offset+=length
    assert int(info['MinimumOSVersion'].split('.')[0])>=17
    for key in ['NSCameraUsageDescription','NSMicrophoneUsageDescription','NSMotionUsageDescription','NSPhotoLibraryAddUsageDescription']:
        assert info.get(key),'Missing privacy description: '+key
    print(json.dumps({'verified':True,'unsigned':True,'architecture':'arm64','bundle':info['CFBundleIdentifier'],
                      'version':info['CFBundleShortVersionString'],'bytes':len(binary)},indent=2))
