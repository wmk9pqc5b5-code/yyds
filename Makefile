# yyds Makefile — 基于 Theos 构建系统
# 编译: make package
# 安装: make install (需要 SSH 到越狱设备)

export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e
export DEBUG = 0
export FINALPACKAGE = 1

INSTALL_TARGET_PROCESSES = SpringBoard

# 注入目标进程 (游戏BundleID, 按需修改)
# 常用: com.tencent.smoba (王者), com.tencent.tmgp.pubgmhd (和平精英)
# 留空则注入所有进程
YYDS_TARGET_BUNDLE = com.tencent.tmgp.pubgmhd

include $(THEOS)/makefiles/common.mk

# ========== Tweak (dylib) ==========
TWEAK_NAME = yyds

yyds_FILES = Tweak.xm
yyds_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
yyds_LDFLAGS = -Wl,-segalign,4000
yyds_FRAMEWORKS = UIKit IOKit CoreFoundation
yyds_PRIVATE_FRAMEWORKS = Preferences
yyds_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# ========== Preference Bundle (设置界面) ==========
BUNDLE_NAME = yydsprefs

yydsprefs_FILES = YYDSRootListController.m
yydsprefs_INSTALL_PATH = /Library/PreferenceBundles
yydsprefs_FRAMEWORKS = UIKit
yydsprefs_PRIVATE_FRAMEWORKS = Preferences
yydsprefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

# ========== 打包后处理 ==========
after-package::
	@echo "========================================"
	@echo " yyds 构建完成!"
	@echo " 输出: ./packages/"
	@echo ""
	@echo " 安装方式1 (SSH):"
	@echo "   make install THEOS_DEVICE_IP=192.168.x.x"
	@echo ""
	@echo " 安装方式2 (手动):"
	@echo "   scp packages/*.deb root@设备IP:/tmp/"
	@echo "   ssh root@设备IP 'dpkg -i /tmp/*.deb'"
	@echo "========================================"
