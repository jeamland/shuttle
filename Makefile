SWIFTC=	swiftc
SDK=	/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.12.sdk

shuttle: shuttle.swift
	$(SWIFTC) -sdk $(SDK) $<
