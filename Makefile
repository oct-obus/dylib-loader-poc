ARCHS = arm64
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# The loader dylib (injected via LiveContainer's tweak system)
LIBRARY_NAME = DylibLoader

DylibLoader_FILES = DylibLoader.m
DylibLoader_CFLAGS = -fobjc-arc -Wno-unused-variable
DylibLoader_FRAMEWORKS = Foundation UIKit CoreGraphics
DylibLoader_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk

# The example payload (hosted on a server, downloaded at runtime)
LIBRARY_NAME += ExamplePayload

ExamplePayload_FILES = ExamplePayload.m
ExamplePayload_CFLAGS = -fobjc-arc
ExamplePayload_FRAMEWORKS = Foundation
ExamplePayload_INSTALL_PATH = /tmp

include $(THEOS_MAKE_PATH)/library.mk
