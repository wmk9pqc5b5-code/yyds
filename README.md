# yyds.dylib — 安装与使用指南

## 一、项目结构

```
yyds/
├── Tweak.xm                    # 核心 Hook 代码 (12个检测函数全部覆盖)
├── YYDSRootListController.h    # 偏好设置控制器头文件
├── YYDSRootListController.m    # 偏好设置控制器 (4滑块UI)
├── Makefile                    # Theos 构建系统
├── control                     # deb 包描述
├── yyds.plist                  # Cydia Substrate 注入过滤器
├── build.sh                    # 无Theos手动编译脚本
├── .github/workflows/
│   └── build.yml               # GitHub Actions 自动编译
├── Resources/
│   ├── Root.plist              # 设置界面布局定义
│   └── Info.plist              # Bundle 信息
└── README.md                   # 本文件
```

## 二、编译方式

### 方式1: 使用 Theos (推荐, 完整 deb 包)

```bash
# 确保已安装 Theos
# 设置环境变量
export THEOS=/opt/theos

# 编译 + 打包 deb
cd yyds
make clean && make package

# 产物在 ./packages/ 目录下
# 如: packages/com.yyds.bypass_1.0.0_iphoneos-arm.deb
```

### 方式2: GitHub Actions 云编译 (零环境、强烈推荐)

**你什么都不需要安装！** 只要把代码 push 到 GitHub，编译自动完成。

```bash
# 1. 在 GitHub 创建仓库
# 2. 把 yyds 文件夹推上去
cd d:\xm\yyds
git init
git add .
git commit -m "yyds v1.0 — TSS检测屏蔽器"
git remote add origin https://github.com/你的用户名/yyds.git
git push -u origin main

# 3. 打开 GitHub 仓库 → Actions 标签
#    自动编译中... (约 2~3 分钟)
# 4. 编译完成后, 在 Artifacts 下载 .deb 文件
```

**或者手动触发（无需 push）：**
1. 打开 GitHub 仓库
2. 点击 **Actions** → 左侧选 **yyds Build**
3. 点击 **Run workflow** → 绿色按钮

每次编译产物保留 **90 天**。打 `tag` 推送会自动创建 **GitHub Release**。

### 方式3: 手动编译 (仅生成 dylib)

```bash
# 在 macOS 上执行
cd yyds
chmod +x build.sh
./build.sh

# 产物: yyds.dylib
```

## 三、安装到 iPhone

### 方式1: SSH 安装 deb (越狱设备)

```bash
# 1. 确保 iPhone 已越狱, 安装 OpenSSH
# 2. 通过 USB/WiFi 连接到设备

# 传输 deb 包
scp packages/com.yyds.bypass_1.0.0_iphoneos-arm.deb root@192.168.x.x:/tmp/

# SSH 安装
ssh root@192.168.x.x
dpkg -i /tmp/com.yyds.bypass_1.0.0_iphoneos-arm.deb

# 重启 SpringBoard
killall -9 SpringBoard

# 或者使用 sbreload
sbreload
```

### 方式2: Filza 安装 (最方便)

```
1. 将 deb 包传到 iPhone (AirDrop / iCloud / QQ)
2. 用 Filza 打开 deb 文件
3. 点击右上角"安装"
4. 安装完成后 Respring
```

### 方式3: 仅注入 dylib 测试 (开发者)

```bash
# 仅测试 Hook 效果, 不安装到系统
# 将 yyds.dylib 传到设备
scp yyds.dylib root@192.168.x.x:/var/mobile/Documents/

# SSH 到设备
ssh root@192.168.x.x

# 使用 DYLD_INSERT_LIBRARIES 注入到游戏进程
# 需要先找到游戏的 PID
ps aux | grep pubg

# 使用 lldb 注入
lldb -p <PID>
(lldb) expr (void *)dlopen("/var/mobile/Documents/yyds.dylib", 0x2)
(lldb) c
```

## 四、使用步骤

### 首次使用:

```
步骤1: 打开「设置」→ 找到「yyds 屏蔽器」
步骤2: 点击「🔰 滑块1: 启动屏蔽」
步骤3: 系统提示"✅ 屏蔽已启动!" → 点击确定
步骤4: 启动目标游戏
步骤5: 注入内存修改工具
步骤6: 点击「📊 滑块3: 查看监控日志」确认无异常
步骤7: 开始使用

退出:
步骤8: 点击「⏻ 滑块4: 退出程序」
```

### 修改注入的目标游戏:

```
编辑 yyds.plist 中的 Bundle ID:
  com.tencent.tmgp.pubgmhd  → 和平精英
  com.tencent.smoba          → 王者荣耀
  com.tencent.tmgp.cf         → 穿越火线
  com.tencent.tmgp.cod        → CODM

如果要注入所有进程, 删除 yyds.plist 中的 Bundles 数组内容
```

## 五、监控日志说明

日志文件位置: `/var/mobile/Documents/yyds_log.txt`

### 日志格式:

```
[时间][级别][标签] 消息内容
```

- **INFO** (白色): 正常运行信息, 初始化成功等
- **WARN** (黄色): 检测到并被拦截的行为, 如拦截 P_TRACED
- **HOOK** (青色): Hook 函数的调用记录
- **ERROR** (红色): 错误信息

### 关键日志示例:

