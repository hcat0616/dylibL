# SubDump — 直接用 Xcode 自带 clang 编译，不依赖 Theos
# 这样 CI 不用装 Theos / 下 SDK，几十秒出包，链接关系也完全可控
# （不会意外链接 libsubstrate，TrollStore 注入不会崩）

NAME      := SubDump
SRC       := Sources/SubDump.m
ARCH      := arm64
MIN_IOS   := 15.0

SDK       := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC        := xcrun --sdk iphoneos clang

CFLAGS    := -arch $(ARCH) \
             -isysroot "$(SDK)" \
             -miphoneos-version-min=$(MIN_IOS) \
             -fobjc-arc -O2 -Wall \
             -Wno-deprecated-declarations \
             -Wno-unused-function

LDFLAGS   := -dynamiclib \
             -framework Foundation \
             -framework UIKit \
             -framework CoreGraphics \
             -Wl,-undefined,dynamic_lookup \
             -Wl,-install_name,@rpath/$(NAME).dylib

.PHONY: all clean verify

all: $(NAME).dylib

$(NAME).dylib: $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^
	@codesign --force --sign - $@ 2>/dev/null || true
	@echo "== build ok =="
	@lipo -info $@

verify: $(NAME).dylib
	@echo "--- lipo ---"
	@lipo -info $(NAME).dylib
	@echo "--- linked dylibs (不应出现 substrate/ellekit) ---"
	@otool -L $(NAME).dylib

clean:
	@rm -f $(NAME).dylib