```
[06-24 14:30:01][INFO][INIT] yyds.dylib v1.0 - TSS检测屏蔽器已加载
[06-24 14:30:01][INFO][HOOKSET] 全部 12 个 Hook 已安装完成
[06-24 14:30:05][WARN][sysctl] !!! 拦截P_TRACED检测: p_flag=0x800 → 清除0x800
[06-24 14:30:06][HOOK][mach_vm_region] 过滤自身区域: addr=0x105800000 → 跳过
[06-24 14:30:07][HOOK][dyld] image_count: 47 → 46 (隐藏1个)
[06-24 14:30:08][WARN][ptrace] !!! 拦截 PT_DENY_ATTACH — 允许调试器附加
```

### 被拦截的标志含义:

| 日志关键词 | 说明 | 来源函数 |
|-----------|------|---------|
| P_TRACED | 反调试检测标志被清除 | sysctl (sub_3F0A8) |
| 自身区域 | 注入模块内存区域被隐藏 | mach_vm_region (sub_20167C) |
| 隐藏1个 | dyld 枚举中隐藏了注入模块 | _dyld_image_count (sub_2012CC) |
| PT_DENY_ATTACH | 反调试附加被拦截 | ptrace |
| 自身模块解析 | dladdr 返回值被伪装 | dladdr (sub_21196C) |

## 六、故障排查

### 问题1: 安装后不生效
```
- 确认设备已越狱
- 确认 Cydia Substrate 已安装
- 检查控制文件确认已启用: cat /var/mobile/Documents/yyds_config.txt
- 可能是 tweak 没注入到目标进程, 查看 yyds.plist 配置
```

### 问题2: 游戏依然闪退
```
- 检查监控日志, 看哪些 Hook 没有正常工作
- 某些游戏可能在初始化时就已经做了检测, 需要保证 dylib 在游戏初始化前加载
- 尝试在 yyds.plist 中设置更早的加载时机
```

### 问题3: 看不到日志
```
- 确认监控已启用: cat /var/mobile/Documents/yyds_config.txt
- 手动创建日志目录: mkdir -p /var/mobile/Documents/
- 检查文件权限: ls -la /var/mobile/Documents/yyds_log.txt
```

## 七、技术架构

```
┌───────────────────────────────────────────────────┐
│                    游戏进程                          │
│                                                    │
│  ┌──────────────────────────────────────────────┐  │
│  │           yyds.dylib (先加载)                  │  │
│  │                                                │  │
│  │  ┌──────────────────────────────────────┐     │  │
│  │  │  Hook 层 (MSHookFunction * 12)       │     │  │
│  │  │  ├─ sysctl           → 屏蔽P_TRACED │     │  │
│  │  │  ├─ sysctlbyname     → 过滤设备查询  │     │  │
│  │  │  ├─ mach_vm_region   → 隐藏内存区域  │     │  │
│  │  │  ├─ vm_region_64     → 隐藏内存区域  │     │  │
│  │  │  ├─ proc_regionfn    → 伪装区域路径  │     │  │
│  │  │  ├─ _dyld_image_cnt  → 减少模块数量  │     │  │
│  │  │  ├─ _dyld_image_name → 隐藏模块名称  │     │  │
│  │  │  ├─ _dyld_image_hdr  → 隐藏模块头部  │     │  │
│  │  │  ├─ dladdr           → 伪装地址解析  │     │  │
│  │  │  ├─ ptrace           → 拦截反调试    │     │  │
│  │  │  ├─ task_for_pid     → 阻止跨进程    │     │  │
│  │  │  └─ getpid           → 监控调试      │     │  │
│  │  └──────────────────────────────────────┘     │  │
│  │                                                │  │
│  │  ┌──────────────────────────────────────┐     │  │
│  │  │  监控日志系统                          │     │  │
│  │  │  ├─ 写文件: /var/.../yyds_log.txt    │     │  │
│  │  │  ├─ 线程安全: pthread_mutex          │     │  │
│  │  │  ├─ 分级日志: INFO/WARN/HOOK/ERROR   │     │  │
│  │  │  └─ 高亮显示: 危及时红, 常规白       │     │  │
│  │  └──────────────────────────────────────┘     │  │
│  │                                                │  │
│  │  ┌──────────────────────────────────────┐     │  │
│  │  │  控制通道                              │     │  │
│  │  │  ├─ 配置文件: yyds_config.txt         │     │  │
│  │  │  └─ notify 通信: com.yyds.bypass...   │     │  │
│  │  └──────────────────────────────────────┘     │  │
│  └──────────────────────────────────────────────┘  │
│                                                    │
│  ┌──────────────────────────────────────────────┐  │
│  │          TSS SDK (tersafe) — 被屏蔽            │  │
│  │  sub_3F0A8 → sysctl(检测P_TRACED)  → 被Hook  │  │
│  │  sub_20167C → mach_vm_region_recurse → 被Hook│  │
│  │  sub_153548 → _dyld_image_count    → 被Hook  │  │
│  │  ... 全部检测函数均被 Hook 屏蔽                │  │
│  └──────────────────────────────────────────────┘  │
│                                                    │
│  ┌──────────────────────────────────────────────┐  │
│  │          内存修改工具 (后加载, 安全运行)        │  │
│  └──────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────┘
```

## 八、免责声明

```
⚠️ 本工具仅供学习研究和逆向工程教育目的使用。

禁止用于:
- 任何违反游戏服务条款的行为
- 破坏游戏公平性
- 其他违法用途

使用者需自行承担所有风险和责任。
作者不对任何封号、数据丢失或其他后果负责。
```
